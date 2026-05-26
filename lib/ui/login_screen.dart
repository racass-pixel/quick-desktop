// Single-email entry screen for the passkey flow. The same form serves both
// signup and login — we always try SignupWithPasskey first and let the server
// tell us via 'already_exists' that this email already has an account, in
// which case we route to the passkey login screen prefilled with the email.
//
// A small toggle below the form lets the user pre-declare which path they
// expect (Sign up / Log in), purely a UX hint — the underlying detection is
// always driven by the server response, so the toggle never gates anything.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/connect.dart';
import '../state/providers.dart';
import '../theme/theme.dart';

enum _Mode { signup, login }

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _email = TextEditingController();
  bool _busy = false;
  String? _error;
  _Mode _mode = _Mode.signup;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Enter a valid email.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_mode == _Mode.login) {
        // User pre-declared they have an account; skip the signup probe and
        // go straight to the passkey field.
        if (!mounted) return;
        context.push('/login-passkey?email=${Uri.encodeQueryComponent(email)}');
        return;
      }
      final res = await ref.read(authApiProvider).signupWithPasskey(email);
      if (res.token.isEmpty || res.passkey.isEmpty) {
        setState(() => _error = 'Server returned an incomplete response.');
        return;
      }
      // Persist the session immediately so a refresh would not strand the
      // user — the passkey is still shown next, but the account is real.
      await ref
          .read(authControllerProvider.notifier)
          .onVerified(res.token, res.user);
      if (!mounted) return;
      context.push(
        '/passkey-reveal'
        '?email=${Uri.encodeQueryComponent(email)}'
        '&passkey=${Uri.encodeQueryComponent(res.passkey)}',
      );
    } on ConnectError catch (e) {
      if (e.code == 'already_exists') {
        if (!mounted) return;
        context.push(
            '/login-passkey?email=${Uri.encodeQueryComponent(email)}');
        return;
      }
      setState(() => _error = e.code == 'resource_exhausted'
          ? 'Too many attempts. Try again shortly.'
          : (e.message.isNotEmpty ? e.message : 'Sign-in failed.'));
    } catch (_) {
      setState(() => _error = 'Network error.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLogin = _mode == _Mode.login;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: AppColors.panel,
              borderRadius: BorderRadius.circular(AppRadii.rLg),
              border: Border.all(color: AppColors.line),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 14,
                      height: 14,
                      decoration: const BoxDecoration(
                        color: AppColors.ember,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('Quick',
                        style: Theme.of(context).textTheme.headlineMedium),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  isLogin ? 'Welcome back' : 'Create your account',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _email,
                  enabled: !_busy,
                  autofocus: true,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _busy ? null : _submit(),
                  decoration: const InputDecoration(
                    hintText: 'you@example.com',
                    prefixIcon:
                        Icon(Icons.mail_outline, color: AppColors.ink3),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!,
                      style: const TextStyle(
                          color: AppColors.err, fontSize: 12)),
                ],
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Continue'),
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      isLogin ? 'New here?' : 'Have a passkey?',
                      style: const TextStyle(
                          color: AppColors.ink3, fontSize: 12),
                    ),
                    const SizedBox(width: 6),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() => _mode =
                              isLogin ? _Mode.signup : _Mode.login),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 0),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                      child: Text(isLogin ? 'Sign up' : 'Log in'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
