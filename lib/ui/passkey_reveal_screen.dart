// One-time reveal of a freshly-minted passkey. Shown right after signup, BEFORE
// the auth state flips to signedIn — that way the router's redirect can't race
// past this screen. The session token and user came back from the server
// already; we hold them locally and write them into auth state only when the
// user has acknowledged they saved the passkey (then we navigate to /).
//
// We make the "saved it" affirmation explicit (a required checkbox) so the
// Continue button can't be clicked through. Copy and download both shove the
// same string into reach so users have at least one easy escape from the
// "lost forever" failure mode.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import '../api/dto.dart';
import '../state/providers.dart';
import '../theme/theme.dart';

class PasskeyRevealScreen extends ConsumerStatefulWidget {
  const PasskeyRevealScreen({
    super.key,
    required this.email,
    required this.result,
  });

  // Email is carried separately because the User record on the server response
  // doesn't include it — the reveal copy mentions which account was created.
  final String email;
  final SignupWithPasskeyResult result;

  String get passkey => result.passkey;

  @override
  ConsumerState<PasskeyRevealScreen> createState() =>
      _PasskeyRevealScreenState();
}

class _PasskeyRevealScreenState extends ConsumerState<PasskeyRevealScreen> {
  bool _acknowledged = false;
  bool _showCopied = false;
  bool _finishing = false;
  String? _toast;

  // Insert middle dots between the 4-char groups for the on-screen rendering
  // only — the clipboard / download payload stays the canonical hyphenated
  // form so the user can paste it straight back into the login field.
  String _displayed(String s) {
    final groups = s.split('-');
    return groups.join('   ');
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.passkey));
    if (!mounted) return;
    setState(() {
      _showCopied = true;
      _toast = 'Copied';
    });
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() {
        _showCopied = false;
        _toast = null;
      });
    });
  }

  Future<void> _download() async {
    try {
      // Prefer the user's Documents folder; fall back to the app documents
      // directory if Documents isn't resolvable on this platform.
      Directory? dir;
      try {
        dir = await getApplicationDocumentsDirectory();
      } catch (_) {
        dir = await getTemporaryDirectory();
      }
      final safeEmail = widget.email.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final file = File('${dir.path}${Platform.pathSeparator}'
          '$safeEmail-quick-passkey.txt');
      await file.writeAsString(
        'Quick passkey for ${widget.email}\n'
        '${widget.passkey}\n\n'
        'Keep this file private. Anyone with this passkey can sign in as you.\n',
        flush: true,
      );
      if (!mounted) return;
      setState(() => _toast = 'Saved to ${file.path}');
      Future<void>.delayed(const Duration(seconds: 3), () {
        if (!mounted) return;
        setState(() => _toast = null);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _toast = 'Could not save file');
    }
  }

  // Writes the session that the server already minted into the AuthController
  // and navigates to the shell. We swallow non-network errors silently here —
  // the worst case is the user has to enter their freshly-saved passkey on the
  // login screen, which is fine.
  Future<void> _finish() async {
    setState(() => _finishing = true);
    try {
      await ref
          .read(authControllerProvider.notifier)
          .completeSignup(widget.result);
      if (!mounted) return;
      context.go('/');
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _finishing = false;
        _toast = 'Could not finish sign-in. Try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Container(
            padding: const EdgeInsets.all(32),
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
                  'Account created',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 10),
                Text(
                  widget.email,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.ink2, fontSize: 13),
                ),
                const SizedBox(height: 18),
                RichText(
                  textAlign: TextAlign.center,
                  text: const TextSpan(
                    style: TextStyle(
                        color: AppColors.ink2, fontSize: 13, height: 1.45),
                    children: [
                      TextSpan(text: 'This is your passkey. '),
                      TextSpan(
                        text: 'Save it now',
                        style: TextStyle(
                          color: AppColors.ink1,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextSpan(
                          text:
                              " — you'll need it to log back in. We can't recover it for you."),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 24),
                  decoration: BoxDecoration(
                    color: AppColors.ember.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(AppRadii.rMd),
                    border: Border.all(color: AppColors.ember),
                  ),
                  child: SelectableText(
                    _displayed(widget.passkey),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      fontFamilyFallback: ['Courier New', 'monospace'],
                      fontSize: 32,
                      fontWeight: FontWeight.w600,
                      color: AppColors.ink1,
                      letterSpacing: 2.0,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _copy,
                        icon: Icon(
                          _showCopied ? Icons.check : Icons.copy,
                          size: 16,
                          color: AppColors.ember,
                        ),
                        label: Text(
                          _showCopied ? 'Copied' : 'Copy',
                          style: const TextStyle(color: AppColors.ember),
                        ),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          side: const BorderSide(color: AppColors.ember),
                          shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(AppRadii.rMd),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _download,
                        icon: const Icon(Icons.download,
                            size: 16, color: AppColors.ember),
                        label: const Text(
                          'Download as .txt',
                          style: TextStyle(color: AppColors.ember),
                        ),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          side: const BorderSide(color: AppColors.ember),
                          shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(AppRadii.rMd),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                if (_toast != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _toast!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.ink2, fontSize: 12),
                  ),
                ],
                const SizedBox(height: 22),
                Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(AppRadii.rSm),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () =>
                        setState(() => _acknowledged = !_acknowledged),
                    borderRadius: BorderRadius.circular(AppRadii.rSm),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 22,
                            height: 22,
                            child: Checkbox(
                              value: _acknowledged,
                              onChanged: (v) =>
                                  setState(() => _acknowledged = v ?? false),
                              activeColor: AppColors.ember,
                              side: const BorderSide(color: AppColors.ink3),
                            ),
                          ),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'I have saved my passkey',
                              style: TextStyle(
                                  color: AppColors.ink1, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                ElevatedButton(
                  onPressed: (_acknowledged && !_finishing) ? _finish : null,
                  child: _finishing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Continue to Quick'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
