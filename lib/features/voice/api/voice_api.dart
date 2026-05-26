// Voice-messages API client.
//
// Voice attachments take a dedicated REST endpoint rather than going through
// Connect-RPC: the backend's connect-go transport isn't well-suited to
// streaming binary uploads. The flow is:
//
//   1. POST /v1/media/voice multipart  →  file_id
//   2. Messaging.SendVoiceMessage{conversationId, voiceFileId} → Message row
//   3. Backend broadcasts the new message over the WS realtime channel.
//
// Playback streams from GET /v1/media/voice/{file_id}?token=... — the token
// rides as a query string because the underlying audio player (just_audio on
// Windows, audio elements in the web client) can't attach an Authorization
// header to the media fetch.
//
// Foundation hasn't shipped its shared client base type yet; we depend on
// `ConnectClient` from `lib/api/connect.dart`. If the foundation reshuffles
// this we keep one import edit local to this file.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../api/connect.dart';
import '../../../api/dto.dart';

class VoiceApi {
  VoiceApi(
    this._connect, {
    required this.baseUrl,
    http.Client? client,
  }) : _http = client ?? http.Client();

  // The Connect base URL doubles as the REST base — backend mounts both under
  // the same origin. We accept it explicitly so callers can swap to a staging
  // host without reaching into the ConnectClient.
  final String baseUrl;
  final ConnectClient _connect;
  final http.Client _http;

  // Multipart upload of the recorded audio blob.
  //
  // Returns the server-assigned file id used by SendVoiceMessage. Throws
  // [VoiceUploadException] on non-2xx responses with the server detail when
  // present — callers should surface this as an inline composer error.
  Future<String> uploadVoice(
    File audioFile,
    int durationMs,
    List<int> peaks,
  ) async {
    final uri = Uri.parse('$baseUrl/v1/media/voice');
    final req = http.MultipartRequest('POST', uri);

    final token = _connect.token;
    if (token != null && token.isNotEmpty) {
      req.headers['Authorization'] = 'Bearer $token';
    }

    // The backend reads the container by file extension when it shells out to
    // ffmpeg for re-encoding, so we set a filename matching the actual bytes.
    // On Windows the `record` package writes m4a (AAC-LC) — see INTEGRATION.md
    // for the codec rationale.
    final lower = audioFile.path.toLowerCase();
    final String filename;
    if (lower.endsWith('.m4a')) {
      filename = 'voice.m4a';
    } else if (lower.endsWith('.webm')) {
      filename = 'voice.webm';
    } else if (lower.endsWith('.ogg')) {
      filename = 'voice.ogg';
    } else if (lower.endsWith('.wav')) {
      filename = 'voice.wav';
    } else {
      filename = 'voice.bin';
    }

    req.files.add(
      await http.MultipartFile.fromPath('file', audioFile.path, filename: filename),
    );
    req.fields['duration_ms'] = '${durationMs < 0 ? 0 : durationMs}';
    req.fields['peaks'] = jsonEncode(peaks);

    final streamed = await _http.send(req);
    final res = await http.Response.fromStream(streamed);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      String detail = res.body;
      try {
        final decoded = jsonDecode(res.body);
        if (decoded is Map<String, dynamic>) {
          detail = (decoded['message'] as String?) ?? detail;
        }
      } catch (_) {
        // body wasn't JSON; keep raw text
      }
      throw VoiceUploadException(res.statusCode, detail);
    }
    final body = jsonDecode(res.body);
    if (body is! Map<String, dynamic>) {
      throw VoiceUploadException(res.statusCode, 'unexpected upload response shape');
    }
    // Backend mirrors the proto field name `file_id` in REST; Connect-RPC
    // would camelCase it, but this endpoint hand-writes the JSON.
    final fileId = (body['file_id'] as String?) ?? (body['fileId'] as String?) ?? '';
    if (fileId.isEmpty) {
      throw VoiceUploadException(res.statusCode, 'missing file_id in upload response');
    }
    return fileId;
  }

  // Connect-RPC: write a message row referencing the uploaded blob. The
  // backend creates the Message + voice payload row and emits the realtime
  // envelope, so we just need the returned Message stub for optimistic UI.
  Future<Message> sendVoiceMessage(
    String conversationId,
    String voiceFileId,
  ) async {
    final res = await _connect.call('quick.v1.Messaging', 'SendVoiceMessage', {
      'conversationId': conversationId,
      'voiceFileId': voiceFileId,
    });
    return Message.fromJson(
      (res['message'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  // Mark a voice message as played by the receiver. Backend fires the
  // `voice_played` WS envelope so the sender's UI flips its bubble state.
  Future<void> markPlayed(String messageId) async {
    await _connect.call('quick.v1.Messaging', 'MarkVoicePlayed', {
      'messageId': messageId,
    });
  }

  // Build the playback URL with the session token in the query string.
  //
  // The audio player can't attach an Authorization header to media fetches
  // (this is a long-standing limitation in <audio>, mirrored by just_audio on
  // Windows which uses the same OS media stack). The backend's voice download
  // proxy accepts the same bearer via `?token=` for this reason.
  String buildPlaybackUrl(String fileId, String token) {
    final encoded = Uri.encodeQueryComponent(token);
    return '$baseUrl/v1/media/voice/$fileId?token=$encoded';
  }
}

class VoiceUploadException implements Exception {
  VoiceUploadException(this.httpStatus, this.message);

  final int httpStatus;
  final String message;

  @override
  String toString() => 'VoiceUploadException($httpStatus): $message';
}
