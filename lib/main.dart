import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'router.dart';
import 'state/providers.dart';
import 'theme/theme.dart';

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
    );
  }
}
