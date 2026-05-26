# Updater integration

The auto-updater ships as two self-contained pieces:

- `lib/services/updater.dart` — `UpdaterService` (poll, download, hand-off)
- `lib/widgets/update_banner.dart` — `UpdateBanner` (40 px ember strip)

Neither imports anything from `lib/api/`, `lib/main.dart`, or `lib/theme/`, so
integration is purely additive.

## 1. Construct + start at boot

In `main.dart`, instantiate the service once after `WidgetsFlutterBinding.ensureInitialized()`
and start polling. Pass it down via Riverpod (preferred) or a top-level final.

```dart
import 'services/updater.dart';

final updater = UpdaterService();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // ... existing window_manager / hive / session boot ...
  updater.startPeriodicCheck();
  runApp(MyApp(updater: updater));
}
```

If/when a Riverpod provider is desired:

```dart
final updaterProvider = Provider<UpdaterService>((ref) {
  final svc = UpdaterService();
  ref.onDispose(svc.dispose);
  svc.startPeriodicCheck();
  return svc;
});
```

## 2. Mount the banner at the top of the app shell

The banner should sit above all routed content but below any custom window
chrome (drag region, traffic lights). Wrap your `MaterialApp.router` (or its
`builder`) with a `Column`:

```dart
import 'widgets/update_banner.dart';

MaterialApp.router(
  // ... existing config ...
  builder: (context, child) {
    return Column(
      children: [
        UpdateBanner(service: updater),
        Expanded(child: child ?? const SizedBox.shrink()),
      ],
    );
  },
);
```

The banner returns `SizedBox.shrink()` while idle/checking, so it costs zero
layout space when no update is pending.

## 3. Nothing else required

- No new permissions, no platform channels — `Process.start` + `dart:io` only.
- `package_info_plus` reads `pubspec.yaml`'s `version:` field on Windows via
  the bundled `.exe` resources (populated by the Inno Setup `AppVersion`).
- On `Restart to update`, the service spawns the installer detached, waits
  250 ms for the file lock, then `exit(0)`s the current process.
