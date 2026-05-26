// Routing + redirect: bootstrap → /login or shell. The shell is a
// ShellRoute, so the conversations sidebar is shared across child routes.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/settings/screens/settings_screen.dart';
import 'state/providers.dart';
import 'ui/chat_view.dart';
import 'ui/empty_chat.dart';
import 'ui/login_passkey_screen.dart';
import 'ui/login_screen.dart';
import 'ui/main_shell.dart';
import 'ui/passkey_reveal_screen.dart';
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
      // Routes safe for unauthenticated users.
      final isSignedOutAuthRoute = loc == '/login' ||
          loc.startsWith('/verify') ||
          loc.startsWith('/login-passkey');
      // /passkey-reveal is shown right after signup completes, i.e. while
      // signedIn — exclude it from the "kick auth routes back to /" rule.
      final isPostSignupReveal = loc.startsWith('/passkey-reveal');
      if (boot == BootState.signedOut) {
        return isSignedOutAuthRoute ? null : '/login';
      }
      // signedIn
      if (isSignedOutAuthRoute && !isPostSignupReveal) return '/';
      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (_, __) => const LoginScreen(),
      ),
      GoRoute(
        path: '/login-passkey',
        builder: (_, s) => LoginPasskeyScreen(
          email: s.uri.queryParameters['email'] ?? '',
        ),
      ),
      GoRoute(
        path: '/passkey-reveal',
        builder: (_, s) => PasskeyRevealScreen(
          email: s.uri.queryParameters['email'] ?? '',
          passkey: s.uri.queryParameters['passkey'] ?? '',
        ),
      ),
      // /verify is the legacy email-code fallback path. Kept registered so
      // existing deep links / muscle memory still resolve, but the primary
      // entry from /login is now the passkey flow.
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
            builder: (ctx, __) => _SettingsHost(ctx: ctx),
          ),
        ],
      ),
    ],
  );
}

class _SettingsHost extends ConsumerWidget {
  const _SettingsHost({required this.ctx});
  final BuildContext ctx;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final me = auth.user;
    if (me == null) {
      // Should never happen — redirect guards keep us authenticated here.
      return const SizedBox.shrink();
    }
    return SettingsScreen(
      me: me,
      email: '',
      usersApi: ref.read(settingsUsersApiProvider),
      onLogout: () async {
        await ref.read(authControllerProvider.notifier).signOut();
        if (context.mounted) context.go('/login');
      },
      onUserUpdated: (u) {
        // Mirror the freshly-saved user into auth state so the shell rerenders
        // with the new display name / handle / bio.
        ref.read(authControllerProvider.notifier).setUser(u);
      },
      onBack: () => context.go('/'),
    );
  }
}
