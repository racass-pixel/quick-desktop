// Telegram K-style profile dialog. Centered modal, 360 px wide, dark panel
// background, rounded-2xl. Mirrors quick-web's ProfileModal layout:
//
//   - Top-right close button.
//   - 104 px avatar centered above the display name.
//   - Presence row (ember "online" dot + label, or "last seen ...").
//   - 4-up action grid card: Message / Mute / Call / More.
//       * Mute is always disabled (notifications not shipped yet).
//       * More opens a popover with "Copy handle" + non-self "Block user".
//   - Bio card (italic "No bio yet" when empty).
//   - Username row with @handle + copy button + 1.5 s ember "Copied" toast.
//   - Full-width red "Block user" row at the bottom (hidden in self mode).
//
// Self mode (`isSelf: true`) hides the Message and Call slots but renders
// placeholder boxes so the 4-column grid stays aligned. Block is also hidden.
//
// Callbacks let the host wire navigation + side effects without binding this
// widget to a specific Riverpod/GoRouter setup. `onMessage` should open the
// resulting DM (host typically calls Messaging.OpenDM and routes to the chat),
// `onCall` starts a voice call.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../api/connect.dart';
import '../../../api/dto.dart';
import '../../../theme/theme.dart';
import '../api/users_api.dart';

Future<void> showProfileModal(
  BuildContext context,
  User user, {
  required SettingsUsersApi usersApi,
  bool isSelf = false,
  Presence? presence,
  Future<void> Function(User user)? onMessage,
  Future<void> Function(User user)? onCall,
  VoidCallback? onBlocked,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (ctx) => ProfileModal(
      user: user,
      usersApi: usersApi,
      isSelf: isSelf,
      presence: presence,
      onMessage: onMessage,
      onCall: onCall,
      onBlocked: onBlocked,
    ),
  );
}

class ProfileModal extends StatefulWidget {
  const ProfileModal({
    super.key,
    required this.user,
    required this.usersApi,
    this.isSelf = false,
    this.presence,
    this.onMessage,
    this.onCall,
    this.onBlocked,
  });

  final User user;
  final SettingsUsersApi usersApi;
  final bool isSelf;
  final Presence? presence;
  final Future<void> Function(User user)? onMessage;
  final Future<void> Function(User user)? onCall;
  final VoidCallback? onBlocked;

  @override
  State<ProfileModal> createState() => _ProfileModalState();
}

class _ProfileModalState extends State<ProfileModal> {
  String? _busy; // 'dm' | 'call' | 'block'
  String? _error;
  bool _copied = false;
  Timer? _copyTimer;
  final GlobalKey _moreKey = GlobalKey();

  @override
  void dispose() {
    _copyTimer?.cancel();
    super.dispose();
  }

  String get _titleText {
    final dn = widget.user.displayName.trim();
    final h = widget.user.handle;
    final hasDistinct = dn.isNotEmpty && dn != h;
    if (hasDistinct) return dn;
    if (h.isNotEmpty) return '@$h';
    return 'Unknown';
  }

  String get _avatarName =>
      widget.user.displayName.isNotEmpty ? widget.user.displayName : (widget.user.handle.isNotEmpty ? widget.user.handle : 'Unknown');

  Future<void> _doMessage() async {
    final cb = widget.onMessage;
    if (cb == null || _busy != null) return;
    setState(() {
      _busy = 'dm';
      _error = null;
    });
    try {
      await cb(widget.user);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = null;
          _error = _msg(e, 'Could not open DM.');
        });
      }
    }
  }

  Future<void> _doCall() async {
    final cb = widget.onCall;
    if (cb == null || _busy != null) return;
    setState(() {
      _busy = 'call';
      _error = null;
    });
    try {
      await cb(widget.user);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = null;
          _error = _msg(e, 'Could not start call.');
        });
      }
    }
  }

  Future<void> _doBlock() async {
    if (_busy != null) return;
    final label = widget.user.handle.isNotEmpty ? '@${widget.user.handle}' : _titleText;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: Text('Block $label?'),
        content: const Text("You won't receive their messages."),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.err),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Block'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _busy = 'block';
      _error = null;
    });
    try {
      await widget.usersApi.block(widget.user.id);
      widget.onBlocked?.call();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = null;
          _error = _msg(e, 'Could not block.');
        });
      }
    }
  }

  void _copyHandle() {
    final h = widget.user.handle;
    if (h.isEmpty) return;
    Clipboard.setData(ClipboardData(text: '@$h'));
    setState(() => _copied = true);
    _copyTimer?.cancel();
    _copyTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  void _openMoreMenu() {
    final ctx = _moreKey.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(ctx).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    final rect = origin & box.size;
    final pos = RelativeRect.fromLTRB(
      rect.left,
      rect.bottom + 4,
      overlay.size.width - rect.right,
      0,
    );
    showMenu<String>(
      context: ctx,
      position: pos,
      color: AppColors.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.rMd),
        side: const BorderSide(color: AppColors.line),
      ),
      items: [
        if (widget.user.handle.isNotEmpty)
          const PopupMenuItem<String>(
            value: 'copy',
            child: Text('Copy handle', style: TextStyle(color: AppColors.ink1)),
          ),
        if (!widget.isSelf)
          const PopupMenuItem<String>(
            value: 'block',
            child: Text('Block user', style: TextStyle(color: AppColors.err)),
          ),
      ],
    ).then((v) {
      if (v == 'copy') _copyHandle();
      if (v == 'block') _doBlock();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isSelf = widget.isSelf;
    final handle = widget.user.handle;
    final bio = widget.user.bio.trim();
    final presence = widget.presence;
    final online = presence?.online == true && !isSelf;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.panel,
            borderRadius: BorderRadius.circular(AppRadii.rXl),
            border: Border.all(color: AppColors.line),
            boxShadow: const [
              BoxShadow(color: Colors.black54, blurRadius: 32, offset: Offset(0, 12)),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.rXl),
            child: Stack(
              children: [
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Avatar + identity.
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 32, 24, 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _Avatar(
                            displayName: _avatarName,
                            colorHex: widget.user.avatarColor,
                            size: 104,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _titleText,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w600,
                              color: AppColors.ink1,
                              height: 1.15,
                            ),
                          ),
                          const SizedBox(height: 4),
                          if (isSelf)
                            const Text(
                              'This is you',
                              style: TextStyle(fontSize: 12, color: AppColors.ink3),
                            )
                          else
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (online)
                                  Container(
                                    margin: const EdgeInsets.only(right: 6),
                                    width: 6,
                                    height: 6,
                                    decoration: const BoxDecoration(
                                      color: AppColors.ember,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                Text(
                                  _presenceLabel(presence),
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: online ? AppColors.ember : AppColors.ink3,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),

                    // Action grid card.
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppColors.raised.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(AppRadii.rLg),
                          border: Border.all(color: AppColors.line),
                        ),
                        padding: const EdgeInsets.all(4),
                        child: Row(
                          children: [
                            Expanded(
                              child: _ActionCell(
                                icon: Icons.chat_bubble_outline,
                                label: _busy == 'dm' ? '…' : 'Message',
                                onTap: isSelf ? null : _doMessage,
                                hidden: isSelf,
                                active: !isSelf,
                              ),
                            ),
                            Expanded(
                              child: _ActionCell(
                                icon: Icons.notifications_none,
                                label: 'Mute',
                                onTap: null,
                                active: false,
                                tooltip: 'Notifications coming soon',
                              ),
                            ),
                            Expanded(
                              child: _ActionCell(
                                icon: Icons.call_outlined,
                                label: _busy == 'call' ? '…' : 'Call',
                                onTap: isSelf ? null : _doCall,
                                hidden: isSelf,
                                active: !isSelf,
                              ),
                            ),
                            Expanded(
                              child: _ActionCell(
                                key: _moreKey,
                                icon: Icons.more_horiz,
                                label: 'More',
                                onTap: _busy == null ? _openMoreMenu : null,
                                active: true,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // Bio + username card.
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(AppRadii.rMd),
                          border: Border.all(color: AppColors.line),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const _Kicker('Bio'),
                                  const SizedBox(height: 4),
                                  if (bio.isEmpty)
                                    const Text(
                                      'No bio yet',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontStyle: FontStyle.italic,
                                        color: AppColors.ink3,
                                      ),
                                    )
                                  else
                                    Text(
                                      bio,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        color: AppColors.ink1,
                                        height: 1.4,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            if (handle.isNotEmpty) ...[
                              const Divider(height: 1, color: AppColors.line),
                              Padding(
                                padding: const EdgeInsets.all(16),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '@$handle',
                                            style: const TextStyle(
                                              fontSize: 13,
                                              fontFamily: 'Consolas',
                                              color: AppColors.ember,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          const _Kicker('Username'),
                                          if (_copied) ...[
                                            const SizedBox(height: 4),
                                            const Text(
                                              'Copied',
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontFamily: 'Consolas',
                                                color: AppColors.ember,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      onPressed: _copyHandle,
                                      icon: const Icon(Icons.copy, size: 16),
                                      color: AppColors.ink3,
                                      tooltip: 'Copy handle',
                                      style: IconButton.styleFrom(
                                        backgroundColor: Colors.transparent,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(AppRadii.rSm),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),

                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 12,
                            fontFamily: 'Consolas',
                            color: AppColors.err,
                          ),
                        ),
                      ),

                    if (!isSelf) ...[
                      const Divider(height: 1, color: AppColors.line),
                      InkWell(
                        onTap: _busy == null ? _doBlock : null,
                        child: SizedBox(
                          height: 48,
                          child: Center(
                            child: Text(
                              _busy == 'block' ? 'Blocking…' : 'Block user',
                              style: const TextStyle(
                                color: AppColors.err,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),

                // Top-right close.
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    color: AppColors.ink3,
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
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

String _presenceLabel(Presence? p) {
  if (p == null) return 'last seen recently';
  if (p.online) return 'online';
  final last = p.lastSeenAt;
  if (last == null) return 'last seen recently';
  final delta = DateTime.now().difference(last);
  if (delta.inMinutes < 1) return 'last seen just now';
  if (delta.inMinutes < 60) return 'last seen ${delta.inMinutes}m ago';
  if (delta.inHours < 24) return 'last seen ${delta.inHours}h ago';
  if (delta.inDays < 7) return 'last seen ${delta.inDays}d ago';
  return 'last seen a while ago';
}

String _msg(Object e, String fallback) {
  if (e is ConnectError) return e.message.isNotEmpty ? e.message : fallback;
  final s = e.toString();
  return s.isEmpty ? fallback : s;
}

class _Kicker extends StatelessWidget {
  const _Kicker(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 10,
          letterSpacing: 1.2,
          fontFamily: 'Consolas',
          color: AppColors.ink3,
        ),
      );
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

class _ActionCell extends StatelessWidget {
  const _ActionCell({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
    this.hidden = false,
    this.active = false,
    this.tooltip,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool hidden;
  final bool active;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    if (hidden) return const SizedBox(height: 60);
    final iconColor = active ? AppColors.ember : AppColors.ink3.withValues(alpha: 0.6);
    final labelColor = active ? AppColors.ink2 : AppColors.ink3.withValues(alpha: 0.6);
    final body = SizedBox(
      height: 60,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadii.rMd),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 20, color: iconColor),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: labelColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (tooltip != null) return Tooltip(message: tooltip!, child: body);
    return body;
  }
}
