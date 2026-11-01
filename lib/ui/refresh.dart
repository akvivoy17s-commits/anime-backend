import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'neo.dart';

/// Pull-down-to-refresh wrapper used by every page.
/// The page refreshes IN PLACE – no navigation happens.
class NeoRefresh extends StatelessWidget {
  final Future<void> Function() onRefresh;
  final Widget child;

  /// Which scroll notifications may start the refresh (default: the normal top-of-list pull).
  final bool Function(ScrollNotification)? notificationPredicate;
  const NeoRefresh({super.key, required this.onRefresh, required this.child, this.notificationPredicate});

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      color: Neo.cyan,
      backgroundColor: Neo.surface,
      onRefresh: onRefresh,
      notificationPredicate: notificationPredicate ?? defaultScrollNotificationPredicate,
      child: child,
    );
  }
}

/// Forces a fresh server read so live Firestore streams on the page
/// receive up-to-date data. Errors (offline etc.) are ignored.
Future<void> refreshFromServer(List<String> collections) async {
  try {
    await Future.wait(collections.map((c) => FirebaseFirestore.instance
        .collection(c)
        .get(const GetOptions(source: Source.server))));
  } catch (_) {}
}
