// Modal that forwards a message to another conversation. Lists every open
// conversation with a search box on top; tapping a row hits
// Messaging.ForwardMessage and shows a SnackBar confirmation.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../api/dto.dart';
import '../../../state/chats_controller.dart';
import '../../../theme/theme.dart';
import '../../../ui/widgets/avatar.dart';

void showForwardModal(
  BuildContext context, {
  required Message sourceMessage,
  required WidgetRef ref,
}) {
  showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (ctx) => _ForwardDialog(source: sourceMessage, parentRef: ref),
  );
}

class _ForwardDialog extends ConsumerStatefulWidget {
  const _ForwardDialog({required this.source, required this.parentRef});
  final Message source;
  final WidgetRef parentRef;
  @override
  ConsumerState<_ForwardDialog> createState() => _ForwardDialogState();
}

class _ForwardDialogState extends ConsumerState<_ForwardDialog> {
  final _ctrl = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatsControllerProvider);
    final all = state.order.map((id) => state.byId[id]!).toList();
    final q = _q.trim().toLowerCase();
    final list = q.isEmpty
        ? all
        : all
            .where((c) =>
                c.displayTitle().toLowerCase().contains(q) ||
                (c.peer?.handle.toLowerCase().contains(q) ?? false))
            .toList();
    return Dialog(
      backgroundColor: AppColors.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.rLg),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 540),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(
                children: [
                  const Icon(Icons.forward, size: 18, color: AppColors.ink2),
                  const SizedBox(width: 8),
                  const Text(
                    'Forward to…',
                    style: TextStyle(
                      color: AppColors.ink1,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close,
                        size: 16, color: AppColors.ink3),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _ctrl,
                autofocus: true,
                onChanged: (v) => setState(() => _q = v),
                decoration: const InputDecoration(
                  hintText: 'Search chats',
                  isDense: true,
                  prefixIcon:
                      Icon(Icons.search, size: 16, color: AppColors.ink3),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: list.isEmpty
                  ? const Center(
                      child: Text('No chats',
                          style:
                              TextStyle(color: AppColors.ink3, fontSize: 13)),
                    )
                  : ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (_, i) {
                        final c = list[i];
                        return Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () async {
                              final m = await ref
                                  .read(chatsControllerProvider.notifier)
                                  .forwardMessage(widget.source.id, c.id);
                              if (!mounted) return;
                              Navigator.of(context).pop();
                              if (m != null) {
                                ScaffoldMessenger.of(context)
                                  ..hideCurrentSnackBar()
                                  ..showSnackBar(SnackBar(
                                    duration: const Duration(seconds: 2),
                                    backgroundColor: AppColors.raised,
                                    content: Text(
                                      'Forwarded to ${c.displayTitle()}',
                                      style: const TextStyle(
                                          color: AppColors.ink1),
                                    ),
                                  ));
                              }
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 10),
                              child: Row(
                                children: [
                                  Avatar(
                                    name: c.avatarSeed(),
                                    colorHex: c.avatarColorHex(),
                                    size: 36,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          c.displayTitle(),
                                          style: const TextStyle(
                                            color: AppColors.ink1,
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        if (c.peer != null)
                                          Text('@${c.peer!.handle}',
                                              style: const TextStyle(
                                                  color: AppColors.ink3,
                                                  fontSize: 11.5))
                                        else
                                          Text(c.type,
                                              style: const TextStyle(
                                                  color: AppColors.ink3,
                                                  fontSize: 11.5)),
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
          ],
        ),
      ),
    );
  }
}
