// In-app notification toaster. Owns a small list of active toasts and a
// broadcast stream the overlay subscribes to. Auto-dismiss is scheduled per
// toast; pausing/resuming on hover is done by the overlay (it calls
// pauseTimer / resumeTimer).

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/dto.dart';

enum ToastKind { text, incomingCall, groupCallStarted }

@immutable
class ToastSpec {
  const ToastSpec({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.avatarSeed,
    required this.avatarColorHex,
    this.autoDismissMs = 4000,
    this.conversationId,
    this.callId,
    this.video = false,
    this.onTap,
    this.onAccept,
    this.onDecline,
    this.onJoin,
  });

  final String id;
  final ToastKind kind;
  final String title;
  final String body;
  final String avatarSeed;
  final String avatarColorHex;
  // 0 means sticky — only dismissed via explicit dismiss() or the X tap.
  final int autoDismissMs;
  // Routing target. For text / group_call_started this is where onTap navigates.
  final String? conversationId;
  // For incomingCall / groupCallStarted we keep enough context to trigger the
  // action without re-walking the WS envelope from the bridge.
  final String? callId;
  final bool video;
  final void Function()? onTap;
  final void Function()? onAccept;
  final void Function()? onDecline;
  final void Function()? onJoin;
}

class Toaster {
  Toaster._();
  static final Toaster instance = Toaster._();

  final _ctrl = StreamController<List<ToastSpec>>.broadcast();
  final List<ToastSpec> _toasts = [];
  final Map<String, Timer> _timers = {};

  static const int maxVisible = 3;

  Stream<List<ToastSpec>> get toasts => _ctrl.stream;
  List<ToastSpec> get current => List.unmodifiable(_toasts);

  void show(ToastSpec spec) {
    // Replace any existing toast with the same id (e.g. an incoming-call toast
    // being re-emitted after a transient WS reconnect).
    _cancelTimer(spec.id);
    final idx = _toasts.indexWhere((t) => t.id == spec.id);
    if (idx >= 0) {
      _toasts[idx] = spec;
    } else {
      _toasts.add(spec);
      // Evict the oldest when we exceed maxVisible — the overlay caps the
      // visible window separately, but trimming here keeps memory bounded
      // if the WS storms us.
      while (_toasts.length > maxVisible + 2) {
        final old = _toasts.removeAt(0);
        _cancelTimer(old.id);
      }
    }
    if (spec.autoDismissMs > 0) {
      _timers[spec.id] =
          Timer(Duration(milliseconds: spec.autoDismissMs), () => dismiss(spec.id));
    }
    _ctrl.add(List.unmodifiable(_toasts));
  }

  void dismiss(String id) {
    _cancelTimer(id);
    final idx = _toasts.indexWhere((t) => t.id == id);
    if (idx < 0) return;
    _toasts.removeAt(idx);
    _ctrl.add(List.unmodifiable(_toasts));
  }

  void dismissWhere(bool Function(ToastSpec) test) {
    final ids = _toasts.where(test).map((t) => t.id).toList();
    for (final id in ids) {
      dismiss(id);
    }
  }

  /// Hover-pause: cancel the auto-dismiss timer but leave the toast in place.
  void pauseTimer(String id) {
    _cancelTimer(id);
  }

  /// Hover-leave: re-arm the timer with the spec's original duration.
  void resumeTimer(String id) {
    final spec = _toasts.firstWhere(
      (t) => t.id == id,
      orElse: () => const ToastSpec(
        id: '',
        kind: ToastKind.text,
        title: '',
        body: '',
        avatarSeed: '',
        avatarColorHex: '#6F7180',
      ),
    );
    if (spec.id.isEmpty) return;
    if (spec.autoDismissMs <= 0) return;
    _cancelTimer(id);
    _timers[id] =
        Timer(Duration(milliseconds: spec.autoDismissMs), () => dismiss(id));
  }

  void _cancelTimer(String id) {
    _timers.remove(id)?.cancel();
  }

  void dispose() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _toasts.clear();
    _ctrl.close();
  }
}

// Utility builder so the bridge can produce text toasts without restating the
// avatar palette for every message.
ToastSpec buildMessageToast({
  required String id,
  required String conversationId,
  required String title,
  required Message message,
  required String avatarSeed,
  required String avatarColorHex,
  void Function()? onTap,
}) {
  final preview = _previewFor(message);
  return ToastSpec(
    id: id,
    kind: ToastKind.text,
    title: title,
    body: preview,
    avatarSeed: avatarSeed,
    avatarColorHex: avatarColorHex,
    conversationId: conversationId,
    onTap: onTap,
  );
}

String _previewFor(Message m) {
  if (m.kind == 'voice') return 'Voice message';
  final body = m.body.trim();
  if (body.isEmpty) return '…';
  return body;
}
