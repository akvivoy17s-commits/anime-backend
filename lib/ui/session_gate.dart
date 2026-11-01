import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/session_service.dart';
import 'neo.dart';

/// Shows [child] only while this user holds a login slot.
/// While the slot is being checked -> spinner. Limit reached -> explanation screen.
class SessionGate extends StatelessWidget {
  final Widget child;
  const SessionGate({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SessionStatus>(
      valueListenable: SessionService.status,
      builder: (context, s, _) {
        final uid = FirebaseAuth.instance.currentUser?.uid;
        if (s == SessionStatus.blocked && SessionService.isFor(uid)) {
          return const _LimitReachedView();
        }
        if (s == SessionStatus.active && SessionService.isFor(uid)) {
          return child;
        }
        return const Scaffold(
          backgroundColor: Neo.bg,
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: Neo.cyan),
                SizedBox(height: 16),
                Text(
                  'CHECKING SESSION…',
                  style: TextStyle(
                    color: Neo.muted,
                    fontFamily: Neo.mono,
                    fontSize: 11,
                    letterSpacing: 2,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LimitReachedView extends StatelessWidget {
  const _LimitReachedView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Neo.bg,
      body: NeoBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(22),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: GlassCard(
                  radius: 26,
                  borderColor: Neo.amber.withValues(alpha: 0.4),
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Neo.amber.withValues(alpha: 0.12),
                          border: Border.all(color: Neo.amber.withValues(alpha: 0.4)),
                        ),
                        child: const Icon(Icons.groups_rounded, color: Neo.amber, size: 34),
                      ),
                      const SizedBox(height: 18),
                      const Text(
                        'LOGIN LIMIT REACHED',
                        style: TextStyle(
                          color: Neo.amber,
                          fontFamily: Neo.mono,
                          fontSize: 12,
                          letterSpacing: 2,
                        ),
                      ),
                      const SizedBox(height: 12),
                      ValueListenableBuilder<String>(
                        valueListenable: SessionService.message,
                        builder: (_, msg, __) => Text(
                          msg.isEmpty
                              ? 'Too many users are online right now. Please try again in a few minutes.'
                              : msg,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Neo.text, fontSize: 14.5, height: 1.45),
                        ),
                      ),
                      const SizedBox(height: 22),
                      NeoButton(
                        label: 'TRY AGAIN',
                        icon: Icons.refresh_rounded,
                        onTap: SessionService.retry,
                      ),
                      const SizedBox(height: 10),
                      NeoGhostButton(
                        label: 'SIGN OUT',
                        leading: const Icon(Icons.logout_rounded, color: Neo.muted, size: 18),
                        onTap: SessionService.signOut,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
