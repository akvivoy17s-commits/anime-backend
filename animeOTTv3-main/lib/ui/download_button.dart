import 'package:flutter/material.dart';

import '../services/admin_service.dart';
import '../services/download_models.dart';
import '../services/download_service.dart';
import '../services/session_service.dart';
import 'neo.dart';

/// Small round download button on the video play page (left of the title / info).
/// Shows only a down arrow, no text and NO progress: the progress lives on the Downloads page.
/// States: idle (arrow) -> busy spinner while starting -> dimmed arrow while queued/downloading/paused
/// -> check when downloaded | pink arrow = failed (tap to retry) | block icon = disabled by admin.
/// Duplicate downloads are blocked by DownloadService (per video + language).
class DownloadButton extends StatefulWidget {
  final String videoId;
  final String variant; // language key when the video has several language files, else ''
  final String url;
  final String title;
  final String subtitle;
  final String thumbnail;

  const DownloadButton({
    super.key,
    required this.videoId,
    this.variant = '',
    required this.url,
    required this.title,
    this.subtitle = '',
    this.thumbnail = '',
  });

  @override
  State<DownloadButton> createState() => _DownloadButtonState();
}

class _DownloadButtonState extends State<DownloadButton> {
  bool _busy = false;

  String get _id => DownloadService.keyFor(widget.videoId, widget.variant);

  void _toast(String m) {
    if (!mounted || m.isEmpty) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  Future<void> _run(Future<DlResult> Function() f) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await f();
      if (r.message.isNotEmpty) _toast(r.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, DownloadRecord>>(
      valueListenable: DownloadService.records,
      builder: (_, __, ___) => ValueListenableBuilder<bool>(
        valueListenable: SessionService.allowDownloads,
        builder: (_, __, ___) => ValueListenableBuilder<bool>(
          valueListenable: AdminService.notifier,
          builder: (_, __, ___) => _body(),
        ),
      ),
    );
  }

  Widget _body() {
    final r = DownloadService.recordFor(_id);
    final allowed = DownloadService.canDownload;

    // Downloads blocked (globally or for this user): show nothing at all.
    if (r == null && !allowed) return const SizedBox.shrink();

    if (r == null) {
      return _circle(
        icon: Icons.arrow_downward_rounded,
        color: Neo.cyan,
        loading: _busy,
        onTap: _busy
            ? null
            : () => _run(() => DownloadService.start(
                  videoId: widget.videoId,
                  variant: widget.variant,
                  url: widget.url,
                  title: widget.title,
                  subtitle: widget.subtitle,
                  thumbnail: widget.thumbnail,
                )),
      );
    }

    switch (r.state) {
      case DlState.done:
        return _circle(
          icon: Icons.download_done_rounded,
          color: Neo.cyan,
          onTap: () => _toast('Already downloaded.'),
        );
      case DlState.failed:
        return _circle(
          icon: Icons.arrow_downward_rounded,
          color: Neo.pink,
          loading: _busy,
          onTap: _busy ? null : () => _run(() => DownloadService.resume(_id)),
        );
      case DlState.queued:
      case DlState.running:
      case DlState.paused:
        // no progress here on purpose; it is shown on the Downloads page
        return _circle(
          icon: Icons.arrow_downward_rounded,
          color: Neo.muted,
          onTap: () => _toast('Download already started.'),
        );
    }
  }

  Widget _circle({
    required IconData icon,
    required Color color,
    VoidCallback? onTap,
    bool loading = false,
  }) =>
      // the gap to the title lives here, so when the button is hidden no empty space is left
      Padding(
        padding: const EdgeInsets.only(top: 2, right: 14),
        child: Material(
          color: color.withValues(alpha: 0.12),
          shape: CircleBorder(side: BorderSide(color: color.withValues(alpha: 0.5))),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 50,
              height: 50,
              child: Center(
                child: loading
                    ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: color))
                    : Icon(icon, color: color, size: 24),
              ),
            ),
          ),
        ),
      );
}
