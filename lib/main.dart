import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'features/calls/screens/call_screen.dart';
import 'features/calls/state/call_state.dart';
import 'features/calls/state/group_call_state.dart';
import 'features/calls/widgets/call_pip.dart';
import 'features/calls/widgets/incoming_call_dialog.dart';
import 'router.dart';
import 'services/notifications_bridge.dart';
import 'services/tray.dart';
import 'state/providers.dart';
import 'state/window_focus.dart';
import 'theme/theme.dart';
import 'widgets/update_banner.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1280, 820),
      minimumSize: Size(960, 600),
      title: 'Quick',
      backgroundColor: Color(0xFF0F1014),
      titleBarStyle: TitleBarStyle.normal,
    ),
    () async {
      // Intercept the X button — the listener hides the window instead of
      // closing the process. See _AppWindowListener below.
      await windowManager.setPreventClose(true);
      await windowManager.show();
      await windowManager.focus();
    },
  );
  runApp(const ProviderScope(child: QuickApp()));
}

class QuickApp extends ConsumerStatefulWidget {
  const QuickApp({super.key});
  @override
  ConsumerState<QuickApp> createState() => _QuickAppState();
}

class _QuickAppState extends ConsumerState<QuickApp> with WindowListener {
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    // Kick off the session bootstrap. The router watches the resulting state
    // and redirects to /login or the main shell once we know.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      ref.read(authControllerProvider.notifier).bootstrap();
      // Touch the updater provider so the polling loop spins up.
      ref.read(updaterServiceProvider);
      // Spin up the WS → toasts bridge — first read instantiates it.
      ref.read(notificationsBridgeProvider);
      // Tray with bound callbacks. Open = show + focus, Quit = real exit.
      await TrayService.instance.init(
        onOpen: _restoreWindow,
        onQuit: _quitApp,
      );
      // Seed the focused flag from the current state.
      try {
        final focused = await windowManager.isFocused();
        ref.read(windowFocusedProvider.notifier).state = focused;
      } catch (_) {/* ignore */}
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _restoreWindow() async {
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {/* ignore */}
  }

  Future<void> _quitApp() async {
    // True exit pathway — invoked from the tray's "Quit Quick" entry.
    try {
      await TrayService.instance.dispose();
    } catch (_) {/* ignore */}
    try {
      ref.read(realtimeProvider).disconnect();
    } catch (_) {/* ignore */}
    try {
      await windowManager.setPreventClose(false);
    } catch (_) {/* ignore */}
    try {
      await windowManager.destroy();
    } catch (_) {/* ignore */}
    exit(0);
  }

  // ---- WindowListener ----

  @override
  void onWindowClose() async {
    // Telegram-style minimize-to-tray. The user gets the tray icon as the
    // affordance to re-open; background WS keeps ringing calls alive.
    try {
      await windowManager.hide();
    } catch (_) {/* ignore */}
  }

  @override
  void onWindowFocus() {
    if (!mounted) return;
    ref.read(windowFocusedProvider.notifier).state = true;
  }

  @override
  void onWindowBlur() {
    if (!mounted) return;
    ref.read(windowFocusedProvider.notifier).state = false;
  }

  @override
  Widget build(BuildContext context) {
    // Keep tooltip in sync with the logged-in handle.
    ref.listen(authControllerProvider, (prev, next) {
      final u = next.user;
      // ignore: discarded_futures
      TrayService.instance.updateTooltip(u == null ? 'Quick' : 'Quick — @${u.handle}');
    });
    final auth = ref.watch(authControllerProvider);
    if (auth.boot == BootState.booting) {
      return MaterialApp(
        theme: buildAppTheme(),
        debugShowCheckedModeBanner: false,
        home: const Scaffold(
          backgroundColor: AppColors.bg,
          body: Center(
            child: SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      );
    }
    final router = buildRouter(ref);
    return MaterialApp.router(
      title: 'Quick',
      theme: buildAppTheme(),
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      builder: (context, child) {
        final updater = ref.read(updaterServiceProvider);
        final call = ref.watch(callNotifierProvider);
        final group = ref.watch(groupCallNotifierProvider);
        final inCall = call.lifecycle == CallLifecycle.active ||
            call.lifecycle == CallLifecycle.ringingOut;
        final inGroup = group.lifecycle == GroupCallLifecycle.active;
        final minimized = (inCall && call.isMinimized) ||
            (inGroup && group.isMinimized);
        final showCallFullScreen = (inCall || inGroup) && !minimized;
        return Column(
          children: [
            UpdateBanner(service: updater),
            Expanded(
              child: Stack(
                children: [
                  child ?? const SizedBox.shrink(),
                  if (showCallFullScreen)
                    Positioned.fill(
                      child: CallScreen(call: call, group: group),
                    ),
                  // Floating pip when an active call is minimized.
                  CallPip(call: call, group: group),
                  // Incoming-call modal — visible only while ringing in.
                  IncomingCallOverlay(call: call),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

