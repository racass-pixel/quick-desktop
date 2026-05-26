// "Group info" modal. Opens when the user taps the conversation title or
// avatar in a group/channel header. Layout follows Telegram's group-profile
// card and mirrors quick-web's MembersModal:
//
//   - 96 px avatar centred above the conversation title
//   - Member count subtitle
//   - Members section with a sticky header and a "+" Add Members button
//     (owners/admins only)
//   - Member rows: avatar + name + role badge (Owner / Admin)
//     Clicking an avatar opens that user's ProfileModal.
//   - Leave Group button at the bottom (red, requires inline confirmation)
//
// Renaming the group is intentionally surfaced as a read-only note —
// the backend doesn't expose UpdateProfile for conversations yet.

import 'package:flutter/material.dart';

import '../../../api/connect.dart';
import '../../../api/dto.dart';
import '../../../theme/theme.dart';
import '../../settings/api/users_api.dart';
import '../../settings/widgets/profile_modal.dart';
import '../api/groups_api.dart';
import 'user_multi_picker.dart';

Future<void> showGroupInfoModal(
  BuildContext context, {
  required Conversation conversation,
  required GroupsApi groupsApi,
  required SettingsUsersApi usersApi,
  VoidCallback? onLeft,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (ctx) => GroupInfoModal(
      conversation: conversation,
      groupsApi: groupsApi,
      usersApi: usersApi,
      onLeft: onLeft,
    ),
  );
}

class GroupInfoModal extends StatefulWidget {
  const GroupInfoModal({
    super.key,
    required this.conversation,
    required this.groupsApi,
    required this.usersApi,
    this.onLeft,
  });

  final Conversation conversation;
  final GroupsApi groupsApi;
  final SettingsUsersApi usersApi;
  final VoidCallback? onLeft;

  @override
  State<GroupInfoModal> createState() => _GroupInfoModalState();
}

class _GroupInfoModalState extends State<GroupInfoModal> {
  List<Member>? _members;
  String? _error;
  bool _showAdd = false;
  List<User> _picked = const [];
  bool _adding = false;
  String? _addError;
  bool _confirmLeave = false;
  bool _leaving = false;
  String? _leaveError;

  @override
  void initState() {
    super.initState();
    // ignore: discarded_futures
    _load();
  }

  Future<void> _load() async {
    try {
      final members =
          await widget.groupsApi.listMembers(widget.conversation.id);
      if (!mounted) return;
      setState(() {
        _members = members;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _members = const [];
        _error = _msg(e, 'Could not load members.');
      });
    }
  }

  bool get _canAdd {
    final r = widget.conversation.myRole;
    return r == 'owner' || r == 'admin';
  }

  String get _convLabel =>
      widget.conversation.type == 'channel' ? 'channel' : 'group';

  String get _headerTitle {
    final t = widget.conversation.title;
    if (t.isNotEmpty) return t;
    return widget.conversation.type == 'channel' ? 'Channel' : 'Group';
  }

  Future<void> _submitAdd() async {
    if (_adding) return;
    final memberIds =
        (_members ?? const <Member>[]).map((m) => m.user?.id).whereType<String>().toSet();
    final newOnes = _picked.where((u) => !memberIds.contains(u.id)).toList();
    if (newOnes.isEmpty) return;
    setState(() {
      _adding = true;
      _addError = null;
    });
    try {
      await widget.groupsApi.addMembers(
        widget.conversation.id,
        newOnes.map((u) => u.id).toList(),
      );
      // Re-pull — the server may reject some entries (private accounts,
      // blocks, etc.) so the round trip is the source of truth.
      await _load();
      if (!mounted) return;
      setState(() {
        _picked = const [];
        _showAdd = false;
        _adding = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _adding = false;
        _addError = _msg(e, 'Could not add members.');
      });
    }
  }

  Future<void> _submitLeave() async {
    if (_leaving) return;
    setState(() {
      _leaving = true;
      _leaveError = null;
    });
    try {
      await widget.groupsApi.leaveConversation(widget.conversation.id);
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onLeft?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _leaving = false;
        _leaveError = _msg(e, 'Could not leave.');
      });
    }
  }

  void _openMemberProfile(User u) {
    showProfileModal(
      context,
      u,
      usersApi: widget.usersApi,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 720),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.panel,
            borderRadius: BorderRadius.circular(AppRadii.rXl),
            border: Border.all(color: AppColors.line),
            boxShadow: const [
              BoxShadow(
                color: Colors.black54,
                blurRadius: 32,
                offset: Offset(0, 12),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.rXl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(),
                _identity(),
                Flexible(child: _membersSection()),
                if (widget.conversation.myRole.isNotEmpty) _footer(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 8, 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$_convLabel info',
              style: const TextStyle(
                fontSize: 11,
                letterSpacing: 1.2,
                fontFamily: 'Consolas',
                color: AppColors.ink3,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            color: AppColors.ink3,
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _identity() {
    final count = _members?.length ?? widget.conversation.memberCount;
    final color = widget.conversation.avatarColorHex();
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 18),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.line)),
      ),
      child: Column(
        children: [
          Container(
            width: 96,
            height: 96,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: avatarColor(color, _headerTitle),
              shape: BoxShape.circle,
            ),
            child: Text(
              avatarInitials(_headerTitle),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 36,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            _headerTitle,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: AppColors.ink1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '$count ${count == 1 ? 'member' : 'members'}',
            style: const TextStyle(
              fontSize: 12,
              fontFamily: 'Consolas',
              color: AppColors.ink3,
            ),
          ),
          if (_canAdd) ...[
            const SizedBox(height: 10),
            const Text(
              "Renaming the group isn't available yet",
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'Consolas',
                color: AppColors.ink3,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _membersSection() {
    final members = _members;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.line)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'MEMBERS${members != null ? ' · ${members.length}' : ''}',
                  style: const TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.2,
                    fontFamily: 'Consolas',
                    color: AppColors.ink3,
                  ),
                ),
              ),
              if (_canAdd && !_showAdd)
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: () => setState(() => _showAdd = true),
                    child: Container(
                      width: 28,
                      height: 28,
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.add,
                        size: 16,
                        color: AppColors.ember,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (_showAdd) _addForm(),
        Flexible(child: _memberList()),
      ],
    );
  }

  Widget _addForm() {
    final memberIds = (_members ?? const <Member>[])
        .map((m) => m.user?.id)
        .whereType<String>()
        .toSet();
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      decoration: BoxDecoration(
        color: AppColors.raised.withValues(alpha: 0.4),
        border: const Border(
          bottom: BorderSide(color: AppColors.line),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UserMultiPicker(
            usersApi: widget.usersApi,
            selected: _picked,
            onChanged: (list) => setState(() => _picked = list),
            placeholder: 'Find by handle…',
            excludeIds: memberIds,
          ),
          if (_addError != null) ...[
            const SizedBox(height: 8),
            Text(
              _addError!,
              style: const TextStyle(
                fontSize: 12,
                fontFamily: 'Consolas',
                color: AppColors.err,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _adding
                    ? null
                    : () => setState(() {
                          _showAdd = false;
                          _picked = const [];
                          _addError = null;
                        }),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _picked.isEmpty || _adding ? null : _submitAdd,
                child: Text(_adding ? 'Adding…' : 'Add'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _memberList() {
    final members = _members;
    if (members == null && _error == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          _error!,
          style: const TextStyle(
            fontSize: 12,
            fontFamily: 'Consolas',
            color: AppColors.err,
          ),
        ),
      );
    }
    if (members == null || members.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Text(
          'No members.',
          style: TextStyle(color: AppColors.ink3, fontSize: 13),
        ),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      itemCount: members.length,
      separatorBuilder: (_, _) => const Divider(
        height: 1,
        color: AppColors.line,
      ),
      itemBuilder: (_, i) {
        final m = members[i];
        final u = m.user;
        if (u == null) return const SizedBox.shrink();
        return _MemberRow(
          user: u,
          role: m.role,
          onAvatarTap: () => _openMemberProfile(u),
        );
      },
    );
  }

  Widget _footer() {
    if (_confirmLeave) {
      return Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.line)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              "Leave this $_convLabel? You'll stop receiving messages.",
              style: const TextStyle(color: AppColors.ink2, fontSize: 13),
            ),
            if (_leaveError != null) ...[
              const SizedBox(height: 6),
              Text(
                _leaveError!,
                style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'Consolas',
                  color: AppColors.err,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _leaving
                      ? null
                      : () => setState(() {
                            _confirmLeave = false;
                            _leaveError = null;
                          }),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _leaving ? null : _submitLeave,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.err,
                    foregroundColor: Colors.white,
                  ),
                  child: Text(_leaving ? 'Leaving…' : 'Leave $_convLabel'),
                ),
              ],
            ),
          ],
        ),
      );
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => setState(() => _confirmLeave = true),
        child: Container(
          height: 48,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AppColors.line)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.logout, color: AppColors.err, size: 16),
              const SizedBox(width: 8),
              Text(
                'Leave $_convLabel',
                style: const TextStyle(
                  color: AppColors.err,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.user,
    required this.role,
    required this.onAvatarTap,
  });
  final User user;
  final String role;
  final VoidCallback onAvatarTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        children: [
          GestureDetector(
            onTap: onAvatarTap,
            child: Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: avatarColor(user.avatarColor, user.displayName),
                shape: BoxShape.circle,
              ),
              child: Text(
                avatarInitials(
                  user.displayName.isNotEmpty
                      ? user.displayName
                      : user.handle,
                ),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  user.displayName.isNotEmpty
                      ? user.displayName
                      : '@${user.handle}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    color: AppColors.ink1,
                  ),
                ),
                if (user.handle.isNotEmpty)
                  Text(
                    '@${user.handle}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'Consolas',
                      color: AppColors.ink3,
                    ),
                  ),
              ],
            ),
          ),
          if (role.isNotEmpty && role != 'member')
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.line),
                borderRadius: BorderRadius.circular(AppRadii.rSm),
              ),
              child: Text(
                role.toUpperCase(),
                style: const TextStyle(
                  fontSize: 10,
                  letterSpacing: 1.2,
                  fontFamily: 'Consolas',
                  color: AppColors.ember,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

String _msg(Object e, String fallback) {
  if (e is ConnectError) return e.message.isNotEmpty ? e.message : fallback;
  final s = e.toString();
  return s.isEmpty ? fallback : s;
}
