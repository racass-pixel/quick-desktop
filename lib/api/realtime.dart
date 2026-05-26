// Realtime WebSocket client.
//
// Connects to wss://<api-host>/ws?token=<session>. Auto-reconnects with
// exponential backoff. Parses incoming JSON envelopes and exposes a broadcast
// Stream<WsEnvelope> the rest of the app subscribes to. Each envelope has a
// `kind` discriminator + arbitrary additional fields (see quick-web's ws.ts).

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

typedef WsEnvelope = Map<String, dynamic>;

enum WsStatus { idle, connecting, open, closed }

class RealtimeClient {
  RealtimeClient({required this.baseHttpUrl});

  // Use the same base URL as Connect-RPC; we rewrite scheme http→ws / https→wss.
  final String baseHttpUrl;

  final _envelopes = StreamController<WsEnvelope>.broadcast();
  Stream<WsEnvelope> get envelopes => _envelopes.stream;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _pingTimer;
  Timer? _reconnectTimer;

  String? _token;
  WsStatus _status = WsStatus.idle;
  int _retryAttempt = 0;
  bool _intentionallyClosed = false;

  WsStatus get status => _status;

  void connect(String token) {
    if (token.isEmpty) {
      disconnect();
      return;
    }
    if (_token == token &&
        (_status == WsStatus.open || _status == WsStatus.connecting)) {
      return;
    }
    _intentionallyClosed = false;
    _token = token;
    _openSocket();
  }

  void disconnect() {
    _intentionallyClosed = true;
    _cancelReconnect();
    _pingTimer?.cancel();
    _pingTimer = null;
    _token = null;
    _retryAttempt = 0;
    _sub?.cancel();
    _sub = null;
    try {
      _channel?.sink.close(ws_status.normalClosure, 'client disconnect');
    } catch (_) {/* ignore */}
    _channel = null;
    _status = WsStatus.idle;
  }

  bool send(WsEnvelope env) {
    final ch = _channel;
    if (ch == null || _status != WsStatus.open) return false;
    try {
      ch.sink.add(jsonEncode(env));
      return true;
    } catch (_) {
      return false;
    }
  }

  void _openSocket() {
    final tok = _token;
    if (tok == null) return;
    _status = WsStatus.connecting;
    final wsBase = baseHttpUrl.replaceFirst(RegExp(r'^http'), 'ws');
    final uri = Uri.parse('$wsBase/ws?token=${Uri.encodeQueryComponent(tok)}');
    WebSocketChannel ch;
    try {
      ch = WebSocketChannel.connect(uri);
    } catch (_) {
      _scheduleReconnect();
      return;
    }
    _channel = ch;
    _sub = ch.stream.listen(
      _onData,
      onError: (_) {/* close will follow */},
      onDone: _onClose,
      cancelOnError: false,
    );
    // Lightweight keepalive — the backend pings too but a client-side ping
    // every ~25s keeps NATs and intermediate proxies from idling us out.
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      send({'kind': 'ping'});
    });
    // We assume the socket is "open" once the channel exists; web_socket_channel
    // doesn't surface a dedicated open event, but the first successful add or
    // first inbound message confirms it. Flip to open optimistically.
    _status = WsStatus.open;
    _retryAttempt = 0;
  }

  void _onData(dynamic raw) {
    if (raw is! String) return;
    Map<String, dynamic>? env;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) env = decoded;
    } catch (_) {
      return;
    }
    if (env == null) return;
    final kind = env['kind'];
    if (kind is! String) return;
    _envelopes.add(env);
  }

  void _onClose() {
    _status = WsStatus.closed;
    _pingTimer?.cancel();
    _pingTimer = null;
    _sub?.cancel();
    _sub = null;
    _channel = null;
    if (!_intentionallyClosed) _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _cancelReconnect();
    if (_intentionallyClosed || _token == null) return;
    final attempt = _retryAttempt++;
    final baseMs = min(500 * (1 << attempt), 30000);
    final jitter = (baseMs * 0.25 * (Random().nextDouble() * 2 - 1)).toInt();
    final delayMs = max(250, baseMs + jitter);
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), _openSocket);
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  Future<void> dispose() async {
    disconnect();
    await _envelopes.close();
  }
}
