// Chat view: top bar with peer name, scrollable message list with day
// separators, ticks for own messages, bottom text composer with voice toggle.
// Loads the page on mount; older pages are fetched as the user scrolls to the
// top.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../api/dto.dart';
import '../features/calls/screens/group_call_banner.dart';
import '../features/calls/state/call_state.dart';
import '../features/groups/widgets/group_info_modal.dart';
import '../api/media_upload.dart';
import '../features/messaging/attachments/attach_button.dart';
import '../features/messaging/attachments/file_bubble.dart';
import '../features/messaging/attachments/image_bubble.dart';
import '../features/messaging/attachments/upload_progress.dart';
import '../features/messaging/attachments/upload_state.dart';
import '../features/messaging/forward/forward_modal.dart';
import '../features/messaging/reactions/reaction_picker.dart';
import '../features/messaging/reactions/reaction_strip.dart';
import '../features/messaging/replies/reply_compose_pill.dart';
import '../features/messaging/replies/reply_quote_block.dart';
import '../features/messaging/search/search_bar.dart';
import '../features/messaging/search/search_results.dart';
import '../features/voice/widgets/voice_bubble.dart' as vw;
import '../features/voice/widgets/voice_recorder_button.dart';
import '../features/settings/widgets/profile_modal.dart';
import '../state/chats_controller.dart';
import '../state/providers.dart';
import '../theme/theme.dart';
import 'service_message.dart';
import 'widgets/avatar.dart';

class ChatView extends ConsumerStatefulWidget {
  const ChatView({super.key, required this.conversationId});
  final String conversationId;
  @override
  ConsumerState<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends ConsumerState<ChatView> {
  final _scroll = ScrollController();
  final _composer = TextEditingController();
  final _composerFocus = FocusNode();
  bool _loadingOlder = false;
  // Debounce per-id so a re-render mid-play doesn't fire MarkPlayed twice.
  final Set<String> _firedPlay = <String>{};
  // Tracks whether the composer has any text — drives the voice/send toggle.
  bool _hasText = false;
  // Inline 3-second error pill in the composer for voice flow failures.
  String? _voiceError;
  // Per-chat-view upload queue. Files are appended as the user picks them
  // and drained into `attachmentFileIds` when the next message is sent.
  final UploadQueue _uploads = UploadQueue();
  // In-pane search state — driven by the magnifier toggle in the top bar.
  bool _searchOpen = false;
  String _searchQuery = '';
  List<Message> _searchResults = const [];
  bool _searchBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
    _scroll.addListener(_onScroll);
    _composer.addListener(_onComposerChanged);
  }

  @override
  void didUpdateWidget(covariant ChatView old) {
    super.didUpdateWidget(old);
    if (old.conversationId != widget.conversationId) {
      _bootstrap();
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _composer.removeListener(_onComposerChanged);
    _scroll.dispose();
    _composer.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  void _onComposerChanged() {
    final has = _composer.text.trim().isNotEmpty;
    if (has != _hasText) {
      setState(() => _hasText = has);
    }
  }

  void _bootstrap() {
    final ctrl = ref.read(chatsControllerProvider.notifier);
    ctrl.setActiveConv(widget.conversationId);
    final msgs = ref.read(chatsControllerProvider).messages[widget.conversationId];
    if (msgs == null || msgs.isEmpty) {
      // ignore: discarded_futures
      ctrl.loadMessages(widget.conversationId);
    }
    // Try to mark the most recent message read.
    final byId = ref.read(chatsControllerProvider).byId[widget.conversationId];
    if (byId != null && byId.preview != null) {
      // ignore: discarded_futures
      ctrl.markRead(widget.conversationId, byId.preview!.id);
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    // Reverse list: scrolling "up" actually grows the offset. Trigger when we
    // approach the bottom of the reversed list (oldest end).
    if (_scroll.position.pixels >=
            _scroll.position.maxScrollExtent - 200 &&
        !_loadingOlder) {
      _loadOlder();
    }
  }

  Future<void> _loadOlder() async {
    final state = ref.read(chatsControllerProvider);
    final hasMore = state.hasMore[widget.conversationId] ?? false;
    if (!hasMore) return;
    final list = state.messages[widget.conversationId] ?? const [];
    if (list.isEmpty) return;
    final before = list.first.id;
    setState(() => _loadingOlder = true);
    try {
      await ref
          .read(chatsControllerProvider.notifier)
          .loadMessages(widget.conversationId, before: before);
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  Future<void> _send() async {
    final text = _composer.text;
    final fileIds = _uploads.drainReady();
    if (text.trim().isEmpty && fileIds.isEmpty) return;
    _composer.clear();
    _composerFocus.requestFocus();
    final replyTo = ref
        .read(chatsControllerProvider)
        .replyTargets[widget.conversationId];
    final ctrl = ref.read(chatsControllerProvider.notifier);
    if (fileIds.isNotEmpty || (replyTo != null && replyTo.isNotEmpty)) {
      await ctrl.sendRich(
        convId: widget.conversationId,
        body: text,
        replyToMessageId: replyTo,
        attachmentFileIds: fileIds,
      );
    } else {
      await ctrl.send(widget.conversationId, text);
    }
  }

  // Scroll to a message by id and trigger a 1s ember pulse.
  void _scrollToMessage(String messageId) {
    final list =
        ref.read(chatsControllerProvider).messages[widget.conversationId] ??
            const <Message>[];
    if (list.isEmpty || !_scroll.hasClients) {
      ref.read(chatsControllerProvider.notifier).pulseMessage(messageId);
      return;
    }
    // Approximate: items are oldest-first; index from the end maps to the
    // reverse list position. We don't track exact bubble heights, so we
    // anchor on the relative position and let the ListView jump.
    final idx = list.indexWhere((m) => m.id == messageId);
    if (idx < 0) {
      ref.read(chatsControllerProvider.notifier).pulseMessage(messageId);
      return;
    }
    final reversedIdx = list.length - 1 - idx;
    final offset = (reversedIdx * 64.0).clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(
      offset,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
    );
    ref.read(chatsControllerProvider.notifier).pulseMessage(messageId);
  }

  void _showVoiceError(String msg) {
    setState(() => _voiceError = msg);
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (_voiceError == msg) setState(() => _voiceError = null);
    });
  }

  void _openPeerProfile(Conversation conv) {
    final peer = conv.peer;
    if (peer == null) return;
    final usersApi = ref.read(settingsUsersApiProvider);
    final me = ref.read(authControllerProvider).user;
    showProfileModal(
      context,
      peer,
      usersApi: usersApi,
      isSelf: me != null && me.id == peer.id,
      onMessage: (u) async {
        final c = await ref.read(chatsControllerProvider.notifier).openDM(u.id);
        if (!mounted) return;
        Navigator.of(context).maybePop();
        if (c.id.isNotEmpty && mounted) {
          GoRouter.of(context).go('/chats/${c.id}');
        }
      },
      onCall: (u) async {
        final notifier = ref.read(callNotifierProvider);
        await notifier.startCall(
          CallPeer(
            id: u.id,
            displayName: u.displayName,
            handle: u.handle,
            avatarColor: u.avatarColor,
          ),
        );
      },
    );
  }

  // Group / channel header: tap opens the GroupInfoModal (members, add,
  // leave). The DM equivalent is the peer ProfileModal above.
  void _openGroupInfo(Conversation conv) {
    final groupsApi = ref.read(groupsApiProvider);
    final usersApi = ref.read(settingsUsersApiProvider);
    showGroupInfoModal(
      context,
      conversation: conv,
      groupsApi: groupsApi,
      usersApi: usersApi,
      onLeft: () {
        // After leaving, refresh the conversations list so the sidebar drops
        // this chat, and route back to the empty pane.
        // ignore: discarded_futures
        ref.read(chatsControllerProvider.notifier).loadConversations();
        if (mounted) GoRouter.of(context).go('/');
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatsControllerProvider);
    final conv = state.byId[widget.conversationId];
    final messages = state.messages[widget.conversationId] ?? const <Message>[];
    final me = ref.watch(authControllerProvider).user;
    if (conv == null) {
      return Container(
        color: AppColors.bg,
        alignment: Alignment.center,
        child: const Text(
          'Conversation not found',
          style: TextStyle(color: AppColors.ink3),
        ),
      );
    }

    // Build a flat item list with day separators interleaved. We render the
    // ListView reversed so the newest messages stay anchored to the bottom.
    final items = _withDaySeparators(messages);
    final isGroup = conv.type == 'group' || conv.type == 'channel';
    final groupNotifier = ref.watch(groupCallNotifierProvider);
    final voiceApi = ref.read(voiceApiProvider);
    final voicePlayer = ref.watch(voicePlayerProvider);
    final connect = ref.read(connectClientProvider);
    final replyTargetId = state.replyTargets[widget.conversationId];
    final Message? replyTargetMsg = replyTargetId == null
        ? null
        : messages.cast<Message?>().firstWhere(
              (m) => m?.id == replyTargetId,
              orElse: () => null,
            );
    final pulseId = state.pulseMessageId;
    final pulseTick = state.pulseTick;
    // Build a quick lookup: messageId -> Message for reply-quote resolution.
    final byMsgId = <String, Message>{for (final m in messages) m.id: m};

    return Column(
      children: [
        _TopBar(
          conv: conv,
          onPeerTap: () => _openPeerProfile(conv),
          onGroupTap: () => _openGroupInfo(conv),
          onToggleSearch: () => setState(() {
            _searchOpen = !_searchOpen;
            if (!_searchOpen) {
              _searchQuery = '';
              _searchResults = const [];
            }
          }),
          searchOpen: _searchOpen,
        ),
        if (_searchOpen)
          Container(
            color: AppColors.panel,
            child: Column(
              children: [
                MessageSearchBar(
                  hint: 'Search in this chat',
                  autofocus: true,
                  onQuery: _runInPaneSearch,
                ),
                if (_searchQuery.isNotEmpty)
                  SizedBox(
                    height: 280,
                    child: MessageSearchResults(
                      query: _searchQuery,
                      results: _searchResults,
                      conversations: state.byId,
                      busy: _searchBusy,
                      onOpen: (m) {
                        setState(() {
                          _searchOpen = false;
                          _searchQuery = '';
                          _searchResults = const [];
                        });
                        _scrollToMessage(m.id);
                      },
                    ),
                  ),
                const Divider(height: 1),
              ],
            ),
          ),
        if (isGroup)
          GroupCallBanner(
            conversationId: widget.conversationId,
            group: groupNotifier,
          ),
        Expanded(
          child: messages.isEmpty
              ? const Center(
                  child: Text('No messages yet — say hi.',
                      style: TextStyle(color: AppColors.ink3, fontSize: 13)),
                )
              : ListView.builder(
                  controller: _scroll,
                  reverse: true,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  itemCount: items.length + (_loadingOlder ? 1 : 0),
                  itemBuilder: (_, i) {
                    if (_loadingOlder && i == items.length) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Center(
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      );
                    }
                    // items is oldest-first; with reverse:true we want index 0
                    // at the bottom (newest). So map i -> last - i.
                    final item = items[items.length - 1 - i];
                    if (item is _DaySep) return _DaySeparator(day: item.day);
                    final m = item as Message;
                    final isMine = me != null && m.senderId == me.id;
                    // Service messages: the `kind` field is stripped over HTTP
                    // (not in the proto), so we also sniff the body for a
                    // `{type: "..."}` JSON envelope. Either signal routes the
                    // bubble through the centered pill renderer.
                    if (m.kind == 'service' || looksLikeServicePayload(m.body)) {
                      return ServiceMessageBubble(message: m);
                    }
                    if (m.kind == 'voice' && m.voice != null) {
                      return _VoiceBubbleRow(
                        message: m,
                        isMine: isMine,
                        token: connect.token ?? '',
                        playbackUrl: voiceApi.buildPlaybackUrl(
                            m.voice!.fileId, connect.token ?? ''),
                        player: voicePlayer,
                        onFirstPlay: () {
                          if (!_firedPlay.add(m.id)) return;
                          // ignore: discarded_futures
                          voiceApi.markPlayed(m.id);
                        },
                      );
                    }
                    return _Bubble(
                      message: m,
                      isMine: isMine,
                      original: m.replyToMessageId != null
                          ? byMsgId[m.replyToMessageId!]
                          : null,
                      onTapReply: m.replyToMessageId != null
                          ? () => _scrollToMessage(m.replyToMessageId!)
                          : null,
                      onReply: () => ref
                          .read(chatsControllerProvider.notifier)
                          .setReplyTarget(widget.conversationId, m.id),
                      onForward: () => _openForwardModal(m),
                      onReact: (emoji) => _toggleReaction(m, emoji),
                      onOpenPicker: (anchor) =>
                          _openReactionPicker(m, anchor),
                      pulseTick: pulseId == m.id ? pulseTick : 0,
                    );
                  },
                ),
        ),
        UploadProgressStrip(queue: _uploads),
        if (replyTargetMsg != null)
          ReplyComposePill(
            message: replyTargetMsg,
            senderName: _senderNameFor(replyTargetMsg, conv, me),
            onCancel: () => ref
                .read(chatsControllerProvider.notifier)
                .setReplyTarget(widget.conversationId, null),
          ),
        _Composer(
          uploadQueue: _uploads,
          controller: _composer,
          focusNode: _composerFocus,
          onSend: _send,
          showVoice: !_hasText,
          conversationId: widget.conversationId,
          voiceError: _voiceError,
          onLocalVoice: (payload) {
            ref
                .read(chatsControllerProvider.notifier)
                .appendOptimisticVoice(
                  widget.conversationId,
                  payload.fileId,
                  payload.durationMs,
                  payload.peaks,
                );
          },
          onVoiceSent: (result) {
            ref
                .read(chatsControllerProvider.notifier)
                .replaceOptimisticVoice(
                  widget.conversationId,
                  result.payload.fileId,
                  result.serverMessageId,
                  result.serverCreatedAt,
                );
          },
          onVoiceError: _showVoiceError,
        ),
      ],
    );
  }

  String _senderNameFor(Message m, Conversation conv, User? me) {
    if (me != null && m.senderId == me.id) return 'yourself';
    if (conv.peer != null && conv.peer!.id == m.senderId) {
      final p = conv.peer!;
      return p.displayName.isNotEmpty ? p.displayName : '@${p.handle}';
    }
    return 'them';
  }

  void _openForwardModal(Message m) {
    showForwardModal(context, sourceMessage: m, ref: ref);
  }

  Future<void> _toggleReaction(Message m, String emoji) async {
    final me = ref.read(authControllerProvider).user;
    final api = ref.read(messagingApiProvider);
    final mine = me != null &&
        m.reactions.any((r) => r.userId == me.id && r.emoji == emoji);
    try {
      if (mine) {
        await api.removeReaction(m.id, emoji);
      } else {
        await api.addReaction(m.id, emoji);
      }
    } catch (_) {/* WS will reconcile */}
  }

  Future<void> _runInPaneSearch(String q) async {
    setState(() => _searchQuery = q);
    if (q.isEmpty) {
      setState(() {
        _searchResults = const [];
        _searchBusy = false;
      });
      return;
    }
    setState(() => _searchBusy = true);
    try {
      final results = await ref.read(messagingApiProvider).searchMessages(
            query: q,
            conversationId: widget.conversationId,
            limit: 40,
          );
      if (!mounted) return;
      setState(() => _searchResults = results);
    } catch (_) {
      if (mounted) setState(() => _searchResults = const []);
    } finally {
      if (mounted) setState(() => _searchBusy = false);
    }
  }

  void _openReactionPicker(Message m, Offset anchor) {
    showReactionPickerOverlay(
      context: context,
      anchor: anchor,
      message: m,
      onPick: (emoji) => _toggleReaction(m, emoji),
    );
  }

  List<Object> _withDaySeparators(List<Message> msgs) {
    if (msgs.isEmpty) return const [];
    final out = <Object>[];
    DateTime? prevDay;
    for (final m in msgs) {
      final d = DateTime(m.createdAt.year, m.createdAt.month, m.createdAt.day);
      if (prevDay == null || d != prevDay) {
        out.add(_DaySep(d));
        prevDay = d;
      }
      out.add(m);
    }
    return out;
  }
}

class _DaySep {
  _DaySep(this.day);
  final DateTime day;
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.day});
  final DateTime day;

  String _label() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    if (day == today) return 'Today';
    if (day == yesterday) return 'Yesterday';
    if (now.year == day.year) return DateFormat('MMMM d').format(day);
    return DateFormat.yMMMMd().format(day);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.raised.withAlpha(150),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            _label(),
            style: const TextStyle(
                color: AppColors.ink2, fontSize: 11, fontWeight: FontWeight.w500),
          ),
        ),
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar({
    required this.conv,
    required this.onPeerTap,
    required this.onGroupTap,
    required this.onToggleSearch,
    required this.searchOpen,
  });
  final Conversation conv;
  final VoidCallback onPeerTap;
  final VoidCallback onGroupTap;
  final VoidCallback onToggleSearch;
  final bool searchOpen;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDm = conv.peer != null;
    final isGroup = conv.type == 'group' || conv.type == 'channel';
    final VoidCallback? headerTap = isDm
        ? onPeerTap
        : (isGroup ? onGroupTap : null);
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: AppColors.panel,
        border: Border(bottom: BorderSide(color: AppColors.line)),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: headerTap,
            child: Avatar(
                name: conv.avatarSeed(),
                colorHex: conv.avatarColorHex(),
                size: 34),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: GestureDetector(
              onTap: headerTap,
              behavior: HitTestBehavior.opaque,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    conv.displayTitle(),
                    style: const TextStyle(
                      color: AppColors.ink1,
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                  Text(
                    conv.peer != null ? '@${conv.peer!.handle}' : conv.type,
                    style: const TextStyle(color: AppColors.ink3, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: searchOpen ? 'Close search' : 'Search in chat',
            icon: Icon(searchOpen ? Icons.close : Icons.search,
                size: 18, color: AppColors.ink2),
            onPressed: onToggleSearch,
          ),
          if (isDm)
            IconButton(
              tooltip: 'Call',
              icon: const Icon(Icons.call, size: 18, color: AppColors.ink2),
              onPressed: () {
                final peer = conv.peer!;
                final notifier = ref.read(callNotifierProvider);
                // ignore: discarded_futures
                notifier.startCall(CallPeer(
                  id: peer.id,
                  displayName: peer.displayName,
                  handle: peer.handle,
                  avatarColor: peer.avatarColor,
                ));
              },
            ),
          if (conv.type == 'group' || conv.type == 'channel')
            IconButton(
              tooltip: 'Voice chat',
              icon:
                  const Icon(Icons.graphic_eq, size: 18, color: AppColors.ink2),
              onPressed: () {
                final n = ref.read(groupCallNotifierProvider);
                // ignore: discarded_futures
                n.startGroupCall(conv.id);
              },
            ),
        ],
      ),
    );
  }
}

class _Bubble extends ConsumerStatefulWidget {
  const _Bubble({
    required this.message,
    required this.isMine,
    this.original,
    this.onTapReply,
    this.onReply,
    this.onForward,
    this.onReact,
    this.onOpenPicker,
    this.pulseTick = 0,
  });
  final Message message;
  final bool isMine;
  final Message? original;
  final VoidCallback? onTapReply;
  final VoidCallback? onReply;
  final VoidCallback? onForward;
  final void Function(String emoji)? onReact;
  final void Function(Offset anchor)? onOpenPicker;
  // Increments when this bubble should run a 1s ember pulse.
  final int pulseTick;

  @override
  ConsumerState<_Bubble> createState() => _BubbleState();
}

class _BubbleState extends ConsumerState<_Bubble>
    with SingleTickerProviderStateMixin {
  bool _hover = false;
  late AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    if (widget.pulseTick > 0) _pulse.forward(from: 0);
  }

  @override
  void didUpdateWidget(covariant _Bubble old) {
    super.didUpdateWidget(old);
    if (widget.pulseTick != old.pulseTick && widget.pulseTick > 0) {
      _pulse.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _openMenu(Offset global) {
    final me = ref.read(authControllerProvider).user;
    final hasMine = me != null &&
        widget.message.reactions
            .any((r) => r.userId == me.id);
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(global.dx, global.dy, global.dx, global.dy),
      color: AppColors.panel,
      items: [
        const PopupMenuItem(
          value: 'reply',
          child: Row(children: [
            Icon(Icons.reply, size: 16, color: AppColors.ink2),
            SizedBox(width: 8),
            Text('Reply'),
          ]),
        ),
        const PopupMenuItem(
          value: 'forward',
          child: Row(children: [
            Icon(Icons.forward, size: 16, color: AppColors.ink2),
            SizedBox(width: 8),
            Text('Forward'),
          ]),
        ),
        PopupMenuItem(
          value: 'react',
          child: Row(children: [
            const Icon(Icons.add_reaction_outlined,
                size: 16, color: AppColors.ink2),
            const SizedBox(width: 8),
            Text(hasMine ? 'Change reaction' : 'React'),
          ]),
        ),
      ],
    ).then((v) {
      if (!mounted || v == null) return;
      switch (v) {
        case 'reply':
          widget.onReply?.call();
          break;
        case 'forward':
          widget.onForward?.call();
          break;
        case 'react':
          widget.onOpenPicker?.call(global);
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isMine = widget.isMine;
    final message = widget.message;
    final align = isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bubbleColor =
        isMine ? AppColors.ember.withAlpha(40) : AppColors.raised;
    final borderColor =
        isMine ? AppColors.ember.withAlpha(70) : AppColors.line;
    final me = ref.watch(authControllerProvider).user;

    final hasForward = message.forwardOriginText.isNotEmpty ||
        (message.forwardFromUserId != null &&
            message.forwardFromUserId!.isNotEmpty);

    final bubble = Container(
      constraints: const BoxConstraints(maxWidth: 520),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      decoration: BoxDecoration(
        color: bubbleColor,
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(AppRadii.rLg),
          topRight: const Radius.circular(AppRadii.rLg),
          bottomLeft:
              Radius.circular(isMine ? AppRadii.rLg : AppRadii.rSm),
          bottomRight:
              Radius.circular(isMine ? AppRadii.rSm : AppRadii.rLg),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasForward)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                message.forwardOriginText.isNotEmpty
                    ? 'Forwarded from ${message.forwardOriginText}'
                    : 'Forwarded',
                style: const TextStyle(
                  color: AppColors.emberSoft,
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          if (message.replyToMessageId != null)
            ReplyQuoteBlock(
              original: widget.original,
              senderName: widget.original == null
                  ? '…'
                  : (me != null && widget.original!.senderId == me.id
                      ? 'You'
                      : 'Reply'),
              onTap: widget.onTapReply ?? () {},
            ),
          for (final a in message.attachments)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: a.kind == 'image'
                  ? ImageBubble(
                      attachment: a,
                      url: buildMediaUrl(
                          apiBaseUrl,
                          a.fileId,
                          ref.read(connectClientProvider).token ?? ''),
                    )
                  : FileBubble(
                      attachment: a,
                      url: buildMediaUrl(
                          apiBaseUrl,
                          a.fileId,
                          ref.read(connectClientProvider).token ?? ''),
                    ),
            ),
          if (message.renderedBody.isNotEmpty)
            Text(
              message.renderedBody,
              style: const TextStyle(
                color: AppColors.ink1,
                fontSize: 14,
                height: 1.35,
              ),
            ),
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                DateFormat.Hm().format(message.createdAt),
                style:
                    const TextStyle(color: AppColors.ink3, fontSize: 10.5),
              ),
              if (isMine) ...[
                const SizedBox(width: 4),
                _StatusIcon(status: message.status),
              ],
            ],
          ),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.deferToChild,
          onSecondaryTapDown: (d) => _openMenu(d.globalPosition),
          onLongPressStart: (d) => _openMenu(d.globalPosition),
          child: Column(
            crossAxisAlignment: align,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  AnimatedBuilder(
                    animation: _pulse,
                    builder: (_, child) {
                      final v = (1 - _pulse.value).clamp(0.0, 1.0);
                      return Container(
                        decoration: BoxDecoration(
                          borderRadius:
                              BorderRadius.circular(AppRadii.rLg),
                          boxShadow: v > 0
                              ? [
                                  BoxShadow(
                                    color: AppColors.ember
                                        .withAlpha((180 * v).toInt()),
                                    blurRadius: 12,
                                    spreadRadius: 1,
                                  )
                                ]
                              : const [],
                        ),
                        child: child,
                      );
                    },
                    child: bubble,
                  ),
                  if (_hover && widget.onOpenPicker != null)
                    Positioned(
                      top: -8,
                      right: isMine ? null : -8,
                      left: isMine ? -8 : null,
                      child: _ReactQuickButton(
                        onTap: (anchor) =>
                            widget.onOpenPicker!.call(anchor),
                      ),
                    ),
                ],
              ),
              if (message.reactions.isNotEmpty)
                ReactionStrip(
                  reactions: message.reactions,
                  currentUserId: me?.id,
                  onToggle: (e) => widget.onReact?.call(e),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReactQuickButton extends StatelessWidget {
  const _ReactQuickButton({required this.onTap});
  final void Function(Offset anchor) onTap;
  @override
  Widget build(BuildContext context) {
    return Builder(builder: (ctx) {
      return Material(
        color: AppColors.panel,
        shape: const CircleBorder(side: BorderSide(color: AppColors.line)),
        elevation: 2,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () {
            final box = ctx.findRenderObject() as RenderBox?;
            final anchor = box?.localToGlobal(Offset.zero) ?? Offset.zero;
            onTap(anchor);
          },
          child: const Padding(
            padding: EdgeInsets.all(4),
            child: Icon(Icons.add_reaction_outlined,
                size: 14, color: AppColors.ink2),
          ),
        ),
      );
    });
  }
}

class _VoiceBubbleRow extends StatelessWidget {
  const _VoiceBubbleRow({
    required this.message,
    required this.isMine,
    required this.token,
    required this.playbackUrl,
    required this.player,
    required this.onFirstPlay,
  });
  final Message message;
  final bool isMine;
  final String token;
  final String playbackUrl;
  final dynamic player;
  final VoidCallback onFirstPlay;

  @override
  Widget build(BuildContext context) {
    final align = isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bg = isMine ? AppColors.ember.withAlpha(40) : AppColors.raised;
    final border = isMine ? AppColors.ember.withAlpha(70) : AppColors.line;
    final v = message.voice!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: align,
        children: [
          Container(
            constraints: const BoxConstraints(maxWidth: 520),
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            decoration: BoxDecoration(
              color: bg,
              border: Border.all(color: border),
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(AppRadii.rLg),
                topRight: const Radius.circular(AppRadii.rLg),
                bottomLeft: Radius.circular(
                    isMine ? AppRadii.rLg : AppRadii.rSm),
                bottomRight: Radius.circular(
                    isMine ? AppRadii.rSm : AppRadii.rLg),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                vw.VoiceBubble(
                  voice: vw.VoicePayload(
                    fileId: v.fileId,
                    url: playbackUrl,
                    durationMs: v.durationMs,
                    peaks: v.peaks,
                    played: v.played,
                    messageId:
                        message.id.isNotEmpty ? message.id : (message.tempId ?? v.fileId),
                  ),
                  isOwn: isMine,
                  player: player,
                  onFirstPlay: onFirstPlay,
                ),
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      DateFormat.Hm().format(message.createdAt),
                      style: const TextStyle(
                          color: AppColors.ink3, fontSize: 10.5),
                    ),
                    if (isMine) ...[
                      const SizedBox(width: 4),
                      _StatusIcon(status: message.status),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status});
  final MessageStatus status;
  @override
  Widget build(BuildContext context) {
    switch (status) {
      case MessageStatus.pending:
        return const Icon(Icons.schedule, size: 12, color: AppColors.ink3);
      case MessageStatus.failed:
        return const Icon(Icons.error_outline, size: 12, color: AppColors.err);
      case MessageStatus.read:
        return const Icon(Icons.done_all, size: 12, color: AppColors.emberSoft);
      case MessageStatus.sent:
        return const Icon(Icons.check, size: 12, color: AppColors.ink2);
    }
  }
}

class _Composer extends ConsumerWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.showVoice,
    required this.conversationId,
    required this.voiceError,
    required this.onLocalVoice,
    required this.onVoiceSent,
    required this.onVoiceError,
    required this.uploadQueue,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;
  final bool showVoice;
  final String conversationId;
  final String? voiceError;
  final void Function(vw.VoicePayload payload) onLocalVoice;
  final void Function(VoiceSendResult result) onVoiceSent;
  final void Function(String msg) onVoiceError;
  final UploadQueue uploadQueue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final voiceApi = ref.read(voiceApiProvider);
    final token = ref.read(connectClientProvider).token ?? '';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: const BoxDecoration(
        color: AppColors.panel,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (voiceError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.err.withAlpha(40),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppColors.err.withAlpha(120)),
                ),
                child: Text(
                  voiceError!,
                  style: const TextStyle(color: AppColors.ink1, fontSize: 12),
                ),
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              AttachButton(queue: uploadQueue),
              const SizedBox(width: 4),
              Expanded(
                child: Shortcuts(
                  shortcuts: const {
                    SingleActivator(LogicalKeyboardKey.enter): _SendIntent(),
                  },
                  child: Actions(
                    actions: {
                      _SendIntent: CallbackAction<_SendIntent>(
                        onInvoke: (_) {
                          onSend();
                          return null;
                        },
                      ),
                    },
                    child: TextField(
                      controller: controller,
                      focusNode: focusNode,
                      minLines: 1,
                      maxLines: 6,
                      textInputAction: TextInputAction.newline,
                      decoration: const InputDecoration(
                        hintText: 'Message',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              if (showVoice)
                VoiceRecorderButton(
                  api: voiceApi,
                  conversationId: conversationId,
                  token: token,
                  onLocalVoiceMessage: onLocalVoice,
                  onSent: onVoiceSent,
                  onError: onVoiceError,
                )
              else
                ElevatedButton(
                  onPressed: onSend,
                  style: ElevatedButton.styleFrom(
                    shape: const CircleBorder(),
                    padding: const EdgeInsets.all(14),
                  ),
                  child:
                      const Icon(Icons.send, color: Colors.white, size: 18),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SendIntent extends Intent {
  const _SendIntent();
}
