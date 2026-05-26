// Compact search-and-select control used by the create-group + add-members
// flows. Lookup hits quick.v1.Users.Search with a 250 ms debounce.
//
// The picker is intentionally minimal — no virtualized list, no batching —
// because the foundation will eventually replace it with a richer
// "ChatRecents" picker. Built here so the create-group flow is self-contained.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../api/dto.dart';
import '../../../theme/theme.dart';
import '../../settings/api/users_api.dart';

class UserMultiPicker extends StatefulWidget {
  const UserMultiPicker({
    super.key,
    required this.usersApi,
    required this.selected,
    required this.onChanged,
    this.placeholder = 'Add by handle…',
    this.excludeIds = const {},
  });

  final SettingsUsersApi usersApi;
  final List<User> selected;
  final ValueChanged<List<User>> onChanged;
  final String placeholder;
  final Set<String> excludeIds;

  @override
  State<UserMultiPicker> createState() => _UserMultiPickerState();
}

class _UserMultiPickerState extends State<UserMultiPicker> {
  final TextEditingController _q = TextEditingController();
  Timer? _debounce;
  List<User> _results = const [];
  bool _loading = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    if (v.trim().isEmpty) {
      setState(() => _results = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 250), _run);
  }

  Future<void> _run() async {
    final q = _q.text.trim().replaceFirst(RegExp(r'^@'), '');
    if (q.isEmpty) return;
    setState(() => _loading = true);
    try {
      final users = await widget.usersApi.search(q);
      if (!mounted) return;
      final selectedIds = widget.selected.map((u) => u.id).toSet();
      setState(() {
        _results = users
            .where((u) => !selectedIds.contains(u.id) && !widget.excludeIds.contains(u.id))
            .toList();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _results = const [];
        _loading = false;
      });
    }
  }

  void _add(User u) {
    widget.onChanged([...widget.selected, u]);
    _q.clear();
    setState(() => _results = const []);
  }

  void _remove(User u) {
    widget.onChanged(widget.selected.where((s) => s.id != u.id).toList());
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.selected.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final u in widget.selected)
                  _Chip(
                    label: u.handle.isNotEmpty ? '@${u.handle}' : u.displayName,
                    onRemove: () => _remove(u),
                  ),
              ],
            ),
          ),
        TextField(
          controller: _q,
          onChanged: _onChanged,
          decoration: InputDecoration(
            hintText: widget.placeholder,
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 16, color: AppColors.ink3),
          ),
          style: const TextStyle(fontSize: 14, color: AppColors.ink1),
        ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(
              minHeight: 1,
              color: AppColors.ember,
              backgroundColor: AppColors.line,
            ),
          )
        else if (_results.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Container(
              constraints: const BoxConstraints(maxHeight: 200),
              decoration: BoxDecoration(
                color: AppColors.raised,
                borderRadius: BorderRadius.circular(AppRadii.rMd),
                border: Border.all(color: AppColors.line),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _results.length,
                itemBuilder: (ctx, i) {
                  final u = _results[i];
                  return Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => _add(u),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        child: Row(
                          children: [
                            Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: avatarColor(u.avatarColor, u.displayName),
                                shape: BoxShape.circle,
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                avatarInitials(u.displayName.isNotEmpty ? u.displayName : u.handle),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    u.displayName.isNotEmpty ? u.displayName : '@${u.handle}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: AppColors.ink1,
                                    ),
                                  ),
                                  if (u.handle.isNotEmpty)
                                    Text(
                                      '@${u.handle}',
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
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.onRemove});
  final String label;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.raised,
        borderRadius: BorderRadius.circular(AppRadii.rSm),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontFamily: 'Consolas',
              color: AppColors.ink1,
            ),
          ),
          const SizedBox(width: 6),
          Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onRemove,
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(Icons.close, size: 12, color: AppColors.ink3),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
