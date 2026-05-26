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

## 6. Voice playback Content-Type quirk

`GET /v1/media/voice/{file_id}?token=...` serves the recorded blob. On the
web client, the `<audio>` element relies on the server's `Content-Type`
header to pick a decoder, and there is a known production case where the
header is missing or set to `application/octet-stream`, leaving the browser
unable to play it. On Windows, `just_audio` decodes through Media Foundation
which sniffs the container instead and tolerates a missing header, so the
desktop client typically plays voice blobs that fail in browsers.

If a voice blob still refuses to play, the bubble surfaces an inline
"Couldn't play" pill (red, MM:SS-adjacent) driven by an `errorMessageId`
field on `VoicePlayerState`. The pill is the user-visible signal that the
load/decode failed; the underlying error is forwarded onto
`AudioPlayer.playbackEventStream`'s error channel.

## tdata local store

A Telegram-style on-disk encrypted cache backs the in-memory `ChatsController`
so the sidebar and the active thread paint instantly on launch and stay usable
when the network drops.

### DB location

`<app-support>/quick/tdata.db` where `<app-support>` is whatever
`path_provider.getApplicationSupportDirectory()` returns. On Windows that
resolves to `%APPDATA%\com.racasspixel\quick\quick` in practice. Two sidecar
files (`tdata.db-wal`, `tdata.db-shm`) ride alongside in WAL mode. Cached
voice/image blobs live in `<app-support>/quick/media/`.

### Schema version

`kSchemaVersion = 1` (see `lib/store/schema.dart`). All tables created in one
DDL pass:

- `users(id PK, handle, display_name, avatar_color, presence_seen_at, enc_blob)`
- `chats(id PK, kind, last_message_at, last_message_id, unread_count, pinned_at, enc_blob)`
- `chat_members(chat_id, user_id, role, joined_at, PRIMARY KEY(chat_id, user_id))`
- `messages(id PK, chat_id, sender_id, created_at, kind, status, enc_body, enc_attachments)` + INDEX `(chat_id, created_at DESC)`
- `media_cache(file_id PK, local_path, mime, size_bytes, cached_at)`
- `outbox(local_id PK, chat_id, payload_json, created_at, attempt_count, last_error)` + INDEX `(chat_id, created_at ASC)`

Future schema changes bump `kSchemaVersion` and add a branch to
`migrate(db, fromVersion, toVersion)` in `schema.dart`. On a corrupt-file
open, the DB is renamed `tdata.db.corrupt-<ms>` and a fresh one is created —
the next sync rebuilds it from the server.

### How to wipe (debugging)

```dart
import 'package:quick_desktop/store/local_store.dart';
await LocalStore.wipe();
```

`wipe` closes the handle, deletes the DB file plus its WAL/SHM/journal
sidecars. Equivalent to the on-disk effect of signing out. Or delete
`tdata.db*` under `<app-support>/quick/` by hand.

### How the encryption key is derived

`lib/store/crypto.dart#StoreCrypto.fromSessionToken(sessionToken)`:

1. Take the session token bytes (UTF-8) as input key material.
2. Run HKDF-SHA256 with the constant 32-byte pepper
   `quick.tdata.v1.pepper.do-not-change-without-bumping-schema` as salt and
   `quick.tdata.aes-gcm` as info to derive a 32-byte AES-256 key.
3. Each row's `enc_*` column is `nonce(12) || ciphertext || mac(16)` from
   `AesGcm.with256bits()`. A fresh nonce per row.

Switching accounts produces a different session token, so the derived key
differs and old rows fail to decrypt. The `onVerified` path defensively wipes
before opening to avoid leaving orphaned rows on disk.

The E2E crypto agent's `lib/crypto/` does not exist at the time of writing.
When it lands, swap `StoreCrypto.fromSessionToken` to call into the shared
primitives — the on-disk blob format is stable and won't need a schema bump
as long as nonce+ciphertext+mac stays at 12+N+16.

### Sync algorithm (local-first + delta from server)

Boot:
1. `AuthController.bootstrap()` reads the persisted session token.
2. `LocalStore.boot(token)` opens the DB and derives the crypto key.
3. `ChatsController` constructor kicks `_hydrateFromStore()` which reads the
   `chats` table and seeds `state.byId` — sidebar paints from disk.
4. `loadConversations()` then calls `ListConversations` and overwrites
   `state.byId` + persists the fresh list (write-through). Network failure
   leaves the disk-hydrated state in place.

Per-thread:
1. `loadMessages(convId)` first reads the latest 50 messages from
   `messages_dao.listLatest(convId)` and surfaces them via `state.messages`.
2. It then calls `ListMessages` with `afterId = <newest cached message id>`
   (when available) so the server only sends the gap since last sync.
3. Returned rows are merged, deduped on id, and persisted.
4. WS `message` envelopes write through to disk immediately
   (`applyMessage` → `messages.upsert`).

On logout the secure-storage token is cleared AND `LocalStore.wipe()` deletes
the DB so the next sign-in starts fresh.

## Attachments + replies + reactions + forward + search (v0.1.7)

Wire shape between client and backend (proto v0.14.0):

- Outgoing rich send: `Messaging.SendMessage` accepts `body`, optional
  `replyToMessageId`, and `attachmentFileIds[]` collected from the inline
  upload queue (`lib/features/messaging/attachments/upload_state.dart`).
- Uploads: `POST /v1/media/upload` (multipart, single `file` field) via
  `MediaUploader.uploadPath`. Returns `{ file_id, kind, mime, size, ... }`.
- Reactions: `Messaging.AddReaction { messageId, emoji }` /
  `RemoveReaction` / `ListReactions`. WS envelopes `reaction_added` and
  `reaction_removed` carry `message_id`, `user_id`, `emoji` and are merged
  into `Message.reactions` by `ChatsController._applyReaction`.
- Forward: `Messaging.ForwardMessage { sourceMessageId, targetConversationId }`.
  The returned `Message.forwardOriginText` is rendered above the bubble body.
- Search: `Messaging.SearchMessages { query, conversationId?, limit, beforeId? }`
  drives both the global sidebar search section and the in-pane magnifier.

E2E posture for attachments: **deferred**. The current `sendRich` path sends
the body in plaintext when attachments are present (TODO marker in
`chats_controller.dart`). The encrypted path in `send()` stays the
authoritative route for text-only DMs. A follow-up will:

1. Seal attachment file_ids alongside the body under the conversation key.
2. Encrypt the uploaded media bytes client-side before the multipart POST
   (the backend already stores ciphertext at rest for voice; the same shape
   applies here).
3. Migrate `forwardMessage` so forwards re-seal under the target
   conversation's key.

Until those land, image / file bubbles fetch via the existing
`GET /v1/media/{file_id}?token=...` (token-authenticated, server-side
encrypted at rest).
