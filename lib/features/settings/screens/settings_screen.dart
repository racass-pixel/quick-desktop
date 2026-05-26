// Full-screen Settings route. Telegram K-style: header + scrollable body
// with an Edit-Profile section (avatar + 3 fields, save-on-blur) and an
// Account section (email read-only + red Log out).
//
// The widget is intentionally callback-driven: it does not own auth, does not
// know about navigation, and does not mutate any global store directly.
// Foundation passes in:
//   - `me`            : initial user values for the form
//   - `email`         : the signed-in email for the read-only Account row
//   - `usersApi`      : transport for UpdateProfile
//   - `onUserUpdated` : optional cache mirror callback the host can use to
//                       update its in-memory User after a successful save
//   - `onLogout`      : host clears tokens + routes to /auth
//   - `onBack`        : pops or navigates per host's routing choice. When
//                       null, falls back to Navigator.maybePop.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../api/connect.dart';
import '../../../api/dto.dart';
import '../../../theme/theme.dart';
import '../api/users_api.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.me,
    required this.email,
    required this.usersApi,
    required this.onLogout,
    this.onUserUpdated,
    this.onBack,
  });

  final User me;
  final String email;
  final SettingsUsersApi usersApi;
  final VoidCallback onLogout;
  final void Function(User user)? onUserUpdated;
  final VoidCallback? onBack;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

// Mirrors quick-web/src/components/auth/HandleField.tsx
final RegExp _handleRe = RegExp(r'^[a-z0-9_]{3,20}$');

class _SettingsScreenState extends State<SettingsScreen> {
  late User _user;
  late final TextEditingController _name;
  late final TextEditingController _handle;
  late final TextEditingController _bio;
  String? _nameError;
  String? _handleError;
  String? _bioError;

  @override
  void initState() {
    super.initState();
    _user = widget.me;
    _name = TextEditingController(text: _user.displayName);
    _handle = TextEditingController(text: _user.handle);
    _bio = TextEditingController(text: _user.bio);
  }

  @override
  void dispose() {
    _name.dispose();
    _handle.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _saveName() async {
    final next = _name.text.trim();
    if (next == _user.displayName) return;
    if (next.isEmpty || next.length > 40) {
      setState(() => _nameError = '1–40 characters.');
      return;
    }
    setState(() => _nameError = null);
    try {
      final u = await widget.usersApi.updateProfile(displayName: next);
      _commitUser(u);
    } catch (e) {
      setState(() => _nameError = _msg(e, 'Could not save.'));
    }
  }

  Future<void> _saveHandle() async {
    final next = _handle.text.trim();
    if (next == _user.handle) return;
    if (!_handleRe.hasMatch(next)) {
      setState(() => _handleError = '3–20 chars, a–z, 0–9, _.');
      return;
    }
    setState(() => _handleError = null);
    try {
      final u = await widget.usersApi.updateProfile(handle: next);
      _commitUser(u);
    } catch (e) {
      setState(() => _handleError = _msg(e, 'Handle unavailable.'));
    }
  }

  Future<void> _saveBio() async {
    final next = _bio.text;
    if (next == _user.bio) return;
    if (next.length > 256) {
      setState(() => _bioError = 'Max 256 characters.');
      return;
    }
    setState(() => _bioError = null);
    try {
      final u = await widget.usersApi.updateProfile(bio: next);
      _commitUser(u);
    } catch (e) {
      setState(() => _bioError = _msg(e, 'Could not save.'));
    }
  }

  void _commitUser(User u) {
    if (!mounted) return;
    setState(() => _user = u);
    widget.onUserUpdated?.call(u);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            _Header(onBack: widget.onBack ?? () => Navigator.maybePop(context)),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _EditProfileSection(
                      user: _user,
                      name: _name,
                      handle: _handle,
                      bio: _bio,
                      nameError: _nameError,
                      handleError: _handleError,
                      bioError: _bioError,
                      onSaveName: _saveName,
                      onSaveHandle: _saveHandle,
                      onSaveBio: _saveBio,
                      onBioChanged: () => setState(() {}),
                    ),
                    _AccountSection(
                      email: widget.email,
                      onLogout: widget.onLogout,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onBack});
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.line)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back',
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back, color: AppColors.ink2),
          ),
          const SizedBox(width: 4),
          const Text(
            'Settings',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: AppColors.ink1,
            ),
          ),
        ],
      ),
    );
  }
}

class _EditProfileSection extends StatelessWidget {
  const _EditProfileSection({
    required this.user,
    required this.name,
    required this.handle,
    required this.bio,
    required this.nameError,
    required this.handleError,
    required this.bioError,
    required this.onSaveName,
    required this.onSaveHandle,
    required this.onSaveBio,
    required this.onBioChanged,
  });

  final User user;
  final TextEditingController name;
  final TextEditingController handle;
  final TextEditingController bio;
  final String? nameError;
  final String? handleError;
  final String? bioError;
  final VoidCallback onSaveName;
  final VoidCallback onSaveHandle;
  final VoidCallback onSaveBio;
  final VoidCallback onBioChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.line)),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _Avatar(
                displayName: user.displayName.isNotEmpty ? user.displayName : user.handle,
                colorHex: user.avatarColor,
                size: 80,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.displayName.isNotEmpty ? user.displayName : '@${user.handle}',
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
                      '@${user.handle}',
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
              ),
            ],
          ),
          const SizedBox(height: 24),
          _Field(
            label: 'Display name',
            controller: name,
            maxLength: 40,
            onSave: onSaveName,
            error: nameError,
          ),
          const SizedBox(height: 16),
          _Field(
            label: 'Handle',
            controller: handle,
            prefix: '@',
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[a-z0-9_]')),
              LengthLimitingTextInputFormatter(20),
            ],
            onSave: onSaveHandle,
            error: handleError,
          ),
          const SizedBox(height: 16),
          _BioField(
            controller: bio,
            error: bioError,
            onSave: onSaveBio,
            onChanged: onBioChanged,
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    required this.onSave,
    this.prefix,
    this.maxLength,
    this.inputFormatters,
    this.error,
  });

  final String label;
  final TextEditingController controller;
  final VoidCallback onSave;
  final String? prefix;
  final int? maxLength;
  final List<TextInputFormatter>? inputFormatters;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            fontFamily: 'Consolas',
            color: AppColors.ink3,
          ),
        ),
        const SizedBox(height: 8),
        Focus(
          onFocusChange: (hasFocus) {
            if (!hasFocus) onSave();
          },
          child: TextField(
            controller: controller,
            maxLength: maxLength,
            inputFormatters: inputFormatters,
            decoration: InputDecoration(
              prefixText: prefix,
              prefixStyle: const TextStyle(
                color: AppColors.ink3,
                fontSize: 13,
                fontFamily: 'Consolas',
              ),
              counterText: '',
              isDense: true,
            ),
            style: const TextStyle(color: AppColors.ink1, fontSize: 14),
            onSubmitted: (_) => onSave(),
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 4),
          Text(
            error!,
            style: const TextStyle(
              fontSize: 11,
              fontFamily: 'Consolas',
              color: AppColors.err,
            ),
          ),
        ],
      ],
    );
  }
}

class _BioField extends StatelessWidget {
  const _BioField({
    required this.controller,
    required this.onSave,
    required this.onChanged,
    this.error,
  });

  final TextEditingController controller;
  final VoidCallback onSave;
  final VoidCallback onChanged;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Bio',
          style: TextStyle(
            fontSize: 11,
            fontFamily: 'Consolas',
            color: AppColors.ink3,
          ),
        ),
        const SizedBox(height: 8),
        Focus(
          onFocusChange: (hasFocus) {
            if (!hasFocus) onSave();
          },
          child: TextField(
            controller: controller,
            maxLength: 256,
            maxLines: 3,
            minLines: 3,
            onChanged: (_) => onChanged(),
            decoration: const InputDecoration(
              hintText: 'A few words about yourself',
              counterText: '',
              isDense: true,
            ),
            style: const TextStyle(color: AppColors.ink1, fontSize: 14),
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 4),
          Text(
            error!,
            style: const TextStyle(
              fontSize: 11,
              fontFamily: 'Consolas',
              color: AppColors.err,
            ),
          ),
        ],
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            '${controller.text.length}/256',
            style: const TextStyle(
              fontSize: 10,
              fontFamily: 'Consolas',
              color: AppColors.ink3,
            ),
          ),
        ),
      ],
    );
  }
}

class _AccountSection extends StatelessWidget {
  const _AccountSection({required this.email, required this.onLogout});
  final String email;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'ACCOUNT',
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'Consolas',
              letterSpacing: 1.2,
              color: AppColors.ink3,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            height: 44,
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.line),
              borderRadius: BorderRadius.circular(AppRadii.rMd),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                const Icon(Icons.mail_outline, color: AppColors.ink3, size: 18),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    email,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.ink1,
                      fontFamily: 'Consolas',
                    ),
                  ),
                ),
                const Text(
                  'verified',
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'Consolas',
                    color: AppColors.ink3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          InkWell(
            onTap: onLogout,
            borderRadius: BorderRadius.circular(AppRadii.rMd),
            child: Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.centerLeft,
              child: Row(
                children: const [
                  Icon(Icons.logout, color: AppColors.err, size: 20),
                  SizedBox(width: 16),
                  Text(
                    'Log out',
                    style: TextStyle(
                      fontSize: 14,
                      color: AppColors.err,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
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

String _msg(Object e, String fallback) {
  if (e is ConnectError) return e.message.isNotEmpty ? e.message : fallback;
  final s = e.toString();
  return s.isEmpty ? fallback : s;
}
