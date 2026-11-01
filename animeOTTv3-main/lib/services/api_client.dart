import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import 'api_config.dart';

/// [status] is null for network problems / timeouts, otherwise the HTTP status code.
class ApiException implements Exception {
  final String message;
  final int? status;
  const ApiException(this.message, [this.status]);

  bool get isNetwork => status == null;

  @override
  String toString() => message;
}

/// Authenticated JSON calls to the backend (Firebase ID token in the Authorization header).
/// Used by sessions, the admin Controls page and (later) downloads.
class ApiClient {
  ApiClient._();

  static DateTime? _lastWarm;

  static Future<Map<String, dynamic>> call(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Duration timeout = const Duration(seconds: 45),
    bool warm = true,
    Duration warmTimeout = const Duration(seconds: 90),
  }) async {
    final base = ApiConfig.baseUrl;
    if (base == null) {
      throw const ApiException('Server URL not configured (API_BASE_URL).');
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw const ApiException('Please sign in again.', 401);

    // Render's free tier sleeps: wake it first so the real call doesn't time out.
    // (shared with wake(); never wait longer than this call's own warmTimeout)
    if (warm) await _warm(base, warmTimeout).timeout(warmTimeout, onTimeout: () {});

    String token;
    try {
      token = (await user.getIdToken()) ?? '';
    } catch (_) {
      throw const ApiException('Could not verify your login. Check your connection.');
    }

    final uri = Uri.parse('$base$path');
    final headers = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
    try {
      final http.Response r;
      switch (method) {
        case 'GET':
          r = await http.get(uri, headers: headers).timeout(timeout);
          break;
        case 'DELETE':
          r = await http.delete(uri, headers: headers).timeout(timeout);
          break;
        case 'PUT':
          r = await http
              .put(uri, headers: headers, body: jsonEncode(body ?? {}))
              .timeout(timeout);
          break;
        default:
          r = await http
              .post(uri, headers: headers, body: jsonEncode(body ?? {}))
              .timeout(timeout);
      }

      dynamic data;
      try {
        data = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(utf8.decode(r.bodyBytes));
      } on FormatException {
        data = null;
      }

      if (r.statusCode >= 200 && r.statusCode < 300) {
        if (data is Map) return Map<String, dynamic>.from(data);
        return <String, dynamic>{};
      }
      final detail = data is Map ? data['detail'] : null;
      // FastAPI's bare "Not Found" means the route does not exist on the deployed
      // server (old backend deploy), not that a video/user is missing.
      if (r.statusCode == 404 && (detail == null || detail == 'Not Found')) {
        throw ApiException(
          'Server-la indha feature illa (old backend deploy). Latest backend-a Render-la redeploy pannunga.',
          404,
        );
      }
      throw ApiException(
        detail is String
            ? detail
            : (r.statusCode == 422 ? 'Invalid request.' : 'Server error (${r.statusCode})'),
        r.statusCode,
      );
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const ApiException('Server timed out.');
    } on http.ClientException {
      final host = Uri.tryParse(ApiConfig.baseUrl ?? '')?.authority ?? '';
      throw ApiException('Cannot reach the server${host.isEmpty ? '' : ' ($host)'}.');
    }
  }

  static Future<void>? _warmFuture;

  /// Fire-and-forget: wakes the sleeping server in the background (call when a screen opens),
  /// so the first real request (download, session...) doesn't hit a cold start.
  static void wake() {
    final base = ApiConfig.baseUrl;
    if (base == null) return;
    unawaited(_warm(base, const Duration(seconds: 90)));
  }

  // One wake-up request at a time: callers share the same in-flight /health call.
  static Future<void> _warm(String base, Duration max) {
    final now = DateTime.now();
    if (_lastWarm != null && now.difference(_lastWarm!).inMinutes < 4) return Future.value();
    return _warmFuture ??= _doWarm(base, max).whenComplete(() => _warmFuture = null);
  }

  static Future<void> _doWarm(String base, Duration max) async {
    try {
      await http.get(Uri.parse('$base/health')).timeout(max);
      _lastWarm = DateTime.now();
    } catch (_) {}
  }
}