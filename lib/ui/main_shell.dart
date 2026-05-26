// Two-pane shell: left rail with conversations + search, right pane with the
// open chat (delegated to the child route). Hosts the SidebarDrawer overlay.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/groups/widgets/create_channel_dialog.dart';
import '../features/groups/widgets/create_group_dialog.dart';
import '../features/settings/widgets/profile_modal.dart';
import '../features/settings/widgets/sidebar_drawer.dart';
import '../services/notifications_bridge.dart';
import '../state/providers.dart';
import '../theme/theme.dart';
import '../widgets/toast_layer.dart';
import 'conversation_list.dart';
import 'widgets/avatar.dart';

class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  bool _drawerOpen = false;

  @override
  void initState() {
    super.initState();
    // Hand the notifications bridge a router-aware navigation callback. The
    // bridge invokes it when the user clicks a toast.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      NotificationsBridge.onOpenChat = (convId) {
        if (!mounted) return;
        context.go('/chats/$convId');
      };
    });
  }

  @override
  void dispose() {
    NotificationsBridge.onOpenChat = null;
    super.dispose();
  }

  void _openDrawer() => setState(() => _drawerOpen = true);
  void _closeDrawer() => setState(() => _drawerOpen = false);

  Future<void> _logout() async {
    _closeDrawer();
    await ref.read(authControllerProvider.notifier).signOut();
    if (mounted) context.go('/login');
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(authControllerProvider).user;
    final settingsUsersApi = ref.read(settingsUsersApiProvider);
    final groupsApi = ref.read(groupsApiProvider);
    return Stack(
      children: [
        Scaffold(
          body: Row(
        children: [
          SizedBox(
            width: 360,
            child: Stack(
              children: [
                Container(
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
                          border:
                              Border(bottom: BorderSide(color: AppColors.line)),
                        ),
                        child: Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.menu,
                                  color: AppColors.ink2),
                              tooltip: 'Menu',
                              onPressed: _openDrawer,
                            ),
                            const SizedBox(width: 4),
                            if (me != null) ...[
                              GestureDetector(
                                onTap: () => showProfileModal(
                                  context,
                                  me,
                                  usersApi: settingsUsersApi,
                                  isSelf: true,
                                ),
                                child: Avatar(
                                  name: me.displayName.isNotEmpty
                                      ? me.displayName
                                      : me.handle,
                                  colorHex: me.avatarColor,
                                  size: 32,
                                ),
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
                                onPressed: _logout,
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
                // Drawer overlay covers only the left rail.
                if (me != null)
                  Positioned.fill(
                    child: IgnorePointer(
                      ignoring: !_drawerOpen,
                      child: SidebarDrawer(
                        open: _drawerOpen,
                        me: me,
                        onClose: _closeDrawer,
                        onProfile: () {
                          _closeDrawer();
                          showProfileModal(
                            context,
                            me,
                            usersApi: settingsUsersApi,
                            isSelf: true,
                          );
                        },
                        onNewGroup: () {
                          _closeDrawer();
                          showCreateGroupDialog(
                            context,
                            groupsApi: groupsApi,
                            usersApi: settingsUsersApi,
                            onCreated: (id) => context.go('/chats/$id'),
                          );
                        },
                        onNewChannel: () {
                          _closeDrawer();
                          showCreateChannelDialog(
                            context,
                            groupsApi: groupsApi,
                            onCreated: (id) => context.go('/chats/$id'),
                          );
                        },
                        onSettings: () {
                          _closeDrawer();
                          context.go('/settings');
                        },
                        onLogout: _logout,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(child: widget.child),
        ],
      ),
        ),
        // Toast overlay floats above everything in the shell. It is hit-test
        // transparent except on its own widgets (the cards use InkWell).
        const ToastLayer(),
      ],
    );
  }
}
