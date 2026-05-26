// WS → Toaster bridge. Subscribes to the realtime envelope stream and emits
// in-app toasts for events the user would want to know about while doing
// something else in the app:
//   - new message in a chat that is not currently focused
//   - incoming 1:1 call (sticky toast with Accept / Decline)
//   - group call started in one of our chats (Join toast)
//
// Suppression rules:
//   - Skip message toasts when our own user sent the message.
//   - Skip message toasts when the window is focused AND the message belongs
//     to the conversation the user is currently viewing.
//   - Always show call-related toasts — those are the whole point of keeping
//     the WS alive while minimized to the tray.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../api/dto.dart';
import '../api/realtime.dart';
import '../features/calls/state/call_state.dart';
import '../services/toaster.dart';
import '../state/chats_controller.dart';
import '../state/providers.dart';
import '../state/window_focus.dart';

class NotificationsBridge {
  NotificationsBridge(this._ref) {
    _sub = _ref.read(realtimeProvider).envelopes.listen(_onEnvelope);
  }

  final Ref _ref;
  StreamSubscription<WsEnvelope>? _sub;

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
        // Drop any sticky incoming-call toast for this call id.
        final id = _str(env, 'call_id', 'callId');
        if (id.isNotEmpty) {
          Toaster.instance.dismiss('incoming-call:$id');
        }
        break;
      case 'group_call_started':
        _onGroupCallStarted(env);
        break;
      case 'group_call_ended':
        final convId = _str(env, 'conversation_id', 'conversationId');
        if (convId.isNotEmpty) {
          Toaster.instance.dismiss('group-call:$convId');
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
  }
}

final notificationsBridgeProvider = Provider<NotificationsBridge>((ref) {
  final b = NotificationsBridge(ref);
  ref.onDispose(b.dispose);
  return b;
});
