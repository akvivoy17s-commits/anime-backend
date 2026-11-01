import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

/// Set to false to get the ORIGINAL start-up behaviour (sequential candidates, no probe, no URL cache)
/// - use it to measure "before" vs "after" on the same device and video (see PHASE6_NOTES.md).
const bool kStreamOptimizations = true;

/// Start-up timings of the player (kept in memory, shown by long-pressing the video title).
class StreamPerf {
  StreamPerf._();

  static final List<String> _log = [];

  static void record(String label, int ms, {String note = ''}) {
    _log.add('${DateTime.now().toIso8601String().substring(11, 19)}  $label  ${ms}ms${note.isEmpty ? '' : '  ($note)'}');
    if (_log.length > 30) _log.removeAt(0);
    debugPrint('[perf] $label ${ms}ms $note');
  }

  static String summary() => _log.isEmpty
      ? 'Perf: no samples yet (optimizations ${kStreamOptimizations ? 'ON' : 'OFF'}).'
      : 'Perf (optimizations ${kStreamOptimizations ? 'ON' : 'OFF'}):\n${_log.reversed.join('\n')}';
}

/// Remembers which URL variant actually played for a video, so the next start skips all guessing.
class StreamUrlCache {
  StreamUrlCache._();

  static const _key = 'stream_url_cache_v1';
  static Map<String, String>? _m;

  static Future<Map<String, String>> _load() async {
    if (_m != null) return _m!;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      _m = raw == null ? {} : Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (_) {
      _m = {};
    }
    return _m!;
  }

  static Future<String?> get(String original) async => (await _load())[original];

  static Future<void> put(String original, String working) async {
    final m = await _load();
    if (m[original] == working) return;
    m[original] = working;
    if (m.length > 200) m.remove(m.keys.first);
    unawaited(SharedPreferences.getInstance().then((p) => p.setString(_key, jsonEncode(m))));
  }

  static Future<void> remove(String original) async {
    final m = await _load();
    if (m.remove(original) != null) {
      unawaited(SharedPreferences.getInstance().then((p) => p.setString(_key, jsonEncode(m))));
    }
  }
}

/// Probes all candidate URLs IN PARALLEL with `Range: bytes=0-0` (a few bytes, proves range support
/// and that the link serves video, not an HTML page) and returns them with the fastest working one first.
class StreamProbe {
  StreamProbe._();

  static Future<List<String>> order(List<String> candidates, {Duration timeout = const Duration(seconds: 5)}) async {
    if (candidates.length < 2) return candidates;
    final best = await fastest(candidates, timeout: timeout);
    if (best == null) return candidates;
    return [best, ...candidates.where((c) => c != best)];
  }

  /// The first candidate that answers with real video bytes, or null when none does.
  static Future<String?> fastest(List<String> candidates, {Duration timeout = const Duration(seconds: 5)}) async {
    if (candidates.isEmpty) return null;
    final clients = <http.Client>[];
    final winner = Completer<String?>();
    var pending = candidates.length;

    Future<void> probe(String url) async {
      final c = http.Client();
      clients.add(c);
      try {
        final req = http.Request('GET', Uri.parse(url))..headers['Range'] = 'bytes=0-0';
        final r = await c.send(req).timeout(timeout);
        final ct = (r.headers['content-type'] ?? '').toLowerCase();
        if ((r.statusCode == 200 || r.statusCode == 206) && !ct.contains('text/html') && !winner.isCompleted) {
          winner.complete(url);
        }
      } on SocketException {
        // offline: nothing to learn
      } catch (_) {}
      if (--pending == 0 && !winner.isCompleted) winner.complete(null);
    }

    for (final u in candidates) {
      unawaited(probe(u));
    }
    final best = await winner.future.timeout(timeout + const Duration(seconds: 1), onTimeout: () => null);
    for (final c in clients) {
      c.close(); // aborts the slower probes
    }
    return best;
  }
}

/// Warms the URL cache for videos the user is likely to open next (a few bytes per video),
/// so the next episode starts without the probe step.
class StreamWarm {
  StreamWarm._();

  static final Set<String> _done = {};

  static Future<void> url(String original, List<String> candidates) async {
    if (!kStreamOptimizations || original.isEmpty || !_done.add(original)) return;
    try {
      if (await StreamUrlCache.get(original) != null) return;
      final best = await StreamProbe.fastest(candidates);
      if (best != null) await StreamUrlCache.put(original, best);
    } catch (_) {
      _done.remove(original); // try again next time
    }
  }

  /// Call from list pages: finds the working URL of the first few videos (one by one, a few bytes each),
  /// so tapping any of them starts without guessing. Every video is probed only once.
  static Future<void> fromDocs(Iterable<Map<String, dynamic>?> datas, {int max = 8}) async {
    if (!kStreamOptimizations) return;
    final urls = <String>[];
    for (final d in datas) {
      if (urls.length >= max) break;
      for (final k in const ['videoUrl', 'url', 'videoURL']) {
        final v = (d?[k] ?? '').toString().trim();
        if (v.isNotEmpty) {
          urls.add(v);
          break;
        }
      }
    }
    // all probes run in parallel (a few bytes each) instead of one after another
    await Future.wait(urls.map(url_));
  }

  static Future<void> url_(String url) => StreamWarm.url(url, StreamCandidates.build(url));
}

/// Keeps ONE already-initialized player for the next episode, so "next" starts instantly
/// (no URL probe, no player start-up). Prepared when the current episode is ~60% watched.
/// The unused player is thrown away after a few minutes / soon after the player page closes.
class StreamPreload {
  StreamPreload._();

  static VideoPlayerController? _c;
  static String? _orig;
  static Timer? _expire;

  static Future<void> prepare(String original, List<String> candidates) async {
    if (!kStreamOptimizations || original.isEmpty || _orig == original) return;
    clear();
    _orig = original;
    VideoPlayerController? c;
    try {
      final url = await StreamUrlCache.get(original) ?? await StreamProbe.fastest(candidates);
      if (url == null || _orig != original) {
        if (_orig == original) _orig = null;
        return;
      }
      c = VideoPlayerController.networkUrl(Uri.parse(url), videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false));
      await c.initialize().timeout(const Duration(seconds: 20));
      if (_orig != original) {
        await c.dispose(); // cleared / replaced while we were preparing
        return;
      }
      _c = c;
      unawaited(StreamUrlCache.put(original, url));
      _expire = Timer(const Duration(minutes: 4), clear);
      debugPrint('[perf] next episode preloaded');
    } catch (_) {
      await c?.dispose();
      if (_orig == original) _orig = null;
    }
  }

  /// The ready player for this video (ownership moves to the caller), or null.
  static VideoPlayerController? take(String original) {
    final c = _c;
    if (c == null || _orig != original) return null;
    _expire?.cancel();
    _c = null;
    _orig = null;
    if (c.value.isInitialized && !c.value.hasError) return c;
    c.dispose(); // unusable
    return null;
  }

  static void clear() {
    _expire?.cancel();
    _c?.dispose();
    _c = null;
    _orig = null;
  }

  /// Called when the player page closes: keep the preloaded player a few seconds for the
  /// next page (pushReplacement), then drop it.
  static void clearSoon() {
    final o = _orig;
    if (o == null) return;
    Timer(const Duration(seconds: 8), () {
      if (_orig == o) clear();
    });
  }
}

/// The URL variants to try for a stored video link (shared by the player and the list pages).
class StreamCandidates {
  StreamCandidates._();

  static String? driveFileId(String url) {
    try {
      final uri = Uri.parse(url);
      final seg = uri.pathSegments;
      final d = seg.indexOf('d');
      if (d != -1 && d + 1 < seg.length) {
        final id = seg[d + 1].trim();
        if (id.isNotEmpty) return id;
      }
      final q = uri.queryParameters['id'];
      if (q != null && q.isNotEmpty) return q;
    } catch (_) {}
    return null;
  }

  static List<String> build(String originalUrl) {
    final clean = originalUrl.trim();
    final out = <String>[];
    void add(String? v) {
      final u = v?.trim() ?? '';
      if (u.isNotEmpty && !out.contains(u)) out.add(u);
    }

    final id = driveFileId(clean);
    if (id != null && id.isNotEmpty) {
      // Direct-download variants FIRST (no redirect, no HTML virus-scan page) -> fastest start.
      add('https://drive.usercontent.google.com/download?id=$id&export=download&confirm=t');
      add('https://drive.usercontent.google.com/download?id=$id&confirm=yes&export=download');
      add('https://drive.google.com/uc?export=download&confirm=t&id=$id');
      add('https://drive.google.com/uc?export=download&id=$id');
    }
    add(clean); // original link last (for a Drive "view" link it is an HTML page)
    return out;
  }
}