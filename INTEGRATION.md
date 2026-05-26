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

# Settings + Profile + Groups

Three feature surfaces live under `lib/features/settings/` and
`lib/features/groups/` and ship pre-wired against the existing
`ConnectClient` (`lib/api/connect.dart`) + `User`/`Conversation` DTOs
(`lib/api/dto.dart`). They take callbacks for navigation and side-effects so
the foundation owns routing + state ownership.

## API wrappers

```dart
import 'features/settings/api/users_api.dart';
import 'features/groups/api/groups_api.dart';

final usersApi  = SettingsUsersApi(connect);
final groupsApi = GroupsApi(connect);
```

These duplicate part of `lib/api/services.dart#UsersApi`; reconciliation will
fold the two together once the foundation API surface stabilises.

## Sidebar drawer (hamburger)

The chats sidebar header (foundation-owned) gates a hamburger button that
toggles `SidebarDrawer` over the chat list:

```dart
import 'features/settings/widgets/sidebar_drawer.dart';

Widget buildSidebarDrawer({required User me, required VoidCallback onLogout}) {
  return SidebarDrawer(
    open: _drawerOpen,
    me: me,
    onClose: () => setState(() => _drawerOpen = false),
    onProfile: () {
      setState(() => _drawerOpen = false);
      showProfileModal(context, me, usersApi: usersApi, isSelf: true);
    },
    onNewGroup: () {
      setState(() => _drawerOpen = false);
      showCreateGroupDialog(
        context,
        groupsApi: groupsApi,
        usersApi: usersApi,
        onCreated: (id) => context.go('/chats/$id'),
      );
    },
    onNewChannel: () {
      setState(() => _drawerOpen = false);
      showCreateChannelDialog(
        context,
        groupsApi: groupsApi,
        onCreated: (id) => context.go('/chats/$id'),
      );
    },
    onSettings: () {
      setState(() => _drawerOpen = false);
      context.go('/settings');
    },
    onLogout: onLogout,
  );
}
```

Drop the returned widget into a `Stack` above the chat list so the slide
animation overlays it. ESC dismisses; tapping the backdrop dismisses.

## Settings route

```dart
import 'package:go_router/go_router.dart';
import 'features/settings/screens/settings_screen.dart';

GoRoute(
  path: '/settings',
  builder: (c, s) => SettingsScreen(
    me: ref.read(meProvider),
    email: ref.read(authProvider).email,
    usersApi: usersApi,
    onUserUpdated: (u) => ref.read(meProvider.notifier).set(u),
    onLogout: () => ref.read(authProvider.notifier).logout(),
    onBack: () => context.go('/chats'),
  ),
);
```

Fields save on blur. Validation errors surface inline; backend errors
(`handle_taken`, etc.) surface in the same slot via `ConnectError.message`.

## Profile modal

Open on any avatar click — sidebar row, thread header, group attribution,
members modal, "My Profile" in the drawer:

```dart
import 'features/settings/widgets/profile_modal.dart';

showProfileModal(
  context,
  user,
  usersApi: usersApi,
  isSelf: user.id == me.id,
  presence: ref.watch(presenceProvider(user.id)),
  onMessage: (u) async {
    final conv = await messagingApi.openDM(u.id);
    context.go('/chats/${conv.id}');
  },
  onCall: (u) => ref.read(callProvider.notifier).start(u, video: false),
  onBlocked: () => ref.read(chatsProvider.notifier).removeByPeer(user.id),
);
```

Self-mode hides Message/Call/Block. The `More` menu always offers `Copy
handle`; for non-self it also exposes `Block user`.

## Create-group / create-channel dialogs

```dart
showCreateGroupDialog(
  context,
  groupsApi: groupsApi,
  usersApi: usersApi,
  onCreated: (conversationId) => context.go('/chats/$conversationId'),
);

showCreateChannelDialog(
  context,
  groupsApi: groupsApi,
  onCreated: (conversationId) => context.go('/chats/$conversationId'),
);
```

The group dialog is two-step (name → optional members). The channel dialog is
single-step (name + `@handle`). The channel handle is encoded into the title
as `Name (@handle)` until a dedicated `handle` column ships server-side.

# Voice messages

The voice feature ships as four self-contained pieces inside
`lib/features/voice/`:

- `api/voice_api.dart` — `VoiceApi` (REST upload + Connect-RPC send/markPlayed)
- `state/voice_recorder.dart` — `VoiceRecorder` (hold-to-record, peak bucketing)
- `state/voice_player.dart` — `VoicePlayerNotifier` (shared single-slot player)
- `widgets/voice_recorder_button.dart` — `VoiceRecorderButton` (composer slot)
- `widgets/voice_bubble.dart` — `VoiceBubble` (message-list slot)

Nothing in `lib/features/voice/` imports from `lib/main.dart`, `lib/state/`,
or other feature directories — it relies only on `lib/api/connect.dart`,
`lib/api/dto.dart` (for `Message`) and `lib/theme/theme.dart`. Integration is
purely additive.

## 1. Construct + share at boot

In `main.dart`, after the existing `ConnectClient` and `SessionStore` are
ready, instantiate the voice API and the shared player exactly once:

```dart
import 'features/voice/api/voice_api.dart';
import 'features/voice/state/voice_player.dart';

final voiceApi = VoiceApi(connect, baseUrl: connect.baseUrl);
final voicePlayer = VoicePlayerNotifier();

// Or via Riverpod (recommended — matches the rest of `lib/state/`):
final voiceApiProvider = Provider<VoiceApi>((ref) {
  final c = ref.watch(connectClientProvider);
  return VoiceApi(c, baseUrl: c.baseUrl);
});
final voicePlayerProvider = ChangeNotifierProvider<VoicePlayerNotifier>((ref) {
  final p = VoicePlayerNotifier();
  ref.onDispose(p.dispose);
  return p;
});
```

The player owns a single `just_audio` `AudioPlayer` — playing one bubble
stops any other, matching Telegram. Hand the same instance to every
`VoiceBubble`.

## 2. Slot the recorder into the composer

When the composer's text input is empty AND `conversationId` is non-null,
render `VoiceRecorderButton` on the right edge in place of the send arrow:

```dart
import 'features/voice/widgets/voice_recorder_button.dart';

VoiceRecorderButton(
  api: voiceApi,
  conversationId: currentConversationId,
  token: session.token!, // for the playback URL we hand back optimistically
  enabled: !disabled,
  onLocalVoiceMessage: (payload) {
    // Optimistic insert — payload.messageId is 'tmp:<fileId>'. Add a
    // Message stub with status: pending so the bubble appears instantly.
    chatsController.appendOptimisticVoice(conversationId, payload);
  },
  onSent: (result) {
    // Replace the optimistic stub (matched by payload.fileId) with the
    // real Message id and createdAt from the server.
    chatsController.replaceOptimisticVoice(
      conversationId,
      result.payload.fileId,
      result.serverMessageId,
      result.serverCreatedAt,
    );
  },
  onError: (msg) {
    // 3-second inline error pill in the composer.
    composerErrorController.show(msg);
  },
)
```

The button morphs into a recording bar (timer + slide-to-cancel hint) while
held. Recordings < 800ms are dropped silently (TG-style).

## 3. Slot the bubble into the message list

When `message.voice != null`, render `VoiceBubble` inside the message-list
renderer:

```dart
import 'features/voice/widgets/voice_bubble.dart';

VoiceBubble(
  voice: VoicePayload(
    fileId: message.voice!.fileId,
    url: voiceApi.buildPlaybackUrl(message.voice!.fileId, session.token!),
    durationMs: message.voice!.durationMs,
    peaks: message.voice!.peaks,
    played: message.voice!.played,
    messageId: message.id,
  ),
  isOwn: message.senderId == me.id,
  player: voicePlayer,
  onFirstPlay: () {
    // Receiver only — debounce per-id in the messaging layer so a
    // re-render mid-play doesn't double-fire.
    if (!firedOnce.add(message.id)) return;
    voiceApi.markPlayed(message.id);
  },
)
```

The `Message` DTO in `lib/api/dto.dart` does not yet carry a `voice` field —
foundation will need to extend it (and the corresponding `ListMessages`
response shape) once the backend wire format is finalised.

## 4. WS `voice_played` envelope

When the WS realtime channel receives a `voice_played` envelope, the
messaging layer should flip the matching `Message.voice.played` to `true`
and notify listeners. The bubble re-renders on its own once the underlying
`VoicePayload.played` flips — no extra wiring needed inside this feature.

## 5. Windows-specific notes

- **Microphone permission**: Windows shows the permission dialog the first
  time `record` opens an input device. Pre-prompt via
  `permission_handler`'s `Permission.microphone.request()` from a settings
  screen if you want to avoid surprising the user inside the composer. The
  recorder also calls `hasPermission()` internally and throws
  `VoicePermissionDeniedException` on denial — the button surfaces this as
  `"Microphone access denied"` through `onError`.
- **Codec**: `record_windows` uses Windows Media Foundation, which exposes
  AAC-LC / FLAC / WAV / PCM — **no opus**. The recorder writes m4a
  (AAC-LC, 64kbps mono 32kHz) instead. The backend's `/v1/media/voice`
  endpoint accepts m4a alongside opus (it re-encodes via ffmpeg when a
  downstream client needs a different container).
- **Temp files**: recordings land in
  `<temp>/quick_voice/rec_<microsTimestamp>.m4a`. The recorder deletes the
  file after a successful upload, but the OS reaps the dir on its own
  schedule if a crash leaves orphans.

# Calls

Voice / video / screen-share for 1:1 and group conversations. Lives entirely
inside `lib/features/calls/` and depends on:

- `lib/api/connect.dart` — `ConnectClient` for the 9 `quick.v1.Calls` RPCs
- `lib/api/realtime.dart` — `Stream<WsEnvelope>` for the 8 call envelopes
- `lib/theme/theme.dart` — colors and radii

LiveKit URL is read from `CallJoin.livekitUrl` returned by the backend; falls
back to `wss://livekit.quick-network.vu` if the field is empty.

## 1. Construct + share at boot

After the foundation's `ConnectClient` + `RealtimeClient` are ready, wire two
notifiers and the WS bridge:

```dart
import 'features/calls/api/calls_api.dart';
import 'features/calls/state/call_state.dart';
import 'features/calls/state/group_call_state.dart';
import 'features/calls/state/calls_realtime.dart';

final callsApi = CallsApi(connect);
final callNotifier = CallNotifier(callsApi);
final groupCallNotifier = GroupCallNotifier(callsApi);
final callsWsSub = wireCallsRealtime(
  realtime.envelopes,
  callNotifier,
  groupCallNotifier,
);
// On sign-out: callsWsSub.cancel(); callNotifier.dispose(); groupCallNotifier.dispose();
```

Riverpod variants (recommended — matches `lib/state/providers.dart`):

```dart
final callsApiProvider = Provider<CallsApi>((ref) =>
    CallsApi(ref.read(connectClientProvider)));

final callNotifierProvider = ChangeNotifierProvider<CallNotifier>((ref) {
  final n = CallNotifier(ref.read(callsApiProvider));
  ref.onDispose(n.dispose);
  return n;
});

final groupCallNotifierProvider =
    ChangeNotifierProvider<GroupCallNotifier>((ref) {
  final n = GroupCallNotifier(ref.read(callsApiProvider));
  ref.onDispose(n.dispose);
  return n;
});

final callsWsBridgeProvider = Provider<StreamSubscription<Map<String, dynamic>>>((ref) {
  final sub = wireCallsRealtime(
    ref.read(realtimeProvider).envelopes,
    ref.read(callNotifierProvider),
    ref.read(groupCallNotifierProvider),
  );
  ref.onDispose(sub.cancel);
  return sub;
});
```

## 2. Mount `CallScreen` over the main shell

When either notifier is in an active lifecycle and NOT minimized, the full
`CallScreen` should occupy the window. Wrap your `MaterialApp.router` builder:

```dart
import 'features/calls/screens/call_screen.dart';
import 'features/calls/widgets/call_pip.dart';
import 'features/calls/widgets/incoming_call_dialog.dart';

MaterialApp.router(
  builder: (context, child) {
    return Stack(
      children: [
        child ?? const SizedBox.shrink(),
        // Full-screen takeover when active + not minimized.
        AnimatedBuilder(
          animation: Listenable.merge([callNotifier, groupCallNotifier]),
          builder: (_, _) {
            final inCall = callNotifier.lifecycle == CallLifecycle.active ||
                callNotifier.lifecycle == CallLifecycle.ringingOut;
            final inGroup =
                groupCallNotifier.lifecycle == GroupCallLifecycle.active;
            final minimized = (inCall && callNotifier.isMinimized) ||
                (inGroup && groupCallNotifier.isMinimized);
            if ((inCall || inGroup) && !minimized) {
              return CallScreen(
                call: callNotifier,
                group: groupCallNotifier,
              );
            }
            return const SizedBox.shrink();
          },
        ),
        // Floating pip — visible whenever an active call is minimized.
        CallPip(call: callNotifier, group: groupCallNotifier),
        // Incoming dialog — auto-dismisses on accept/decline/timeout.
        IncomingCallOverlay(call: callNotifier),
      ],
    );
  },
);
```

## 3. Start a 1:1 call

From a profile modal or chat header:

```dart
callNotifier.startCall(
  CallPeer(
    id: user.id,
    displayName: user.displayName,
    handle: user.handle,
    avatarColor: user.avatarColor,
  ),
  video: false, // or true for a video call
);
```

The notifier handles the entire lifecycle: ringing-out → active → end.

## 4. Mount the group-call banner in conversation views

At the top of every group/channel conversation:

```dart
import 'features/calls/screens/group_call_banner.dart';

GroupCallBanner(
  conversationId: conversation.id,
  group: groupCallNotifier,
)
```

The banner returns `SizedBox.shrink()` when no group call is active in that
conversation and we're not in one — zero layout cost. To start a group call
from the chat header:

```dart
groupCallNotifier.startGroupCall(conversation.id);
```

To preload banner state when the chats list loads:

```dart
groupCallNotifier.refreshActive(conversations.map((c) => c.id).toList());
```

## 5. Screen-share + anti-echo (Windows gotcha)

The feature calls `setScreenShareEnabled(true, captureScreenAudio: true)`
which on Windows routes through `flutter-webrtc`'s `getDisplayMedia` and
honors the system-audio checkbox in the Windows desktop-capture picker.

The web app's `suppressLocalAudioPlayback` anti-echo trick has no direct
analog in `livekit_client` on Windows. Workarounds:

1. Share a single application window rather than the entire screen.
2. Route the app's audio output to a virtual cable that the screen-share
   capture does NOT include.

The `startScreenShare()` methods carry a `TODO(calls-anti-echo)` and a
desktop-source-picker UI is the right follow-up once a single agent owns the
calls UX end-to-end.
