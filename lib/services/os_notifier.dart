// Windows OS-level toast notifications. Sits next to the in-app Toaster: the
// in-app stack handles the "user is looking at the app right now" case, this
// service handles "user has minimised Quick to the tray and is doing something
// else". The notifications_bridge picks one path or the other based on window
// focus, except for incoming calls which fire both (the call is urgent enough
// that we want the OS toast to surface even while the window is visible).
//
// Implementation uses `local_notifier`, which on Windows shells out to the
// WinRT ToastNotification APIs (so we get real Action Center entries, native
// styling, and the OS notification sound). The package requires a Start Menu
// shortcut bound to an AppUserModelID — `shortcutPolicy: requireCreate` makes
// it create one in `%APPDATA%\Microsoft\Windows\Start Menu\Programs` pointing
// at the running .exe on first run. Installed copies already get a shortcut
// from the Inno Setup `[Icons]` section, so that path keeps the installer-
// created Start Menu entry as-is.
//
// Activation flow:
//   - User clicks the toast body              -> NotificationActivation(action: 'open')
//   - User clicks an action button            -> NotificationActivation(action: <button key>)
// Subscribers (main.dart -> bridge) decide what to do with it; this service
// stays oblivious to routing and call-state so it can be unit-tested without
// the full app graph.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:local_notifier/local_notifier.dart';

enum NotificationKind { message, incomingCall, groupCall }

@immutable
class NotificationActivation {
  const NotificationActivation({
    required this.kind,
    required this.action,
    required this.data,
  });

  final NotificationKind kind;

  /// One of: 'open' (toast body click), or a kind-specific button key like
  /// 'accept' / 'decline' / 'join'.
  final String action;

  /// Free-form payload the bridge attached when calling [OsNotifier.show].
  /// Typically holds `conversationId`, `callId`, etc.
  final Map<String, String> data;
}

class OsNotifier {
  OsNotifier._();
  static final OsNotifier instance = OsNotifier._();

  final StreamController<NotificationActivation> _activations =
      StreamController<NotificationActivation>.broadcast();

  /// Live notifications keyed by our caller-supplied id (or generated id).
  /// We keep refs so we can [dismiss] and also so the listener callbacks on
  /// each [LocalNotification] aren't GCed while the toast is on screen.
  final Map<String, _LiveNotification> _live = {};

  bool _inited = false;

  Stream<NotificationActivation> get activations => _activations.stream;

  Future<void> init({required String appId}) async {
    if (_inited) return;
    if (!Platform.isWindows) {
      // On non-Windows we currently no-op. Keeping the API symmetric lets the
      // bridge stay platform-agnostic; future macOS/Linux work can plug in
      // here without touching callers.
      _inited = true;
      return;
    }
    try {
      await localNotifier.setup(
        // local_notifier uses this both as the displayed app name and as the
        // AppUserModelID hash key, so it MUST be stable across releases — the
        // appId arg from main.dart is the source of truth.
        appName: appId,
        shortcutPolicy: ShortcutPolicy.requireCreate,
      );
      _inited = true;
    } catch (e) {
      // Setup can fail on locked-down systems (no write access to the Start
      // Menu folder). We swallow so the app keeps booting; toasts just won't
      // appear. The in-app Toaster still works.
      debugPrint('OsNotifier.init failed: $e');
    }
  }

  /// Fires a Windows toast. Safe to call before [init] completes — it just
  /// no-ops in that case.
  ///
  /// `id` lets the caller dedupe / dismiss later (e.g. cancel a sticky
  /// incoming-call toast when the call ends). If omitted, a fresh id is
  /// generated each time.
  Future<void> show({
    required String title,
    required String body,
    String? id,
    String? subtitle,
    NotificationKind kind = NotificationKind.message,
    Map<String, String> data = const {},
  }) async {
    if (!_inited || !Platform.isWindows) return;

    // Reuse the caller's id as the local_notifier identifier so dismiss() can
    // find the right notification. Fall back to a deterministic counter when
    // missing — local_notifier would otherwise allocate a uuid internally.
    final notificationId = id ?? 'os:${DateTime.now().microsecondsSinceEpoch}';

    // Replace an existing toast with the same id (e.g. a refreshed
    // incoming-call toast). Without this, two toasts could stack in the
    // Action Center for the same logical event.
    final existing = _live.remove(notificationId);
    if (existing != null) {
      try {
        await existing.notification.destroy();
      } catch (_) {/* best effort */}
    }

    final actions = _actionsFor(kind);

    // Incoming calls should ring with sound; message toasts use the default
    // Windows messaging sound (silent=false). local_notifier doesn't expose
    // a sticky/long-duration flag, so the bridge dismisses the call toast
    // explicitly when the call state resolves.
    final notification = LocalNotification(
      identifier: notificationId,
      title: title,
      subtitle: subtitle,
      body: body,
      silent: false,
      actions: actions.isEmpty ? null : actions,
    );

    final live = _LiveNotification(
      notification: notification,
      kind: kind,
      data: Map<String, String>.unmodifiable(data),
      actionKeys: actions.map((a) => a.text ?? '').toList(),
    );
    _live[notificationId] = live;

    notification.onClick = () {
      _emit(live, 'open');
    };
    notification.onClickAction = (int index) {
      final key = _keyForAction(live, index);
      _emit(live, key);
    };
    notification.onClose = (_) {
      // Drop the ref so the map doesn't grow unbounded; the listener is
      // detached by LocalNotifier internals.
      _live.remove(notificationId);
    };

    try {
      await notification.show();
    } catch (e) {
      debugPrint('OsNotifier.show failed: $e');
      _live.remove(notificationId);
    }
  }

  /// Dismisses a previously-shown toast by id. Safe to call for unknown ids.
  Future<void> dismiss(String id) async {
    final live = _live.remove(id);
    if (live == null) return;
    try {
      await live.notification.destroy();
    } catch (_) {/* ignore */}
  }

  List<LocalNotificationAction> _actionsFor(NotificationKind kind) {
    switch (kind) {
      case NotificationKind.message:
        return const [];
      case NotificationKind.incomingCall:
        return [
          LocalNotificationAction(text: 'Accept'),
          LocalNotificationAction(text: 'Decline'),
        ];
      case NotificationKind.groupCall:
        return [
          LocalNotificationAction(text: 'Join'),
        ];
    }
  }

  String _keyForAction(_LiveNotification live, int index) {
    // Map index back to a stable action key (lowercased label). We can't rely
    // on the index alone because the bridge speaks in semantic actions.
    if (index < 0 || index >= live.actionKeys.length) return 'unknown';
    return live.actionKeys[index].toLowerCase();
  }

  void _emit(_LiveNotification live, String action) {
    if (_activations.isClosed) return;
    _activations.add(NotificationActivation(
      kind: live.kind,
      action: action,
      data: live.data,
    ));
  }

  Future<void> dispose() async {
    for (final live in _live.values.toList()) {
      try {
        await live.notification.destroy();
      } catch (_) {/* ignore */}
    }
    _live.clear();
    await _activations.close();
  }
}

class _LiveNotification {
  _LiveNotification({
    required this.notification,
    required this.kind,
    required this.data,
    required this.actionKeys,
  });

  final LocalNotification notification;
  final NotificationKind kind;
  final Map<String, String> data;
  final List<String> actionKeys;
}
