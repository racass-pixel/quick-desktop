// Single-step modal for creating a broadcast channel.
//
// Captures a name (1–40 chars) and a handle (`@`, 3–20 chars `[a-z0-9_]`),
// then calls CreateChannel. The wire today only carries `title`; the handle
// is concatenated into the title as `Name (@handle)` so it surfaces in the
// chat list, and is also kept in local state so a future ChannelMeta column
// can be backfilled without UI churn.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../api/connect.dart';
import '../../../theme/theme.dart';
import '../api/groups_api.dart';

Future<void> showCreateChannelDialog(
  BuildContext context, {
  required GroupsApi groupsApi,
  required void Function(String conversationId) onCreated,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (ctx) => CreateChannelDialog(
      groupsApi: groupsApi,
      onCreated: onCreated,
    ),
  );
}

class CreateChannelDialog extends StatefulWidget {
  const CreateChannelDialog({
    super.key,
    required this.groupsApi,
    required this.onCreated,
  });

  final GroupsApi groupsApi;
  final void Function(String conversationId) onCreated;

  @override
  State<CreateChannelDialog> createState() => _CreateChannelDialogState();
}

final RegExp _handleRe = RegExp(r'^[a-z0-9_]{3,20}$');

class _CreateChannelDialogState extends State<CreateChannelDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _handle = TextEditingController();
  String? _nameError;
  String? _handleError;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _handle.dispose();
    super.dispose();
  }

  bool _validate() {
    final name = _name.text.trim();
    final h = _handle.text.trim();
    String? n;
    String? he;
    if (name.isEmpty || name.length > 40) n = '1–40 characters.';
    if (!_handleRe.hasMatch(h)) he = '3–20 chars, a–z, 0–9, _.';
    setState(() {
      _nameError = n;
      _handleError = he;
    });
    return n == null && he == null;
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!_validate()) return;
    final name = _name.text.trim();
    final h = _handle.text.trim();
    // Encode the handle into the title so it appears in the conversation list
    // immediately. Foundation will swap this for a dedicated channel-handle
    // column when one ships.
    final title = '$name (@$h)';
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final conv = await widget.groupsApi.createChannel(title);
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onCreated(conv.id);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _msg(e, 'Could not create channel.');
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
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 12),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppColors.line)),
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'New channel',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: AppColors.ink1,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    color: AppColors.ink3,
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: 'Close',
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Channel name',
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
                      hintText: 'e.g. Product updates',
                      counterText: '',
                      isDense: true,
                    ),
                    style: const TextStyle(color: AppColors.ink1, fontSize: 14),
                    onChanged: (_) => setState(() {}),
                  ),
                  if (_nameError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        _nameError!,
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'Consolas',
                          color: AppColors.err,
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  const Text(
                    'Public handle',
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'Consolas',
                      color: AppColors.ink3,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _handle,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[a-z0-9_]')),
                      LengthLimitingTextInputFormatter(20),
                    ],
                    decoration: const InputDecoration(
                      prefixText: '@',
                      prefixStyle: TextStyle(
                        color: AppColors.ink3,
                        fontSize: 13,
                        fontFamily: 'Consolas',
                      ),
                      counterText: '',
                      isDense: true,
                    ),
                    style: const TextStyle(color: AppColors.ink1, fontSize: 14),
                    onChanged: (_) => setState(() {}),
                  ),
                  if (_handleError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        _handleError!,
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'Consolas',
                          color: AppColors.err,
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  const Text(
                    'Only admins can post; everyone else reads.',
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'Consolas',
                      color: AppColors.ink3,
                    ),
                  ),
                ],
              ),
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
                  ElevatedButton(
                    onPressed: _busy ? null : _submit,
                    child: Text(_busy ? 'Creating…' : 'Create channel'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _msg(Object e, String fallback) {
  if (e is ConnectError) return e.message.isNotEmpty ? e.message : fallback;
  final s = e.toString();
  return s.isEmpty ? fallback : s;
}
