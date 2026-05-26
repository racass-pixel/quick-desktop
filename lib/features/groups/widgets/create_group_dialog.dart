// Two-step modal for creating a new group:
//
//   1. Name (1–40 chars) → Continue
//   2. Optional Add Members (multi-select via UserMultiPicker) → Create
//
// On success the dialog dismisses and invokes `onCreated(conversationId)` so
// the host can route the user into the new group conversation. The create call
// itself is a single CreateGroup; members are added with a follow-up
// AddMembers when the user added any.

import 'package:flutter/material.dart';

import '../../../api/connect.dart';
import '../../../api/dto.dart';
import '../../../theme/theme.dart';
import '../../settings/api/users_api.dart';
import '../api/groups_api.dart';
import 'user_multi_picker.dart';

Future<void> showCreateGroupDialog(
  BuildContext context, {
  required GroupsApi groupsApi,
  required SettingsUsersApi usersApi,
  required void Function(String conversationId) onCreated,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (ctx) => CreateGroupDialog(
      groupsApi: groupsApi,
      usersApi: usersApi,
      onCreated: onCreated,
    ),
  );
}

class CreateGroupDialog extends StatefulWidget {
  const CreateGroupDialog({
    super.key,
    required this.groupsApi,
    required this.usersApi,
    required this.onCreated,
  });

  final GroupsApi groupsApi;
  final SettingsUsersApi usersApi;
  final void Function(String conversationId) onCreated;

  @override
  State<CreateGroupDialog> createState() => _CreateGroupDialogState();
}

enum _Step { name, members }

class _CreateGroupDialogState extends State<CreateGroupDialog> {
  final TextEditingController _name = TextEditingController();
  _Step _step = _Step.name;
  List<User> _members = const [];
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _nameValid {
    final v = _name.text.trim();
    return v.isNotEmpty && v.length <= 40;
  }

  Future<void> _submit() async {
    if (_busy) return;
    final title = _name.text.trim();
    if (title.isEmpty || title.length > 40) {
      setState(() => _error = 'Name must be 1–40 characters.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final conv = await widget.groupsApi.createGroup(
        title,
        memberUserIds: _members.map((m) => m.id).toList(),
      );
      if (!mounted) return;
      // If the wire didn't carry the members on the initial create (older
      // backends), retry with an explicit AddMembers call. Today the backend
      // accepts the list inline, but the second call is idempotent and cheap.
      if (_members.isNotEmpty) {
        try {
          await widget.groupsApi.addMembers(
            conv.id,
            _members.map((m) => m.id).toList(),
          );
        } catch (_) {
          // Initial create likely accepted members; swallow.
        }
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onCreated(conv.id);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _msg(e, 'Could not create group.');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.rLg),
        side: const BorderSide(color: AppColors.line),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DialogHeader(
              title: _step == _Step.name ? 'New group' : 'Add members',
              onClose: () => Navigator.of(context).pop(),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: _step == _Step.name ? _nameStep() : _membersStep(),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  _error!,
                  style: const TextStyle(
                    fontSize: 12,
                    fontFamily: 'Consolas',
                    color: AppColors.err,
                  ),
                ),
              ),
            const Divider(height: 1, color: AppColors.line),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  if (_step == _Step.name)
                    ElevatedButton(
                      onPressed: !_nameValid || _busy
                          ? null
                          : () => setState(() => _step = _Step.members),
                      child: const Text('Continue'),
                    )
                  else
                    ElevatedButton(
                      onPressed: _busy ? null : _submit,
                      child: Text(_busy ? 'Creating…' : 'Create group'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _nameStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Group name',
          style: TextStyle(
            fontSize: 11,
            fontFamily: 'Consolas',
            color: AppColors.ink3,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _name,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(
            hintText: 'e.g. Trip planning',
            counterText: '',
            isDense: true,
          ),
          style: const TextStyle(color: AppColors.ink1, fontSize: 14),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) {
            if (_nameValid) setState(() => _step = _Step.members);
          },
        ),
      ],
    );
  }

  Widget _membersStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _name.text.trim(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 14,
            color: AppColors.ink1,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Members (optional)',
          style: TextStyle(
            fontSize: 11,
            fontFamily: 'Consolas',
            color: AppColors.ink3,
          ),
        ),
        const SizedBox(height: 8),
        UserMultiPicker(
          usersApi: widget.usersApi,
          selected: _members,
          onChanged: (list) => setState(() => _members = list),
        ),
        const SizedBox(height: 8),
        Text(
          '${_members.length} selected',
          style: const TextStyle(
            fontSize: 11,
            fontFamily: 'Consolas',
            color: AppColors.ink3,
          ),
        ),
      ],
    );
  }
}

class _DialogHeader extends StatelessWidget {
  const _DialogHeader({required this.title, required this.onClose});
  final String title;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 8, 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppColors.ink1,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            color: AppColors.ink3,
            onPressed: onClose,
            tooltip: 'Close',
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
