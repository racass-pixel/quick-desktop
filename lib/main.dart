import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'features/calls/screens/call_screen.dart';
import 'features/calls/state/call_state.dart';
import 'features/calls/state/group_call_state.dart';
import 'features/calls/widgets/call_pip.dart';
import 'features/calls/widgets/incoming_call_dialog.dart';
import 'router.dart';
import 'state/providers.dart';
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

class _QuickAppState extends ConsumerState<QuickApp> {
  @override
  void initState() {
    super.initState();
    // Kick off the session bootstrap. The router watches the resulting state
    // and redirects to /login or the main shell once we know.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(authControllerProvider.notifier).bootstrap();
      // Touch the updater provider so the polling loop spins up.
      ref.read(updaterServiceProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
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
