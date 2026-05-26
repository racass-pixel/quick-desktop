// WS -> Toaster bridge. Subscribes to the realtime envelope stream and emits
// notifications for events the user would want to know about while doing
// something else in the app:
//   - new message in a chat that is not currently focused
//   - incoming 1:1 call (sticky toast with Accept / Decline)
//   - group call started in one of our chats (Join toast)
//
// Output routing:
//   - When the Quick window is focused (and not minimized to tray), use the
//     in-app Toaster -- the user is here, so a soft in-app banner is best.
//   - When the window is hidden / minimized / unfocused, fire a real Windows
//     toast via OsNotifier so the user sees it from another app or after
//     coming back to the desk.
//   - Calls (incoming + group call started) ALWAYS fire the OS toast in
//     addition to the in-app toast. Calls are urgent and the user might be
//     in another app even if Quick happens to be focused on a second monitor.
//
// Suppression rules:
//   - Skip message toasts when our own user sent the message.
//   - Skip message toasts when the window is focused AND the message belongs
//     to the conversation the user is currently viewing.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../api/dto.dart';
import '../api/realtime.dart';
import '../features/calls/state/call_state.dart';
import '../services/os_notifier.dart';
import '../services/toaster.dart';
import '../state/chats_controller.dart';
import '../state/providers.dart';
import '../state/window_focus.dart';

class NotificationsBridge {
  NotificationsBridge(this._ref) {
    _sub = _ref.read(realtimeProvider).envelopes.listen(_onEnvelope);
    // Activations come from the OS toast layer (user clicked the toast or one
    // of its buttons). The bridge owns the routing because it already has the
    // chat / call notifier handles in scope.
    _activationSub = OsNotifier.instance.activations.listen(_onActivation);
  }

  final Ref _ref;
  StreamSubscription<WsEnvelope>? _sub;
  StreamSubscription<NotificationActivation>? _activationSub;

  /// Set by the shell once GoRouter is mounted. The bridge invokes it to
  /// navigate when the user clicks a toast. Held as a function so the bridge
  /// has zero coupling to go_router.
  static void Function(String conversationId)? onOpenChat;

  Future<void> _onEnvelope(WsEnvelope env) async {
    final kind = env['kind'];
    if (kind is! String) return;
    switch (kind) {
      case 'message':
        _onMessage(env);
        break;
      case 'incoming_call':
        _onIncomingCall(env);
        break;
      case 'call_ended':
      case 'call_declined':
        // Drop any sticky incoming-call toast for this call id, both in-app
        // and in the OS notification center.
        final id = _str(env, 'call_id', 'callId');
        if (id.isNotEmpty) {
          Toaster.instance.dismiss('incoming-call:$id');
          // ignore: discarded_futures
          OsNotifier.instance.dismiss('incoming-call:$id');
        }
        break;
      case 'group_call_started':
        _onGroupCallStarted(env);
        break;
      case 'group_call_ended':
        final convId = _str(env, 'conversation_id', 'conversationId');
        if (convId.isNotEmpty) {
          Toaster.instance.dismiss('group-call:$convId');
          // ignore: discarded_futures
          OsNotifier.instance.dismiss('group-call:$convId');
        }
        break;
      default:
        break;
    }
  }

  void _onMessage(WsEnvelope env) {
    final raw = env['message'];
    if (raw is! Map) return;
    final wire = raw.cast<String, dynamic>();
    final convId = (wire['conversationId'] as String?) ??
        (wire['conversation_id'] as String?) ??
        (env['conversation_id'] as String?) ??
        '';
    if (convId.isEmpty) return;
    final me = _ref.read(authControllerProvider).user;
    final senderId =
        (wire['senderId'] as String?) ?? (wire['sender_id'] as String?) ?? '';
    if (me != null && senderId == me.id) return; // never toast our own sends

    final chats = _ref.read(chatsControllerProvider);
    final focused = _ref.read(windowFocusedProvider);
    // Only the "already viewing this chat" suppression rule applies in the
    // focused branch -- when the window is hidden the user is by definition
    // not viewing anything, so we always notify.
    if (focused && chats.activeConvId == convId) return;

    // Build a synthetic Message for the preview path.
    final normalized = <String, dynamic>{
      'id': wire['id'],
      'conversationId': convId,
      'senderId': senderId,
      'body': wire['body'],
      'createdAt': wire['createdAt'] ?? wire['created_at'],
      if (wire['kind'] != null) 'kind': wire['kind'],
      if (wire['voice'] != null) 'voice': wire['voice'],
    };
    final msg = Message.fromJson(normalized);

    final conv = chats.byId[convId];
    final title = _titleFor(conv: conv, senderId: senderId);
    final seedColor = _seedColorFor(conv: conv, senderId: senderId);

    // For group chats, prepend "Sender: " to the body so the user can tell
    // who said what before opening the toast.
    String body;
    final isGroup = conv != null && conv.type != 'dm';
    if (isGroup && msg.kind != 'voice') {
      final senderName = _senderNameFromConv(conv, senderId);
      final preview = msg.body.trim().isEmpty ? '…' : msg.body.trim();
      body = senderName.isEmpty ? preview : '$senderName: $preview';
    } else {
      body = msg.kind == 'voice'
          ? 'Voice message'
          : (msg.body.trim().isEmpty ? '…' : msg.body.trim());
    }

    final id = 'msg:$convId:${msg.id}';
    if (focused) {
      // Window is here -- give the user a soft in-app toast they can interact
      // with without losing context.
      Toaster.instance.show(ToastSpec(
        id: id,
        kind: ToastKind.text,
        title: title,
        body: body,
        avatarSeed: seedColor.$1,
        avatarColorHex: seedColor.$2,
        conversationId: convId,
        onTap: () => _navigateToChat(convId),
      ));
    } else {
      // Window is hidden / minimized to tray / unfocused -- the user isn't
      // looking at us, so we go through the OS notification surface so the
      // alert shows up in the Action Center and on the desktop.
      // ignore: discarded_futures
      OsNotifier.instance.show(
        id: id,
        title: title,
        body: body,
        kind: NotificationKind.message,
        data: {'conversationId': convId},
      );
    }
  }

  void _onIncomingCall(WsEnvelope env) {
    final id = _str(env, 'call_id', 'callId');
    if (id.isEmpty) return;
    final video = env['video'] == true;
    final callerRaw = env['caller_user'] ?? env['callerUser'];
    String name = 'Caller';
    String avatarSeed = 'Caller';
    String avatarColor = '#6F7180';
    CallPeer peer;
    if (callerRaw is Map) {
      final m = callerRaw.cast<String, dynamic>();
      peer = CallPeer.fromJson(m);
      name = peer.displayName.isNotEmpty ? peer.displayName : 'Caller';
      avatarSeed = name;
      avatarColor = peer.avatarColor ?? avatarColor;
    } else {
      peer = CallPeer(
        id: _str(env, 'caller_id', 'callerId'),
        displayName: 'Caller',
      );
    }
    if (peer.id.isEmpty) return;

    Toaster.instance.show(ToastSpec(
      id: 'incoming-call:$id',
      kind: ToastKind.incomingCall,
      title: 'Incoming ${video ? 'video ' : ''}call',
      body: name,
      avatarSeed: avatarSeed,
      avatarColorHex: avatarColor,
      // Sticky — dismissed when the ring resolves or the user reacts.
      autoDismissMs: 0,
      callId: id,
      video: video,
      onAccept: () async {
        await _bringToFront();
        try {
          await _ref.read(callNotifierProvider).acceptIncoming();
        } catch (_) {/* error UX lives on the dialog */}
      },
      onDecline: () async {
        try {
          await _ref.read(callNotifierProvider).declineIncoming();
        } catch (_) {/* best effort */}
      },
    ));

    // Always also raise an OS toast for incoming calls. The user might be in
    // another app even if the Quick window is technically focused (multi-
    // monitor setups), and the Action Center entry is a useful safety net if
    // they miss the ring.
    // ignore: discarded_futures
    OsNotifier.instance.show(
      id: 'incoming-call:$id',
      title: 'Incoming ${video ? 'video ' : ''}call',
      body: name,
      kind: NotificationKind.incomingCall,
      data: {'callId': id},
    );
  }

  void _onGroupCallStarted(WsEnvelope env) {
    final convId = _str(env, 'conversation_id', 'conversationId');
    final callId = _str(env, 'call_id', 'callId');
    if (convId.isEmpty || callId.isEmpty) {
      // Some envelopes nest the call object — try that path too.
      final callRaw = env['call'];
      if (callRaw is Map) {
        final m = callRaw.cast<String, dynamic>();
        final nestedConv = (m['conversationId'] as String?) ??
            (m['conversation_id'] as String?) ??
            '';
        final nestedCall = (m['id'] as String?) ?? '';
        if (nestedConv.isNotEmpty && nestedCall.isNotEmpty) {
          _emitGroupCallToast(nestedConv, nestedCall);
        }
      }
      return;
    }
    _emitGroupCallToast(convId, callId);
  }

  void _emitGroupCallToast(String convId, String callId) {
    final chats = _ref.read(chatsControllerProvider);
    final conv = chats.byId[convId];
    final title = conv?.displayTitle() ?? 'Group';
    Toaster.instance.show(ToastSpec(
      id: 'group-call:$convId',
      kind: ToastKind.groupCallStarted,
      title: title,
      body: 'Voice chat started',
      avatarSeed: conv?.avatarSeed() ?? title,
      avatarColorHex: conv?.avatarColorHex() ?? '#6F7180',
      autoDismissMs: 10000,
      conversationId: convId,
      callId: callId,
      onTap: () => _navigateToChat(convId),
      onJoin: () async {
        await _bringToFront();
        try {
          // ignore: discarded_futures
          _ref
              .read(groupCallNotifierProvider)
              .joinGroupCall(callId, convId);
        } catch (_) {/* surface via banner */}
        _navigateToChat(convId);
      },
    ));

    // Always also raise an OS toast for group calls -- same reasoning as the
    // 1:1 incoming-call path. The Join button on the OS toast lets the user
    // jump in without restoring the window first.
    // ignore: discarded_futures
    OsNotifier.instance.show(
      id: 'group-call:$convId',
      title: title,
      body: 'Voice chat started',
      kind: NotificationKind.groupCall,
      data: {'conversationId': convId, 'callId': callId},
    );
  }

  Future<void> _onActivation(NotificationActivation a) async {
    switch (a.kind) {
      case NotificationKind.message:
        final convId = a.data['conversationId'] ?? '';
        if (convId.isEmpty) return;
        await _bringToFront();
        _navigateToChat(convId);
        break;
      case NotificationKind.incomingCall:
        if (a.action == 'accept') {
          await _bringToFront();
          try {
            await _ref.read(callNotifierProvider).acceptIncoming();
          } catch (_) {/* error UX lives on the dialog */}
        } else if (a.action == 'decline') {
          // No window restore on decline -- the user is choosing to dismiss
          // without engaging, dragging Quick to the front would be hostile.
          try {
            await _ref.read(callNotifierProvider).declineIncoming();
          } catch (_) {/* best effort */}
        } else {
          // Plain body click -- treat as "show me the call" so the incoming
          // dialog can be answered with the in-app controls.
          await _bringToFront();
        }
        break;
      case NotificationKind.groupCall:
        final convId = a.data['conversationId'] ?? '';
        final callId = a.data['callId'] ?? '';
        if (a.action == 'join') {
          if (callId.isEmpty || convId.isEmpty) return;
          await _bringToFront();
          try {
            // ignore: discarded_futures
            _ref
                .read(groupCallNotifierProvider)
                .joinGroupCall(callId, convId);
          } catch (_) {/* surface via banner */}
          _navigateToChat(convId);
        } else if (convId.isNotEmpty) {
          await _bringToFront();
          _navigateToChat(convId);
        }
        break;
    }
  }

  Future<void> _bringToFront() async {
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {/* ignore */}
  }

  void _navigateToChat(String convId) {
    final fn = onOpenChat;
    if (fn != null) {
      fn(convId);
      return;
    }
  }

  String _titleFor({Conversation? conv, required String senderId}) {
    if (conv == null) return 'New message';
    return conv.displayTitle();
  }

  // For DM avatars we use the peer; for groups we use the group's seed.
  (String, String) _seedColorFor({
    Conversation? conv,
    required String senderId,
  }) {
    if (conv == null) return ('?', '#6F7180');
    final seed = conv.avatarSeed();
    final color = conv.avatarColorHex();
    return (seed, color);
  }

  // Best-effort sender label for group chats. We don't have a full members map
  // wired into ChatsState yet, so DMs surface as the peer name and groups fall
  // back to no prefix when we can't resolve the sender locally.
  String _senderNameFromConv(Conversation conv, String senderId) {
    final peer = conv.peer;
    if (peer != null && peer.id == senderId) {
      return peer.displayName.isNotEmpty ? peer.displayName : '@${peer.handle}';
    }
    return '';
  }

  String _str(Map<String, dynamic> env, String a, String b) {
    final va = env[a];
    if (va is String && va.isNotEmpty) return va;
    final vb = env[b];
    if (vb is String && vb.isNotEmpty) return vb;
    return '';
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    await _activationSub?.cancel();
    _activationSub = null;
  }
}

final notificationsBridgeProvider = Provider<NotificationsBridge>((ref) {
  final b = NotificationsBridge(ref);
  ref.onDispose(b.dispose);
  return b;
});
