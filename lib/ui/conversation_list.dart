import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../api/dto.dart';
import '../features/calls/state/call_state.dart';
import '../features/messaging/search/search_results.dart';
import '../features/settings/widgets/profile_modal.dart';
import '../state/chats_controller.dart';
import '../state/providers.dart';
import '../theme/theme.dart';
import 'widgets/avatar.dart';

class ConversationListPane extends ConsumerStatefulWidget {
  const ConversationListPane({super.key});
  @override
  ConsumerState<ConversationListPane> createState() =>
      _ConversationListPaneState();
}

class _ConversationListPaneState extends ConsumerState<ConversationListPane> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  List<User> _searchResults = const [];
  List<Message> _msgResults = const [];
  bool _searching = false;
  String _q = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String v) {
    _debounce?.cancel();
    final q = v.trim();
    setState(() => _q = q);
    if (q.isEmpty) {
      setState(() {
        _searchResults = const [];
        _msgResults = const [];
        _searching = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      setState(() => _searching = true);
      try {
        // Fire both queries in parallel; user search is a prefix lookup
        // while message search is full-text.
        final usersFut = ref.read(usersApiProvider).search(q);
        final msgsFut = q.length >= 2
            ? ref.read(messagingApiProvider).searchMessages(query: q, limit: 20)
            : Future<List<Message>>.value(const <Message>[]);
        final results = await Future.wait([usersFut, msgsFut]);
        if (!mounted) return;
        setState(() {
          _searchResults = results[0] as List<User>;
          _msgResults = results[1] as List<Message>;
        });
      } catch (_) {
        if (mounted) {
          setState(() {
            _searchResults = const [];
            _msgResults = const [];
          });
        }
      } finally {
        if (mounted) setState(() => _searching = false);
      }
    });
  }

  Future<void> _openMessageResult(Message m) async {
    final ctrl = ref.read(chatsControllerProvider.notifier);
    // Make sure the chat is hydrated, then route and pulse.
    await ctrl.loadMessages(m.conversationId);
    ctrl.pulseMessage(m.id);
    if (mounted) context.go('/chats/${m.conversationId}');
  }

  Future<void> _startDmWith(User peer) async {
    try {
      final conv = await ref
          .read(chatsControllerProvider.notifier)
          .openDM(peer.id);
      _searchCtrl.clear();
      setState(() => _searchResults = const []);
      if (mounted) context.go('/chats/${conv.id}');
    } catch (_) {/* surface later */}
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatsControllerProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: TextField(
            controller: _searchCtrl,
            onChanged: _onSearchChanged,
            decoration: const InputDecoration(
              hintText: 'Search @handle',
              prefixIcon: Icon(Icons.search, color: AppColors.ink3, size: 18),
              isDense: true,
            ),
          ),
        ),
        if (_searchCtrl.text.trim().isNotEmpty)
          Expanded(
              child: _GlobalSearchPane(
            users: _searchResults,
            messages: _msgResults,
            byConv: state.byId,
            busy: _searching,
            query: _q,
            onTapUser: _startDmWith,
            onTapMessage: _openMessageResult,
          ))
        else
          Expanded(
            child: state.loadingConvs && state.order.isEmpty
                ? const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : state.order.isEmpty
                    ? const _EmptyState()
                    : ListView.builder(
                        itemCount: state.order.length,
                        itemBuilder: (_, i) {
                          final id = state.order[i];
                          final conv = state.byId[id]!;
                          final active = state.activeConvId == id;
                          return _ConversationTile(
                            conv: conv,
                            active: active,
                            onTap: () => context.go('/chats/$id'),
                            onAvatarTap: () {
                              final peer = conv.peer;
                              if (peer == null) return;
                              final me =
                                  ref.read(authControllerProvider).user;
                              showProfileModal(
                                context,
                                peer,
                                usersApi:
                                    ref.read(settingsUsersApiProvider),
                                isSelf: me != null && me.id == peer.id,
                                onMessage: (u) async {
                                  final c = await ref
                                      .read(chatsControllerProvider.notifier)
                                      .openDM(u.id);
                                  if (!context.mounted) return;
                                  Navigator.of(context).maybePop();
                                  if (c.id.isNotEmpty &&
                                      context.mounted) {
                                    context.go('/chats/${c.id}');
                                  }
                                },
                                onCall: (u) async {
                                  await ref
                                      .read(callNotifierProvider)
                                      .startCall(CallPeer(
                                        id: u.id,
                                        displayName: u.displayName,
                                        handle: u.handle,
                                        avatarColor: u.avatarColor,
                                      ));
                                },
                              );
                            },
                          );
                        },
                      ),
          ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(24),
      child: Center(
        child: Text(
          'No chats yet. Search a @handle to start one.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.ink3, fontSize: 13),
        ),
      ),
    );
  }
}

class _GlobalSearchPane extends StatelessWidget {
  const _GlobalSearchPane({
    required this.users,
    required this.messages,
    required this.byConv,
    required this.busy,
    required this.query,
    required this.onTapUser,
    required this.onTapMessage,
  });
  final List<User> users;
  final List<Message> messages;
  final Map<String, Conversation> byConv;
  final bool busy;
  final String query;
  final void Function(User) onTapUser;
  final void Function(Message) onTapMessage;

  @override
  Widget build(BuildContext context) {
    if (busy && users.isEmpty && messages.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final empty = users.isEmpty && messages.isEmpty;
    if (empty) {
      return const Center(
        child: Text('No matches',
            style: TextStyle(color: AppColors.ink3, fontSize: 13)),
      );
    }
    return ListView(
      children: [
        if (users.isNotEmpty) ...[
          const _SectionHeader('Chats'),
          for (final u in users) _UserRow(user: u, onTap: () => onTapUser(u)),
        ],
        if (messages.isNotEmpty) ...[
          const _SectionHeader('Messages'),
          SizedBox(
            height: (messages.length * 64.0).clamp(64, 480),
            child: MessageSearchResults(
              query: query,
              results: messages,
              conversations: byConv,
              onOpen: onTapMessage,
            ),
          ),
        ],
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);
  final String label;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          color: AppColors.ink3,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _UserRow extends StatelessWidget {
  const _UserRow({required this.user, required this.onTap});
  final User user;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Avatar(
                name: user.displayName.isNotEmpty
                    ? user.displayName
                    : user.handle,
                colorHex: user.avatarColor,
                size: 36,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.displayName.isNotEmpty
                          ? user.displayName
                          : user.handle,
                      style: const TextStyle(
                        color: AppColors.ink1,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    Text('@${user.handle}',
                        style: const TextStyle(
                            color: AppColors.ink3, fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchResults extends StatelessWidget {
  const _SearchResults({
    required this.results,
    required this.busy,
    required this.onTap,
  });
  final List<User> results;
  final bool busy;
  final void Function(User) onTap;

  @override
  Widget build(BuildContext context) {
    if (busy && results.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (results.isEmpty) {
      return const Center(
        child: Text('No matches',
            style: TextStyle(color: AppColors.ink3, fontSize: 13)),
      );
    }
    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (_, i) {
        final u = results[i];
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => onTap(u),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Avatar(
                    name: u.displayName.isNotEmpty ? u.displayName : u.handle,
                    colorHex: u.avatarColor,
                    size: 36,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          u.displayName.isNotEmpty ? u.displayName : u.handle,
                          style: const TextStyle(
                            color: AppColors.ink1,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        Text('@${u.handle}',
                            style: const TextStyle(
                                color: AppColors.ink3, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.conv,
    required this.active,
    required this.onTap,
    required this.onAvatarTap,
  });
  final Conversation conv;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onAvatarTap;

  String _relative(DateTime? t) {
    if (t == null) return '';
    final now = DateTime.now();
    final d = now.difference(t);
    if (d.inMinutes < 1) return 'now';
    if (d.inHours < 1) return '${d.inMinutes}m';
    if (now.year == t.year && now.month == t.month && now.day == t.day) {
      return DateFormat.Hm().format(t);
    }
    if (d.inDays < 7) return DateFormat.E().format(t);
    return DateFormat.yMd().format(t);
  }

  @override
  Widget build(BuildContext context) {
    final preview = conv.preview?.body ?? '';
    final time = _relative(conv.lastMessageAt);
    final title = conv.displayTitle();
    return Material(
      color: active ? AppColors.raised : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 68,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              GestureDetector(
                onTap: onAvatarTap,
                child: Avatar(
                    name: conv.avatarSeed(),
                    colorHex: conv.avatarColorHex(),
                    size: 44),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              color: AppColors.ink1,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (time.isNotEmpty)
                          Text(time,
                              style: const TextStyle(
                                  color: AppColors.ink3, fontSize: 11)),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: conv.unreadCount > 0
                                  ? AppColors.ink1
                                  : AppColors.ink3,
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                        if (conv.unreadCount > 0)
                          Container(
                            constraints: const BoxConstraints(minWidth: 20),
                            height: 18,
                            padding:
                                const EdgeInsets.symmetric(horizontal: 6),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: AppColors.ember,
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: Text(
                              conv.unreadCount > 99
                                  ? '99+'
                                  : conv.unreadCount.toString(),
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
