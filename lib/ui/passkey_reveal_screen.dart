// One-time reveal of a freshly-minted passkey. Shown right after signup, with
// the session already stored — leaving the screen without saving the passkey
// means the user can still chat now but can't ever log back in.
//
// We make the "saved it" affirmation explicit (a required checkbox) so the
// Continue button can't be clicked through. Copy and download both shove the
// same string into reach so users have at least one easy escape from the
// "lost forever" failure mode.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import '../theme/theme.dart';

class PasskeyRevealScreen extends StatefulWidget {
  const PasskeyRevealScreen({
    super.key,
    required this.email,
    required this.passkey,
  });

  final String email;
  final String passkey;

  @override
  State<PasskeyRevealScreen> createState() => _PasskeyRevealScreenState();
}

class _PasskeyRevealScreenState extends State<PasskeyRevealScreen> {
  bool _acknowledged = false;
  bool _showCopied = false;
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
                InkWell(
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
                const SizedBox(height: 18),
                ElevatedButton(
                  onPressed: _acknowledged ? () => context.go('/') : null,
                  child: const Text('Continue to Quick'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
