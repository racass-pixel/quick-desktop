// Telegram-style hamburger drawer for the chats sidebar.
//
// Slides in from the left over the chat list at 280 px wide. Renders the
// signed-in user identity at the top, primary nav (My Profile / New Group /
// New Channel / Settings) in the middle, and a red Log out pinned to the
// bottom.
//
// This widget owns its dismiss surface (backdrop tap + ESC). Each menu entry
// delegates to a host-provided callback so the drawer is decoupled from
// routing, dialog stacks, and Riverpod wiring.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../api/dto.dart';
import '../../../theme/theme.dart';

class SidebarDrawer extends StatelessWidget {
  const SidebarDrawer({
    super.key,
    required this.open,
    required this.me,
    required this.onClose,
    required this.onProfile,
    required this.onNewGroup,
    required this.onNewChannel,
    required this.onSettings,
    required this.onLogout,
  });

  final bool open;
  final User me;
  final VoidCallback onClose;
  final VoidCallback onProfile;
  final VoidCallback onNewGroup;
  final VoidCallback onNewChannel;
  final VoidCallback onSettings;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: open,
      onKeyEvent: (node, event) {
        if (open &&
            event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          onClose();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Stack(
        children: [
          // Backdrop — only mounted while open so it doesn't swallow clicks.
          if (open)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onClose,
                child: Container(color: Colors.black.withValues(alpha: 0.4)),
              ),
            ),
          // Panel — always mounted so the slide transition can play both
          // directions; visibility is driven by AnimatedSlide.
          AnimatedSlide(
            offset: open ? Offset.zero : const Offset(-1, 0),
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            child: IgnorePointer(
              ignoring: !open,
              child: SizedBox(
                width: 280,
                height: double.infinity,
                child: Material(
                  color: AppColors.panel,
                  child: Container(
                    decoration: const BoxDecoration(
                      border: Border(right: BorderSide(color: AppColors.line)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Identity(me: me),
                        Expanded(
                          child: ListView(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            children: [
                              _MenuItem(
                                icon: Icons.account_circle_outlined,
                                label: 'My Profile',
                                onTap: onProfile,
                              ),
                              _MenuItem(
                                icon: Icons.group_outlined,
                                label: 'New Group',
                                onTap: onNewGroup,
                              ),
                              _MenuItem(
                                icon: Icons.campaign_outlined,
                                label: 'New Channel',
                                onTap: onNewChannel,
                              ),
                              _MenuItem(
                                icon: Icons.settings_outlined,
                                label: 'Settings',
                                onTap: onSettings,
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1, color: AppColors.line),
                        _MenuItem(
                          icon: Icons.logout,
                          label: 'Logout',
                          danger: true,
                          onTap: onLogout,
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Identity extends StatelessWidget {
  const _Identity({required this.me});
  final User me;

  @override
  Widget build(BuildContext context) {
    final name = me.displayName.isNotEmpty ? me.displayName : '@${me.handle}';
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Avatar(
            displayName: me.displayName.isNotEmpty ? me.displayName : me.handle,
            colorHex: me.avatarColor,
            size: 56,
          ),
          const SizedBox(height: 12),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: AppColors.ink1,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '@${me.handle}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              fontFamily: 'Consolas',
              color: AppColors.ink3,
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  const _MenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.err : AppColors.ink1;
    final iconColor = danger ? AppColors.err : AppColors.ink3;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Icon(icon, size: 20, color: iconColor),
                const SizedBox(width: 16),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.displayName,
    required this.colorHex,
    required this.size,
  });
  final String displayName;
  final String colorHex;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = avatarColor(colorHex, displayName);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: c, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text(
        avatarInitials(displayName),
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.36,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
