// System tray integration. Behaviour mirrors Telegram Desktop:
//   - X (close) on the window hides instead of exiting (handled by main.dart's
//     WindowListener). The WS connection and call subscription stay alive so
//     incoming calls still raise toasts / surface the OS focus.
//   - Left click on the tray icon restores + focuses the window.
//   - Right click opens a context menu with Open / Quit entries.
//
// The Windows runner already ships an `app_icon.ico` under
// `windows/runner/resources/`; tray_manager accepts both .ico (Windows) and
// .png assets so we point at the runner icon directly without bundling a copy.

import 'package:tray_manager/tray_manager.dart';

class TrayService with TrayListener {
  TrayService._();
  static final TrayService instance = TrayService._();

  bool _inited = false;
  void Function()? _onOpen;
  void Function()? _onQuit;

  Future<void> init({
    required void Function() onOpen,
    required void Function() onQuit,
    String? subtitle,
  }) async {
    _onOpen = onOpen;
    _onQuit = onQuit;
    if (!_inited) {
      trayManager.addListener(this);
      _inited = true;
    }
    // The Flutter Windows scaffold places app_icon.ico at this path. It is the
    // same icon Visual Studio bakes into the .exe — keeps the tray icon
    // visually consistent with the window icon and the taskbar entry.
    await trayManager.setIcon('windows/runner/resources/app_icon.ico');
    await _refreshTooltip(subtitle);
    await _rebuildMenu();
  }

  Future<void> updateTooltip(String text) async {
    if (!_inited) return;
    await trayManager.setToolTip(text);
  }

  Future<void> _refreshTooltip(String? subtitle) async {
    final tip = (subtitle == null || subtitle.isEmpty)
        ? 'Quick'
        : 'Quick — $subtitle';
    await trayManager.setToolTip(tip);
  }

  Future<void> _rebuildMenu() async {
    final menu = Menu(items: [
      MenuItem(key: 'open', label: 'Open Quick'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit Quick'),
    ]);
    await trayManager.setContextMenu(menu);
  }

  Future<void> dispose() async {
    if (!_inited) return;
    trayManager.removeListener(this);
    try {
      await trayManager.destroy();
    } catch (_) {/* ignore */}
    _inited = false;
  }

  // ---- TrayListener ----

  @override
  void onTrayIconMouseDown() {
    // Left click — restore the window.
    _onOpen?.call();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayIconRightMouseUp() {/* noop */}

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open':
        _onOpen?.call();
        break;
      case 'quit':
        _onQuit?.call();
        break;
    }
  }
}
