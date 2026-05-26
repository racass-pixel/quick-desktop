// Connect-RPC over JSON transport for the prod backend.
//
// Wire format: POST {baseUrl}/{service}/{method} with JSON body. Headers include
// Connect-Protocol-Version: 1 and an optional Bearer token. Responses are JSON;
// non-2xx bodies carry a Connect error envelope `{ code, message }`.
//
// We use the same camelCase field names the proto3 JSON mapping produces — the
// backend (Go connect-go with JSON codec) accepts and returns exactly that.

import 'dart:convert';

import 'package:http/http.dart' as http;

class ConnectError implements Exception {
  ConnectError(this.httpStatus, this.code, this.message, this.retryAfterUnix);

  final int httpStatus;
  // Connect canonical error code string, e.g. 'unauthenticated', 'invalid_argument'.
  final String code;
  final String message;
  // Server hint from the trailer (S10.5 rate-limit). 0 if absent.
  final int retryAfterUnix;

  @override
  String toString() => 'ConnectError($httpStatus $code): $message';
}

class ConnectClient {
  ConnectClient(this.baseUrl, {http.Client? client})
      : _http = client ?? http.Client();

  final String baseUrl;
  final http.Client _http;
  String? _token;

  String? get token => _token;
  void setToken(String? t) {
    _token = (t != null && t.isNotEmpty) ? t : null;
  }

  Future<Map<String, dynamic>> call(
    String service,
    String method,
    Map<String, dynamic> body,
  ) async {
    final uri = Uri.parse('$baseUrl/$service/$method');
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Connect-Protocol-Version': '1',
      if (_token != null) 'Authorization': 'Bearer $_token',
    };
    final res = await _http.post(uri, headers: headers, body: jsonEncode(body));
    final text = res.body;
    if (res.statusCode >= 200 && res.statusCode < 300) {
      if (text.isEmpty) return const <String, dynamic>{};
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      return <String, dynamic>{'result': decoded};
    }
    // Try to parse a Connect error envelope.
    String code = 'unknown';
    String msg = text;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        code = (decoded['code'] as String?) ?? code;
        msg = (decoded['message'] as String?) ?? msg;
      }
    } catch (_) {
      // body wasn't JSON — keep raw text as the message.
    }
    final retryHeader = res.headers['retry-after-unix'] ?? '';
    final retry = int.tryParse(retryHeader) ?? 0;
    throw ConnectError(res.statusCode, code, msg, retry);
  }
}
