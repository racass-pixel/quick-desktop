import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/connect.dart';
import '../state/providers.dart';
import '../theme/theme.dart';

class VerifyScreen extends ConsumerStatefulWidget {
  const VerifyScreen({super.key, required this.email});
  final String email;
  @override
  ConsumerState<VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyScreenState extends ConsumerState<VerifyScreen> {
  // Six independent single-character inputs that behave as a single 6-digit
  // code field — autoadvance on input, backspace returns focus to previous.
  late final List<TextEditingController> _ctrls;
  late final List<FocusNode> _nodes;
  bool _busy = false;
  String? _error;
  int _cooldown = 0;
  Timer? _cooldownTimer;

  @override
  void initState() {
    super.initState();
    _ctrls = List.generate(6, (_) => TextEditingController());
    _nodes = List.generate(6, (_) => FocusNode());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _nodes.first.requestFocus();
    });
    _startCooldown(30);
  }

  @override
  void dispose() {
    for (final c in _ctrls) {
      c.dispose();
    }
    for (final n in _nodes) {
      n.dispose();
    }
    _cooldownTimer?.cancel();
    super.dispose();
  }

  void _startCooldown(int seconds) {
    _cooldownTimer?.cancel();
    setState(() => _cooldown = seconds);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (_cooldown <= 1) {
        t.cancel();
        setState(() => _cooldown = 0);
      } else {
        setState(() => _cooldown--);
      }
    });
  }

  String get _code => _ctrls.map((c) => c.text).join();

  void _onChanged(int i, String v) {
    if (v.length > 1) {
      // Paste path.
      final digits = v.replaceAll(RegExp(r'\D'), '');
      for (var k = 0; k < 6; k++) {
        _ctrls[k].text = k < digits.length ? digits[k] : '';
      }
      if (digits.length >= 6) {
        _nodes.last.requestFocus();
        _submit();
      } else {
        _nodes[digits.length.clamp(0, 5)].requestFocus();
      }
      return;
    }
    if (v.isNotEmpty && i < 5) {
      _nodes[i + 1].requestFocus();
    }
    if (_code.length == 6) _submit();
  }

  KeyEventResult _onKey(int i, FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.backspace &&
        _ctrls[i].text.isEmpty &&
        i > 0) {
      _nodes[i - 1].requestFocus();
      _ctrls[i - 1].clear();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _submit() async {
    if (_busy) return;
    final code = _code;
    if (code.length != 6) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await ref.read(authApiProvider).verifyCode(widget.email, code);
      if (res.token.isEmpty) {
        setState(() => _error = 'Server returned no token.');
        return;
      }
      await ref.read(authControllerProvider.notifier).onVerified(res.token, res.user);
      if (!mounted) return;
      context.go('/');
    } on ConnectError catch (e) {
      setState(() => _error = e.message.isNotEmpty ? e.message : 'Invalid code.');
      // Clear inputs so the user can retry.
      for (final c in _ctrls) {
        c.clear();
      }
      _nodes.first.requestFocus();
    } catch (_) {
      setState(() => _error = 'Network error.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    if (_cooldown > 0 || _busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(authApiProvider).requestCode(widget.email);
      _startCooldown(30);
    } catch (_) {/* swallow */} finally {
      if (mounted) setState(() => _busy = false);
    }
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
                Text('Check your email',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 6),
                Text(
                  widget.email,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.ink2,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (var i = 0; i < 6; i++)
                      SizedBox(
                        width: 48,
                        child: Focus(
                          onKeyEvent: (n, e) => _onKey(i, n, e),
                          child: TextField(
                            controller: _ctrls[i],
                            focusNode: _nodes[i],
                            enabled: !_busy,
                            textAlign: TextAlign.center,
                            keyboardType: TextInputType.number,
                            maxLength: 1,
                            style: const TextStyle(
                                fontSize: 22, fontWeight: FontWeight.w600),
                            decoration: const InputDecoration(
                              counterText: '',
                              contentPadding:
                                  EdgeInsets.symmetric(vertical: 14),
                            ),
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            onChanged: (v) => _onChanged(i, v),
                          ),
                        ),
                      ),
                  ],
                ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(_error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.err, fontSize: 12)),
                ],
                const SizedBox(height: 18),
                ElevatedButton(
                  onPressed: _busy || _code.length != 6 ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Verify'),
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _cooldown > 0
                          ? 'Resend code in ${_cooldown}s'
                          : "Didn't get it?",
                      style: const TextStyle(color: AppColors.ink3, fontSize: 12),
                    ),
                    if (_cooldown == 0) ...[
                      const SizedBox(width: 6),
                      TextButton(
                        onPressed: _busy ? null : _resend,
                        child: const Text('Resend'),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                TextButton(
                  onPressed: _busy ? null : () => context.go('/login'),
                  child: const Text('Use a different email'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
