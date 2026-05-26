// Second step of the passkey login: the email is already known (forwarded
// from the entry screen, which discovered the account is registered via the
// AlreadyExists branch), and the user types their 19-char passkey here.
//
// The input is auto-formatted on the fly — we strip non-alphanumeric, lowercase
// everything, and re-insert the three hyphens after every fourth character.
// That way pastes from clipboard, downloads or user typing all converge on the
// same canonical xxxx-xxxx-xxxx-xxxx shape before submission.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/connect.dart';
import '../state/providers.dart';
import '../theme/theme.dart';

class LoginPasskeyScreen extends ConsumerStatefulWidget {
  const LoginPasskeyScreen({super.key, required this.email});
  final String email;

  @override
  ConsumerState<LoginPasskeyScreen> createState() => _LoginPasskeyScreenState();
}

class _LoginPasskeyScreenState extends ConsumerState<LoginPasskeyScreen> {
  final _passkey = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _passkey.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _looksComplete => _passkey.text.length == 19;

  Future<void> _submit() async {
    if (_busy) return;
    final pk = _passkey.text.trim();
    if (pk.length != 19) {
      setState(() => _error = 'Passkey should be 19 characters.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res =
          await ref.read(authApiProvider).loginWithPasskey(widget.email, pk);
      if (res.token.isEmpty) {
        setState(() => _error = 'Server returned no token.');
        return;
      }
      await ref
          .read(authControllerProvider.notifier)
          .onVerified(res.token, res.user);
      if (!mounted) return;
      context.go('/');
    } on ConnectError catch (e) {
      setState(() => _error = e.code == 'unauthenticated'
          ? 'Wrong passkey.'
          : (e.message.isNotEmpty ? e.message : 'Login failed.'));
    } catch (_) {
      setState(() => _error = 'Network error.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showForgotTooltip() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.raised,
        content: Text(
          "Passkeys can't be recovered. Contact your admin.",
          style: TextStyle(color: AppColors.ink1),
        ),
        duration: Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
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
                Text(
                  'Welcome back',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.raised,
                    borderRadius: BorderRadius.circular(AppRadii.rMd),
                    border: Border.all(color: AppColors.line),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.mail_outline,
                          color: AppColors.ink3, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          widget.email,
                          style: const TextStyle(
                              color: AppColors.ink1, fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton(
                        onPressed:
                            _busy ? null : () => context.go('/login'),
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(0, 0),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('Change'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: _passkey,
                  focusNode: _focus,
                  enabled: !_busy,
                  obscureText: _obscure,
                  obscuringCharacter: '•',
                  keyboardType: TextInputType.visiblePassword,
                  textInputAction: TextInputAction.go,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: const TextStyle(
                    fontFamily: 'Consolas',
                    fontFamilyFallback: ['Courier New', 'monospace'],
                    fontSize: 16,
                    letterSpacing: 1.2,
                  ),
                  onSubmitted: (_) => _submit(),
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                  inputFormatters: [_PasskeyFormatter()],
                  decoration: InputDecoration(
                    hintText: 'xxxx-xxxx-xxxx-xxxx',
                    hintStyle: const TextStyle(
                      color: AppColors.ink3,
                      fontFamily: 'Consolas',
                      fontFamilyFallback: ['Courier New', 'monospace'],
                    ),
                    prefixIcon: const Icon(Icons.key_outlined,
                        color: AppColors.ink3),
                    suffixIcon: IconButton(
                      tooltip: _obscure ? 'Show' : 'Hide',
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        size: 18,
                        color: AppColors.ink3,
                      ),
                      onPressed: _busy
                          ? null
                          : () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!,
                      style: const TextStyle(
                          color: AppColors.err, fontSize: 12)),
                ],
                const SizedBox(height: 18),
                ElevatedButton(
                  onPressed: _busy || !_looksComplete ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Log in'),
                ),
                const SizedBox(height: 8),
                Center(
                  child: TextButton(
                    onPressed: _busy ? null : _showForgotTooltip,
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.ink3,
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                    child: const Text('Forgot passkey?'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Normalises any keystroke or paste into the canonical xxxx-xxxx-xxxx-xxxx
// form: lowercase a-z0-9 only, hyphens auto-inserted, truncated to 19 chars.
// Re-positions the caret to the end of the formatted string — good enough for
// a left-to-right one-shot field; we don't try to preserve mid-edit cursor.
class _PasskeyFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final raw = newValue.text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    final clamped = raw.length > 16 ? raw.substring(0, 16) : raw;
    final buf = StringBuffer();
    for (var i = 0; i < clamped.length; i++) {
      if (i > 0 && i % 4 == 0) buf.write('-');
      buf.write(clamped[i]);
    }
    final out = buf.toString();
    return TextEditingValue(
      text: out,
      selection: TextSelection.collapsed(offset: out.length),
    );
  }
}
