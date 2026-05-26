// Root Riverpod providers. Holds the long-lived singletons (ConnectClient,
// service wrappers, realtime), session bootstrap state, and the chats store.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/connect.dart';
import '../api/dto.dart';
import '../api/realtime.dart';
import '../api/services.dart';
import '../api/session_store.dart';
import '../features/calls/api/calls_api.dart';
import '../features/calls/state/call_state.dart';
import '../features/calls/state/calls_realtime.dart';
import '../features/calls/state/group_call_state.dart';
import '../features/groups/api/groups_api.dart';
import '../features/settings/api/users_api.dart';
import '../features/voice/api/voice_api.dart';
import '../features/voice/state/voice_player.dart';
import '../services/updater.dart';
import 'chats_controller.dart';

const apiBaseUrl = 'https://api.quick-network.vu';

final sessionStoreProvider = Provider<SessionStore>((_) => SessionStore());

final connectClientProvider = Provider<ConnectClient>((_) {
  return ConnectClient(apiBaseUrl);
});

final realtimeProvider = Provider<RealtimeClient>((ref) {
  final r = RealtimeClient(baseHttpUrl: apiBaseUrl);
  ref.onDispose(r.dispose);
  return r;
});

final authApiProvider = Provider<AuthApi>((ref) => AuthApi(ref.read(connectClientProvider)));
final usersApiProvider = Provider<UsersApi>((ref) => UsersApi(ref.read(connectClientProvider)));
final messagingApiProvider =
    Provider<MessagingApi>((ref) => MessagingApi(ref.read(connectClientProvider)));

// Boot states drive the redirect logic in the router.
enum BootState { booting, signedOut, signedIn }

class AuthState {
  AuthState({required this.boot, this.user});
  final BootState boot;
  final User? user;

  AuthState copyWith({BootState? boot, User? user}) =>
      AuthState(boot: boot ?? this.boot, user: user ?? this.user);
}

class AuthController extends StateNotifier<AuthState> {
  AuthController(this._ref) : super(AuthState(boot: BootState.booting));

  final Ref _ref;

  // Called once at app startup. Reads the persisted token, hits Users.Me to
  // verify it, then opens the realtime socket.
  Future<void> bootstrap() async {
    final store = _ref.read(sessionStoreProvider);
    final token = await store.readToken();
    if (token == null || token.isEmpty) {
      state = AuthState(boot: BootState.signedOut);
      return;
    }
    _ref.read(connectClientProvider).setToken(token);
    try {
      final me = await _ref.read(usersApiProvider).me();
      state = AuthState(boot: BootState.signedIn, user: me);
      _ref.read(realtimeProvider).connect(token);
      // Ensure the calls WS bridge is alive — first read instantiates it.
      _ref.read(callsWsBridgeProvider);
      // Eagerly hydrate the conversations list so the first paint isn't empty.
      // ignore: unawaited_futures, discarded_futures
      _ref.read(chatsControllerProvider.notifier).loadConversations();
    } on ConnectError catch (e) {
      if (e.httpStatus == 401 || e.code == 'unauthenticated') {
        await store.clear();
        _ref.read(connectClientProvider).setToken(null);
        state = AuthState(boot: BootState.signedOut);
      } else {
        // Network error or other transient — assume signed-in, let UI deal.
        state = AuthState(boot: BootState.signedIn);
      }
    } catch (_) {
      state = AuthState(boot: BootState.signedIn);
    }
  }

  Future<void> onVerified(String token, User user) async {
    await _ref.read(sessionStoreProvider).writeToken(token);
    _ref.read(connectClientProvider).setToken(token);
    state = AuthState(boot: BootState.signedIn, user: user);
    _ref.read(realtimeProvider).connect(token);
    _ref.read(callsWsBridgeProvider);
    // ignore: unawaited_futures, discarded_futures
    _ref.read(chatsControllerProvider.notifier).loadConversations();
  }

  Future<void> signOut() async {
    try {
      await _ref.read(authApiProvider).logout();
    } catch (_) {
      // best-effort
    }
    await _ref.read(sessionStoreProvider).clear();
    _ref.read(connectClientProvider).setToken(null);
    _ref.read(realtimeProvider).disconnect();
    state = AuthState(boot: BootState.signedOut);
  }
}

final authControllerProvider =
    StateNotifierProvider<AuthController, AuthState>((ref) => AuthController(ref));

// ---- Feature surfaces ------------------------------------------------------

// Settings/Profile/Groups use their own UsersApi wrapper layered on top of the
// foundation ConnectClient; keep both providers wired side by side.
final settingsUsersApiProvider = Provider<SettingsUsersApi>(
    (ref) => SettingsUsersApi(ref.read(connectClientProvider)));

final groupsApiProvider =
    Provider<GroupsApi>((ref) => GroupsApi(ref.read(connectClientProvider)));

// Voice
final voiceApiProvider = Provider<VoiceApi>((ref) {
  final c = ref.read(connectClientProvider);
  return VoiceApi(c, baseUrl: apiBaseUrl);
});

final voicePlayerProvider = ChangeNotifierProvider<VoicePlayerNotifier>((ref) {
  final p = VoicePlayerNotifier();
  ref.onDispose(p.dispose);
  return p;
});

// Calls
final callsApiProvider =
    Provider<CallsApi>((ref) => CallsApi(ref.read(connectClientProvider)));

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

// Bridges the realtime envelope stream into the call notifiers. The provider
// lifetime owns the StreamSubscription so it tears down on app dispose.
final callsWsBridgeProvider =
    Provider<StreamSubscription<CallsWsEnvelope>>((ref) {
  final sub = wireCallsRealtime(
    ref.read(realtimeProvider).envelopes,
    ref.read(callNotifierProvider),
    ref.read(groupCallNotifierProvider),
  );
  ref.onDispose(sub.cancel);
  return sub;
});

// Updater
final updaterServiceProvider = Provider<UpdaterService>((ref) {
  final svc = UpdaterService();
  ref.onDispose(svc.dispose);
  // startPeriodicCheck triggers an immediate first checkNow internally.
  svc.startPeriodicCheck();
  return svc;
});
