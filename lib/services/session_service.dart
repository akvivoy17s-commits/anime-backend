import 'dart:async';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';

enum SessionStatus { idle, checking, active, blocked }

/// Concurrent-login control (the limit itself lives on the backend).
///
///  * login          -> POST /session/start      (429 = limit reached -> [SessionStatus.blocked])
///  * every ~60 s    -> POST /session/heartbeat  (keeps the session "active"; re-admits an expired one)
///  * sign out       -> POST /session/end
///
/// If the server can't be reached the user is NOT locked out (so offline use keeps working);
/// the app keeps retrying every 20 s and the limit applies again as soon as the server answers.
class SessionService {
  SessionService._();

  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  static final ValueNotifier<SessionStatus> status = ValueNotifier(SessionStatus.idle);

  /// Message shown on the "limit reached" screen.
  static final ValueNotifier<String> message = ValueNotifier('');

  /// Last value the server reported for the download permission (live updates come from Firestore later).
  static final ValueNotifier<bool> allowDownloads = ValueNotifier(true);

  // Effective permission = this user's own setting (admin's choice) if any, else the global switch.
  /// true when the admin blocked downloads for THIS user -> the Downloads tab is hidden.
  static final ValueNotifier<bool> downloadsBlocked = ValueNotifier(false);

  static bool _globalAllow = true;
  static bool? _userOverride;

  /// Live global switch (Firestore settings/app).
  static void setGlobalAllow(bool v) {
    _globalAllow = v;
    allowDownloads.value = _userOverride ?? _globalAllow;
  }

  static StreamSubscription<User?>? _authSub;
  static Timer? _timer;
  static String? _uid;
  static String? _device;
  static bool _busy = false;
  static int _heartbeatSec = 60;
  static const Duration _retryAfterFailure = Duration(seconds: 20);
  static final _Lifecycle _lifecycle = _Lifecycle();

  /// Call once after Firebase.initializeApp.
  static void init() {
    WidgetsBinding.instance.removeObserver(_lifecycle);
    WidgetsBinding.instance.addObserver(_lifecycle);
    _authSub?.cancel();
    _authSub = FirebaseAuth.instance.authStateChanges().listen(_onAuth);
  }

  /// True when the session state belongs to [uid] (guards against a stale state after switching accounts).
  static bool isFor(String? uid) => uid != null && uid == _uid;

  // ---------------------------------------------------------------- device id
  static Future<String> deviceId() async {
    if (_device != null) return _device!;
    final valid = RegExp(r'^[A-Za-z0-9_-]{8,64}$');
    try {
      final prefs = await SharedPreferences.getInstance();
      var id = prefs.getString('anime_device_id');
      if (id == null || !valid.hasMatch(id)) {
        id = _randomId();
        await prefs.setString('anime_device_id', id);
      }
      _device = id;
    } catch (_) {
      _device = _randomId();
    }
    return _device!;
  }

  static String _randomId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random.secure();
    return List.generate(28, (_) => chars[r.nextInt(chars.length)]).join();
  }

  static Future<Map<String, dynamic>> _body() async => {
        'deviceId': await deviceId(),
        'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
      };

  // ---------------------------------------------------------------- auth hook
  static void _onAuth(User? user) {
    if (user == null) {
      _uid = null;
      _userOverride = null;
      downloadsBlocked.value = false;
      _timer?.cancel();
      message.value = '';
      status.value = SessionStatus.idle;
      return;
    }
    if (user.uid == _uid) return;
    _uid = user.uid;
    _start();
  }

  // ---------------------------------------------------------------- start / heartbeat
  static Future<void> _start() async {
    final uid = _uid;
    if (uid == null || _busy) return;
    _busy = true;
    _timer?.cancel();
    status.value = SessionStatus.checking;
    try {
      final r = await ApiClient.call(
        'POST',
        '/session/start',
        body: await _body(),
        timeout: const Duration(seconds: 20),
        warmTimeout: const Duration(seconds: 25),
      );
      if (_uid != uid) return;
      _accept(r);
    } on ApiException catch (e) {
      if (_uid != uid) return;
      if (e.status == 429) {
        _block(e.message);
      } else {
        // Server asleep / unreachable: let the user in, keep trying in the background.
        status.value = SessionStatus.active;
        _scheduleRetry();
      }
    } finally {
      _busy = false;
    }
  }

  static Future<void> _heartbeat() async {
    final uid = _uid;
    if (uid == null || _busy || status.value == SessionStatus.blocked) return;
    _busy = true;
    try {
      final r = await ApiClient.call(
        'POST',
        '/session/heartbeat',
        body: await _body(),
        timeout: const Duration(seconds: 20),
        warm: false,
      );
      if (_uid != uid) return;
      _accept(r);
    } on ApiException catch (e) {
      if (_uid != uid) return;
      if (e.status == 429) {
        _block(e.message);
      } else {
        _scheduleRetry();
      }
    } finally {
      _busy = false;
    }
  }

  static void _accept(Map<String, dynamic> r) {
    final hb = r['heartbeatSec'];
    _heartbeatSec = hb is num ? hb.toInt().clamp(15, 120).toInt() : 60;
    final g = r['globalDownloads'];
    if (g is bool) _globalAllow = g;
    if (r.containsKey('downloadOverride')) {
      final o = r['downloadOverride'];
      _userOverride = o is bool ? o : null;
      downloadsBlocked.value = _userOverride == false;
    }
    final dl = r['allowDownloads'];
    if (dl is bool) {
      allowDownloads.value = (g is bool || r.containsKey('downloadOverride')) ? (_userOverride ?? _globalAllow) : dl;
    }
    message.value = '';
    status.value = SessionStatus.active;
    _timer?.cancel();
    _timer = Timer.periodic(Duration(seconds: _heartbeatSec), (_) => _heartbeat());
  }

  static void _scheduleRetry() {
    _timer?.cancel();
    _timer = Timer(_retryAfterFailure, _heartbeat);
  }

  static void _block(String msg) {
    _timer?.cancel();
    message.value = msg;
    status.value = SessionStatus.blocked;
    // close any page that was open on top of Home (player, profile sub-pages, ...)
    navigatorKey.currentState?.popUntil((route) => route.isFirst);
  }

  static void _onResume() {
    if (_uid != null && status.value == SessionStatus.active) _heartbeat();
  }

  /// "Try again" on the limit-reached screen.
  static Future<void> retry() => _start();

  // ---------------------------------------------------------------- end
  /// Frees this device's slot. Never throws; a failure only means the slot frees itself after ~3 min.
  static Future<void> end() async {
    final uid = _uid;
    _timer?.cancel();
    if (uid == null) return;
    try {
      await ApiClient.call(
        'POST',
        '/session/end',
        body: await _body(),
        timeout: const Duration(seconds: 6),
        warm: false,
      );
    } catch (_) {}
  }

  /// Use this instead of FirebaseAuth.signOut() so the slot is released first.
  static Future<void> signOut() async {
    await end();
    await FirebaseAuth.instance.signOut();
  }
}

class _Lifecycle with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) SessionService._onResume();
  }
}
