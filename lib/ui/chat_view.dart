// Chat view: top bar with peer name, scrollable message list with day
// separators, ticks for own messages, bottom text composer. Loads the page on
// mount; older pages are fetched as the user scrolls to the top.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../api/dto.dart';
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
    _scroll.addListener(_onScroll);
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
    _scroll.dispose();
    _composer.dispose();
    _composerFocus.dispose();
    super.dispose();
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

    return Column(
      children: [
        _TopBar(conv: conv),
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
                    return _Bubble(message: m, isMine: isMine);
                  },
                ),
        ),
        _Composer(
          controller: _composer,
          focusNode: _composerFocus,
          onSend: _send,
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

class _TopBar extends StatelessWidget {
  const _TopBar({required this.conv});
  final Conversation conv;
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: AppColors.panel,
        border: Border(bottom: BorderSide(color: AppColors.line)),
      ),
      child: Row(
        children: [
          Avatar(name: conv.avatarSeed(), colorHex: conv.avatarColorHex(), size: 34),
          const SizedBox(width: 12),
          Expanded(
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

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.onSend,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: const BoxDecoration(
        color: AppColors.panel,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: Row(
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
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          ElevatedButton(
            onPressed: onSend,
            style: ElevatedButton.styleFrom(
              shape: const CircleBorder(),
              padding: const EdgeInsets.all(14),
            ),
            child: const Icon(Icons.send, color: Colors.white, size: 18),
          ),
        ],
      ),
    );
  }
}

class _SendIntent extends Intent {
  const _SendIntent();
}
