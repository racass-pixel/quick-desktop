// Chats store. Holds:
//   - conversations sorted desc by lastMessageAt
//   - per-conversation message lists (oldest-first for display)
//   - active conv id + simple loading flags
//
// WS envelopes are merged in via a subscription set up on construction. Only
// `message`, `read`, `typing`, `conversation_added`, `conversation_removed` are
// handled this pass; other kinds are logged and ignored.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/dto.dart';
import '../api/realtime.dart';
import '../api/services.dart';
import '../store/local_store.dart';
import 'providers.dart' show messagingApiProvider, realtimeProvider, authControllerProvider;

class ChatsState {
  ChatsState({
    this.order = const [],
    this.byId = const {},
    this.messages = const {},
    this.hasMore = const {},
    this.loadingConvs = false,
    this.loadingMessages = const {},
    this.activeConvId,
  });

  final List<String> order;
  final Map<String, Conversation> byId;
  final Map<String, List<Message>> messages;
  final Map<String, bool> hasMore;
  final bool loadingConvs;
  final Map<String, bool> loadingMessages;
  final String? activeConvId;

  ChatsState copyWith({
    List<String>? order,
    Map<String, Conversation>? byId,
    Map<String, List<Message>>? messages,
    Map<String, bool>? hasMore,
    bool? loadingConvs,
    Map<String, bool>? loadingMessages,
    String? activeConvId,
    bool clearActive = false,
  }) =>
      ChatsState(
        order: order ?? this.order,
        byId: byId ?? this.byId,
        messages: messages ?? this.messages,
        hasMore: hasMore ?? this.hasMore,
        loadingConvs: loadingConvs ?? this.loadingConvs,
        loadingMessages: loadingMessages ?? this.loadingMessages,
        activeConvId: clearActive ? null : (activeConvId ?? this.activeConvId),
      );
}

class ChatsController extends StateNotifier<ChatsState> {
  ChatsController(this._ref) : super(ChatsState()) {
    _wsSub = _ref.read(realtimeProvider).envelopes.listen(_onEnvelope);
    // Hydrate from the local store on creation so the first paint reflects
    // cached chats even before ListConversations responds.
    // ignore: discarded_futures
    _hydrateFromStore();
  }

  final Ref _ref;
  StreamSubscription<WsEnvelope>? _wsSub;

  MessagingApi get _api => _ref.read(messagingApiProvider);

  @override
  void dispose() {
    _wsSub?.cancel();
    super.dispose();
  }

  Future<void> _hydrateFromStore() async {
    final store = LocalStore.instanceOrNull;
    if (store == null) return;
    try {
      final cached = await store.hydrateConvs();
      if (cached.isEmpty || !mounted) return;
      // Don't clobber whatever may have already arrived from the network.
      if (state.byId.isNotEmpty) return;
      final byId = <String, Conversation>{for (final c in cached) c.id: c};
      state = state.copyWith(byId: byId, order: _reorder(byId));
    } catch (_) {/* ignore */}
  }

  Future<void> loadConversations() async {
    state = state.copyWith(loadingConvs: true);
    try {
      final convs = await _api.listConversations();
      final byId = <String, Conversation>{for (final c in convs) c.id: c};
      state = state.copyWith(
        byId: byId,
        order: _reorder(byId),
        loadingConvs: false,
      );
      // Write-through: persist the server-authoritative list.
      final store = LocalStore.instanceOrNull;
      if (store != null) {
        // ignore: discarded_futures
        store.persistConvs(convs);
      }
    } catch (_) {
      // Network down — keep showing what we hydrated from disk.
      state = state.copyWith(loadingConvs: false);
    }
  }

  Future<void> loadMessages(
    String convId, {
    String? before,
    int limit = 50,
  }) async {
    if (state.loadingMessages[convId] == true) return;
    state = state.copyWith(
      loadingMessages: {...state.loadingMessages, convId: true},
    );

    // Read-through: surface cached messages first so the thread paints
    // instantly while the network request races.
    final store = LocalStore.instanceOrNull;
    if (store != null && (before == null || before.isEmpty)) {
      final existing = state.messages[convId] ?? const <Message>[];
      if (existing.isEmpty) {
        try {
          final cached = await store.hydrateMessages(convId, limit: limit);
          if (cached.isNotEmpty && mounted) {
            state = state.copyWith(
              messages: {...state.messages, convId: cached},
            );
          }
        } catch (_) {/* ignore */}
      }
    }

    try {
      // Delta fetch: when we have a cached newest message, ask the server only
      // for anything strictly after it. Falls back to a full page when we have
      // nothing local.
      String? afterId;
      if (store != null && (before == null || before.isEmpty)) {
        final newest = await store.latestForChat(convId);
        if (newest != null && newest.id.isNotEmpty) {
          // Skip the delta fetch for now if we already have cached data —
          // a backfill is correct but the wire shape for afterId is small.
          afterId = newest.id;
        }
      }

      final res = await _api.listMessages(
        convId,
        beforeId: before,
        afterId: afterId,
        limit: limit,
      );
      // Server returns newest-first; reverse for display.
      final fresh = res.messages.reversed.toList();
      final existing = state.messages[convId] ?? const <Message>[];
      List<Message> merged;
      if (before != null && before.isNotEmpty) {
        final ids = existing.map((m) => m.id).toSet();
        merged = [...fresh.where((m) => !ids.contains(m.id)), ...existing];
      } else if (afterId != null) {
        final ids = existing.map((m) => m.id).toSet();
        merged = [...existing, ...fresh.where((m) => !ids.contains(m.id))];
      } else {
        merged = fresh;
      }
      state = state.copyWith(
        messages: {...state.messages, convId: merged},
        hasMore: {...state.hasMore, convId: res.hasMore},
      );
      // Write-through: persist the freshly-arrived rows.
      if (store != null && fresh.isNotEmpty) {
        // ignore: discarded_futures
        store.persistMessages(fresh);
      }
    } catch (_) {
      // Network failure — keep whatever was hydrated from disk.
    } finally {
      final next = {...state.loadingMessages}..remove(convId);
      state = state.copyWith(loadingMessages: next);
    }
  }

  void setActiveConv(String? convId) {
    if (convId == null) {
      state = state.copyWith(clearActive: true);
    } else {
      state = state.copyWith(activeConvId: convId);
    }
  }

  Future<Conversation> openDM(String peerUserId) async {
    final conv = await _api.openDM(peerUserId);
    final byId = {...state.byId, conv.id: conv};
    state = state.copyWith(byId: byId, order: _reorder(byId));
    final store = LocalStore.instanceOrNull;
    if (store != null) {
      // ignore: discarded_futures
      store.persistConv(conv);
    }
    return conv;
  }

  Future<void> send(String convId, String body) async {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return;
    final me = _ref.read(authControllerProvider).user;
    final tempId = 'tmp_${DateTime.now().microsecondsSinceEpoch}';
    final pending = Message(
      id: tempId,
      conversationId: convId,
      senderId: me?.id ?? '',
      body: trimmed,
      createdAt: DateTime.now(),
      status: MessageStatus.pending,
      tempId: tempId,
    );
    final existing = state.messages[convId] ?? const <Message>[];
    state = state.copyWith(
      messages: {...state.messages, convId: [...existing, pending]},
    );
    try {
      final real = await _api.sendMessage(convId, trimmed);
      _swapPendingWithReal(convId, tempId, real);
      final store = LocalStore.instanceOrNull;
      if (store != null) {
        // ignore: discarded_futures
        store.persistMessage(real);
      }
    } catch (_) {
      _markFailed(convId, tempId);
    }
  }

  Future<void> markRead(String convId, String lastMsgId) async {
    try {
      await _api.markRead(convId, lastMsgId);
      final conv = state.byId[convId];
      if (conv != null && conv.unreadCount > 0) {
        final next = conv.copyWith(unreadCount: 0);
        state = state.copyWith(byId: {...state.byId, convId: next});
      }
    } catch (_) {/* best-effort */}
  }

  // --- WS handlers -----------------------------------------------------------

  void _onEnvelope(WsEnvelope env) {
    final kind = env['kind'];
    if (kind is! String) return;
    switch (kind) {
      case 'message':
        _applyMessage(env);
        break;
      case 'read':
        _applyRead(env);
        break;
      case 'voice_played':
        _applyVoicePlayed(env);
        break;
      case 'typing':
      case 'conversation_added':
      case 'conversation_removed':
        // conversation_added/removed deserve handling, but conservatively a
        // full ListConversations reload is correct and cheap.
        if (kind == 'conversation_added' || kind == 'conversation_removed') {
          // ignore: discarded_futures
          loadConversations();
        }
        break;
      default:
        // Forward-compat: log and ignore (incoming_call, voice_played, etc.).
        break;
    }
  }

  void _applyMessage(WsEnvelope env) {
    final raw = env['message'];
    if (raw is! Map) return;
    final wire = raw.cast<String, dynamic>();
    final convId = (wire['conversationId'] as String?) ??
        (wire['conversation_id'] as String?) ??
        (env['conversation_id'] as String?) ??
        '';
    if (convId.isEmpty) return;
    // The WS path emits snake_case (cf. quick-web's ws envelopes); the unary
    // ListMessages emits camelCase. Tolerate both at the boundary.
    final normalized = <String, dynamic>{
      'id': wire['id'],
      'conversationId': convId,
      'senderId': wire['senderId'] ?? wire['sender_id'],
      'body': wire['body'],
      'createdAt': wire['createdAt'] ?? wire['created_at'],
      if (wire['kind'] != null) 'kind': wire['kind'],
      if (wire['voice'] != null) 'voice': wire['voice'],
    };
    final msg = Message.fromJson(normalized);
    final existing = state.messages[convId] ?? const <Message>[];
    if (existing.any((m) => m.id == msg.id)) return;

    final me = _ref.read(authControllerProvider).user;
    final isOwn = me != null && msg.senderId == me.id;

    // Self-send dedupe: a freshly-sent message may arrive over WS BEFORE the
    // unary response. Swap any matching pending stub instead of appending.
    if (isOwn) {
      final idx = existing.indexWhere(
        (m) =>
            m.tempId != null &&
            m.body == msg.body &&
            DateTime.now().difference(m.createdAt).inSeconds < 60,
      );
      if (idx >= 0) {
        final next = [...existing];
        next[idx] = msg.copyWith(status: MessageStatus.sent);
        _updateConvPreview(convId, msg, isOwn: true);
        state = state.copyWith(messages: {...state.messages, convId: next});
        return;
      }
    }

    state = state.copyWith(
      messages: {...state.messages, convId: [...existing, msg]},
    );
    _updateConvPreview(convId, msg, isOwn: isOwn);
    final store = LocalStore.instanceOrNull;
    if (store != null) {
      // ignore: discarded_futures
      store.persistMessage(msg);
    }
  }

  void _applyRead(WsEnvelope env) {
    final convId = (env['conversation_id'] as String?) ?? '';
    final byUser = (env['by_user_id'] as String?) ?? '';
    final me = _ref.read(authControllerProvider).user;
    if (convId.isEmpty) return;
    if (me != null && byUser == me.id) {
      final conv = state.byId[convId];
      if (conv != null && conv.unreadCount > 0) {
        state = state.copyWith(
          byId: {...state.byId, convId: conv.copyWith(unreadCount: 0)},
        );
      }
    }
  }

  void _applyVoicePlayed(WsEnvelope env) {
    final convId = (env['conversation_id'] as String?) ??
        (env['conversationId'] as String?) ??
        '';
    final msgId =
        (env['message_id'] as String?) ?? (env['messageId'] as String?) ?? '';
    if (convId.isEmpty || msgId.isEmpty) return;
    final list = state.messages[convId];
    if (list == null) return;
    final idx = list.indexWhere((m) => m.id == msgId);
    if (idx < 0) return;
    final m = list[idx];
    final v = m.voice;
    if (v == null || v.played) return;
    final next = [...list];
    next[idx] = m.copyWith(voice: v.copyWith(played: true));
    state = state.copyWith(messages: {...state.messages, convId: next});
  }

  // --- voice optimistic ------------------------------------------------------

  // Used by VoiceRecorderButton.onLocalVoiceMessage. Inserts a 'voice' message
  // stub with status: pending while the SendVoiceMessage RPC is in flight.
  void appendOptimisticVoice(
    String convId,
    String fileId,
    int durationMs,
    List<int> peaks,
  ) {
    final me = _ref.read(authControllerProvider).user;
    final tempId = 'tmp_${DateTime.now().microsecondsSinceEpoch}_$fileId';
    final voice = VoicePayload(
      fileId: fileId,
      durationMs: durationMs,
      peaks: peaks,
      played: false,
    );
    final m = Message(
      id: tempId,
      conversationId: convId,
      senderId: me?.id ?? '',
      body: '',
      createdAt: DateTime.now(),
      status: MessageStatus.pending,
      tempId: tempId,
      kind: 'voice',
      voice: voice,
    );
    final existing = state.messages[convId] ?? const <Message>[];
    state = state.copyWith(
      messages: {...state.messages, convId: [...existing, m]},
    );
  }

  // Swap the optimistic 'tmp_..._<fileId>' stub for the server-stamped row.
  // Matched by suffix '_<fileId>' on tempId so concurrent uploads can't cross.
  void replaceOptimisticVoice(
    String convId,
    String fileId,
    String serverMessageId,
    DateTime serverCreatedAt,
  ) {
    final list = state.messages[convId];
    if (list == null) return;
    final idx = list.indexWhere(
      (m) => m.tempId != null && m.tempId!.endsWith('_$fileId'),
    );
    if (idx < 0) return;
    // Guard against a WS echo already inserting the real row.
    if (list.any((m) => m.id == serverMessageId && m.tempId == null)) {
      final next = [...list]..removeAt(idx);
      state = state.copyWith(messages: {...state.messages, convId: next});
      return;
    }
    final old = list[idx];
    final next = [...list];
    next[idx] = old.copyWith(
      id: serverMessageId,
      createdAt: serverCreatedAt,
      status: MessageStatus.sent,
    );
    state = state.copyWith(messages: {...state.messages, convId: next});
  }

  // --- helpers ---------------------------------------------------------------

  void _swapPendingWithReal(String convId, String tempId, Message real) {
    final msgs = state.messages[convId] ?? const <Message>[];
    final idx = msgs.indexWhere((m) => m.tempId == tempId);
    if (idx < 0) return;
    final next = [...msgs];
    // Guard against a WS echo already inserting the real message.
    if (msgs.any((m) => m.id == real.id && m.tempId == null)) {
      next.removeAt(idx);
    } else {
      next[idx] = real.copyWith(status: MessageStatus.sent);
    }
    state = state.copyWith(messages: {...state.messages, convId: next});
    _updateConvPreview(convId, real, isOwn: true);
  }

  void _markFailed(String convId, String tempId) {
    final msgs = state.messages[convId] ?? const <Message>[];
    final idx = msgs.indexWhere((m) => m.tempId == tempId);
    if (idx < 0) return;
    final next = [...msgs];
    next[idx] = msgs[idx].copyWith(status: MessageStatus.failed);
    state = state.copyWith(messages: {...state.messages, convId: next});
  }

  void _updateConvPreview(String convId, Message msg, {required bool isOwn}) {
    final conv = state.byId[convId];
    if (conv == null) return;
    final isActive = state.activeConvId == convId;
    final unread = (isActive || isOwn) ? conv.unreadCount : conv.unreadCount + 1;
    final next = conv.copyWith(
      lastMessageAt: msg.createdAt,
      preview: msg,
      unreadCount: unread,
    );
    final byId = {...state.byId, convId: next};
    state = state.copyWith(byId: byId, order: _reorder(byId));
  }

  List<String> _reorder(Map<String, Conversation> byId) {
    final list = byId.values.toList();
    list.sort((a, b) {
      final ax = a.lastMessageAt?.millisecondsSinceEpoch ?? 0;
      final bx = b.lastMessageAt?.millisecondsSinceEpoch ?? 0;
      return bx.compareTo(ax);
    });
    return list.map((c) => c.id).toList();
  }
}

final chatsControllerProvider =
    StateNotifierProvider<ChatsController, ChatsState>((ref) => ChatsController(ref));
