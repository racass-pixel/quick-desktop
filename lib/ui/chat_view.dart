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
import '../features/voice/widgets/voice_bubble.dart' as vw;
import '../features/voice/widgets/voice_recorder_button.dart';
import '../features/settings/widgets/profile_modal.dart';
import '../state/chats_controller.dart';
import '../state/providers.dart';
import '../theme/theme.dart';
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
    if (text.trim().isEmpty) return;
    _composer.clear();
    _composerFocus.requestFocus();
    await ref
        .read(chatsControllerProvider.notifier)
        .send(widget.conversationId, text);
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

    return Column(
      children: [
        _TopBar(conv: conv, onPeerTap: () => _openPeerProfile(conv)),
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
                    return _Bubble(message: m, isMine: isMine);
                  },
                ),
        ),
        _Composer(
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
  const _TopBar({required this.conv, required this.onPeerTap});
  final Conversation conv;
  final VoidCallback onPeerTap;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDm = conv.peer != null;
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
            onTap: isDm ? onPeerTap : null,
            child: Avatar(
                name: conv.avatarSeed(),
                colorHex: conv.avatarColorHex(),
                size: 34),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: GestureDetector(
              onTap: isDm ? onPeerTap : null,
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

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.isMine});
  final Message message;
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    final align = isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bubbleColor = isMine ? AppColors.ember.withAlpha(40) : AppColors.raised;
    final borderColor = isMine ? AppColors.ember.withAlpha(70) : AppColors.line;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: align,
        children: [
          Container(
            constraints: const BoxConstraints(maxWidth: 520),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            decoration: BoxDecoration(
              color: bubbleColor,
              border: Border.all(color: borderColor),
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
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  message.body,
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
