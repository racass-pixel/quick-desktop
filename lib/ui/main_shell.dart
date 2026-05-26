// Two-pane shell: left rail with conversations + search, right pane with the
// open chat (delegated to the child route).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/providers.dart';
import '../theme/theme.dart';
import 'widgets/avatar.dart';
import 'conversation_list.dart';

class MainShell extends ConsumerWidget {
  const MainShell({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(authControllerProvider).user;
    return Scaffold(
      body: Row(
        children: [
          SizedBox(
            width: 360,
            child: Container(
              decoration: const BoxDecoration(
                color: AppColors.panel,
                border: Border(right: BorderSide(color: AppColors.line)),
              ),
              child: Column(
                children: [
                  // Top bar with me + hamburger.
                  Container(
                    height: 56,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: AppColors.line)),
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.menu, color: AppColors.ink2),
                          tooltip: 'Menu',
                          onPressed: () {
                            // TODO: drawer with settings, blocks, etc.
                          },
                        ),
                        const SizedBox(width: 4),
                        if (me != null) ...[
                          Avatar(
                            name: me.displayName.isNotEmpty
                                ? me.displayName
                                : me.handle,
                            colorHex: me.avatarColor,
                            size: 32,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  me.displayName.isNotEmpty
                                      ? me.displayName
                                      : me.handle,
                                  style: const TextStyle(
                                    color: AppColors.ink1,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  '@${me.handle}',
                                  style: const TextStyle(
                                    color: AppColors.ink3,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.logout,
                                color: AppColors.ink3, size: 18),
                            tooltip: 'Sign out',
                            onPressed: () async {
                              await ref
                                  .read(authControllerProvider.notifier)
                                  .signOut();
                              if (context.mounted) context.go('/login');
                            },
                          ),
                        ] else
                          const Expanded(child: SizedBox.shrink()),
                      ],
                    ),
                  ),
                  const Expanded(child: ConversationListPane()),
                ],
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}
