import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../services/screen_awake_service.dart';
import '../ui/neo.dart';

/// Plays a downloaded file straight from local storage (no network needed).
class OfflinePlayerPage extends StatefulWidget {
  final String path;
  final String title;
  const OfflinePlayerPage({super.key, required this.path, required this.title});

  @override
  State<OfflinePlayerPage> createState() => _OfflinePlayerPageState();
}

class _OfflinePlayerPageState extends State<OfflinePlayerPage> {
  late final VideoPlayerController _c = VideoPlayerController.file(File(widget.path));
  bool _ready = false;
  bool _controls = true;
  bool _landscape = false;
  String? _error;
  double _speed = 1.0;

  @override
  void initState() {
    super.initState();
    _c.addListener(_tick);
    _c.initialize().then((_) async {
      if (!mounted) return;
      setState(() => _ready = true);
      await _c.play();
    }).catchError((e) {
      if (mounted) setState(() => _error = 'This file could not be played. It may be damaged — delete it and download again.');
    });
  }

  void _tick() {
    if (!mounted) return;
    ScreenAwakeService.set(this, _c.value.isPlaying);
    setState(() {});
  }

  @override
  void dispose() {
    _c.removeListener(_tick);
    _c.dispose();
    ScreenAwakeService.release(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
    super.dispose();
  }

  Future<void> _toggleOrientation() async {
    _landscape = !_landscape;
    await SystemChrome.setEnabledSystemUIMode(_landscape ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(_landscape
        ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
        : [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
    if (mounted) setState(() {});
  }

  Future<void> _seekBy(int sec) async {
    final v = _c.value;
    var t = v.position + Duration(seconds: sec);
    if (t < Duration.zero) t = Duration.zero;
    if (t > v.duration) t = v.duration;
    await _c.seekTo(t);
  }

  String _fmt(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours, m = d.inMinutes.remainder(60), s = d.inSeconds.remainder(60);
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    final v = _c.value;
    final maxMs = v.duration.inMilliseconds.toDouble() < 1 ? 1.0 : v.duration.inMilliseconds.toDouble();
    return Scaffold(
      backgroundColor: Colors.black,
      body: _error != null
          ? SafeArea(
              child: Stack(children: [
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Neo.text)),
                  ),
                ),
                Positioned(top: 4, left: 4, child: BackButton(color: Neo.text, onPressed: () => Navigator.pop(context))),
              ]),
            )
          : !_ready
              ? const Center(child: CircularProgressIndicator(color: Neo.cyan))
              : GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _controls = !_controls),
                  child: Stack(fit: StackFit.expand, children: [
                    Center(child: AspectRatio(aspectRatio: v.aspectRatio == 0 ? 16 / 9 : v.aspectRatio, child: VideoPlayer(_c))),
                    AnimatedOpacity(
                      duration: const Duration(milliseconds: 200),
                      opacity: _controls ? 1 : 0,
                      child: IgnorePointer(
                        ignoring: !_controls,
                        child: Container(
                          color: Colors.black45,
                          child: SafeArea(
                            child: Column(children: [
                              Row(children: [
                                BackButton(color: Neo.text, onPressed: () => Navigator.pop(context)),
                                Expanded(
                                  child: Text(widget.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: Neo.text, fontWeight: FontWeight.w700)),
                                ),
                                PopupMenuButton<double>(
                                  tooltip: 'Speed',
                                  color: Neo.surface,
                                  icon: const Icon(Icons.speed_rounded, color: Neo.text),
                                  onSelected: (s) {
                                    _speed = s;
                                    _c.setPlaybackSpeed(s);
                                  },
                                  itemBuilder: (_) => [
                                    for (final s in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
                                      PopupMenuItem(
                                        value: s,
                                        child: Text('${s}x', style: TextStyle(color: s == _speed ? Neo.cyan : Neo.text)),
                                      ),
                                  ],
                                ),
                                IconButton(
                                  onPressed: _toggleOrientation,
                                  icon: Icon(_landscape ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded, color: Neo.text),
                                ),
                              ]),
                              const Spacer(),
                              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                IconButton(iconSize: 36, onPressed: () => _seekBy(-10), icon: const Icon(Icons.replay_10_rounded, color: Neo.text)),
                                const SizedBox(width: 12),
                                IconButton(
                                  iconSize: 56,
                                  onPressed: () => v.isPlaying ? _c.pause() : _c.play(),
                                  icon: Icon(v.isPlaying ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded, color: Neo.cyan),
                                ),
                                const SizedBox(width: 12),
                                IconButton(iconSize: 36, onPressed: () => _seekBy(10), icon: const Icon(Icons.forward_10_rounded, color: Neo.text)),
                              ]),
                              const Spacer(),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                                child: Row(children: [
                                  Text(_fmt(v.position), style: const TextStyle(color: Neo.text, fontSize: 12)),
                                  Expanded(
                                    child: Slider(
                                      activeColor: Neo.cyan,
                                      inactiveColor: Colors.white24,
                                      min: 0,
                                      max: maxMs,
                                      value: v.position.inMilliseconds.toDouble().clamp(0.0, maxMs).toDouble(),
                                      onChanged: (x) => _c.seekTo(Duration(milliseconds: x.round())),
                                    ),
                                  ),
                                  Text(_fmt(v.duration), style: const TextStyle(color: Neo.text, fontSize: 12)),
                                ]),
                              ),
                            ]),
                          ),
                        ),
                      ),
                    ),
                  ]),
                ),
    );
  }
}
