// Routing + redirect: bootstrap → /login or shell. The shell is a
// ShellRoute, so the conversations sidebar is shared across child routes.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'state/providers.dart';
import 'ui/chat_view.dart';
import 'ui/empty_chat.dart';
import 'ui/login_screen.dart';
import 'ui/main_shell.dart';
import 'ui/verify_screen.dart';

GoRouter buildRouter(WidgetRef ref) {
  final auth = ref.watch(authControllerProvider);
  return GoRouter(
    initialLocation: '/',
    refreshListenable:
        ValueNotifier<BootState>(auth.boot)..value = auth.boot,
    redirect: (ctx, state) {
      final boot = ref.read(authControllerProvider).boot;
      final loc = state.matchedLocation;
      if (boot == BootState.booting) return null; // splash handles itself
      final isAuthRoute = loc == '/login' || loc.startsWith('/verify');
      if (boot == BootState.signedOut) {
        return isAuthRoute ? null : '/login';
      }
      // signedIn
      if (isAuthRoute) return '/';
      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (_, __) => const LoginScreen(),
      ),
      GoRoute(
        path: '/verify',
        builder: (_, s) => VerifyScreen(email: s.uri.queryParameters['email'] ?? ''),
      ),
      ShellRoute(
        builder: (ctx, state, child) => MainShell(child: child),
        routes: [
          GoRoute(
            path: '/',
            builder: (_, __) => const EmptyChat(),
          ),
          GoRoute(
            path: '/chats/:id',
            builder: (_, s) => ChatView(conversationId: s.pathParameters['id']!),
          ),
          GoRoute(
            path: '/settings',
            builder: (_, __) => Container(
              color: const Color(0xFF0F1014),
              alignment: Alignment.center,
              child: const Text('Settings — coming soon',
                  style: TextStyle(color: Color(0xFFA6A8B5))),
            ),
          ),
        ],
      ),
    ],
  );
}
