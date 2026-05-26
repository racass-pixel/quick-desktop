// Compact search input with 300ms debounce. Emits the cleaned query string
// to its parent which performs the actual `Messaging.SearchMessages` call.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../theme/theme.dart';

class MessageSearchBar extends StatefulWidget {
  const MessageSearchBar({
    super.key,
    required this.onQuery,
    this.hint = 'Search messages',
    this.autofocus = false,
    this.trailing,
  });
  final void Function(String query) onQuery;
  final String hint;
  final bool autofocus;
  final Widget? trailing;

  @override
  State<MessageSearchBar> createState() => _MessageSearchBarState();
}

class _MessageSearchBarState extends State<MessageSearchBar> {
  final _ctrl = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      widget.onQuery(v.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _ctrl,
              autofocus: widget.autofocus,
              onChanged: _onChanged,
              decoration: InputDecoration(
                hintText: widget.hint,
                isDense: true,
                prefixIcon:
                    const Icon(Icons.search, size: 16, color: AppColors.ink3),
                suffixIcon: _ctrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close,
                            size: 14, color: AppColors.ink3),
                        onPressed: () {
                          _ctrl.clear();
                          widget.onQuery('');
                          setState(() {});
                        },
                      ),
              ),
            ),
          ),
          if (widget.trailing != null) ...[
            const SizedBox(width: 6),
            widget.trailing!,
          ],
        ],
      ),
    );
  }
}
