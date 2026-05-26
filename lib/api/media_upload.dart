// Generic media upload client for `POST /v1/media/upload`.
//
// Uses a multipart request with a custom MultipartFile that streams the
// payload through a progress-reporting wrapper so the UI can render an
// upload bar. Backend caps: 50MB for images, 500MB for files.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'connect.dart';

class MediaUpload {
  const MediaUpload({
    required this.fileId,
    required this.kind,
    required this.mime,
    required this.size,
    this.filename = '',
    this.width = 0,
    this.height = 0,
    this.thumbnailUrl = '',
  });

  final String fileId;
  final String kind; // 'image' | 'file'
  final String mime;
  final int size;
  final String filename;
  final int width;
  final int height;
  final String thumbnailUrl;

  factory MediaUpload.fromJson(Map<String, dynamic> j) => MediaUpload(
        fileId: (j['fileId'] as String?) ?? (j['file_id'] as String?) ?? '',
        kind: (j['kind'] as String?) ?? 'file',
        mime: (j['mime'] as String?) ?? '',
        size: _i(j['size'] ?? j['sizeBytes'] ?? j['size_bytes'], 0),
        filename: (j['filename'] as String?) ?? (j['name'] as String?) ?? '',
        width: _i(j['width'], 0),
        height: _i(j['height'], 0),
        thumbnailUrl: (j['thumbnailUrl'] as String?) ??
            (j['thumbnail_url'] as String?) ??
            '',
      );
}

int _i(dynamic v, int d) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? d;
  return d;
}

class MediaUploader {
  MediaUploader({required this.baseUrl, required this.tokenProvider});
  final String baseUrl;
  final String? Function() tokenProvider;

  // Uploads a file with progress reporting. The `onProgress` callback receives
  // a fraction [0..1] as bytes are sent. Cancellation isn't wired through
  // dart:io HTTP here — callers track outstanding tasks separately if needed.
  Future<MediaUpload> uploadFile(
    File file, {
    void Function(double progress)? onProgress,
    String? filename,
  }) async {
    final bytes = await file.readAsBytes();
    final name = filename ?? file.uri.pathSegments.last;
    return uploadBytes(bytes, name: name, onProgress: onProgress);
  }

  Future<MediaUpload> uploadBytes(
    Uint8List bytes, {
    required String name,
    void Function(double progress)? onProgress,
  }) async {
    final uri = Uri.parse('$baseUrl/v1/media/upload');
    final tok = tokenProvider();
    final headers = <String, String>{
      if (tok != null && tok.isNotEmpty) 'Authorization': 'Bearer $tok',
    };

    final boundary =
        '----QuickDesktopBoundary${DateTime.now().microsecondsSinceEpoch}';
    final contentType = 'multipart/form-data; boundary=$boundary';

    // Build the multipart body by hand so we can stream byte-by-byte chunks
    // and emit progress. http.MultipartRequest doesn't expose progress out
    // of the box, so we hand-roll the encoding.
    final mime = _guessMime(name);
    final preamble = utf8.encode(
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="file"; filename="${_escape(name)}"\r\n'
      'Content-Type: $mime\r\n\r\n',
    );
    final epilogue = utf8.encode('\r\n--$boundary--\r\n');
    final totalLen = preamble.length + bytes.length + epilogue.length;

    final client = HttpClient();
    try {
      final req = await client.postUrl(uri);
      req.headers.set(HttpHeaders.contentTypeHeader, contentType);
      req.headers.contentLength = totalLen;
      headers.forEach(req.headers.set);

      // Stream in chunks with progress callbacks.
      const chunk = 64 * 1024;
      var sent = 0;
      req.add(preamble);
      sent += preamble.length;
      onProgress?.call(sent / totalLen);
      for (var i = 0; i < bytes.length; i += chunk) {
        final end = (i + chunk).clamp(0, bytes.length);
        req.add(bytes.sublist(i, end));
        sent += (end - i);
        onProgress?.call(sent / totalLen);
        // Yield so the UI can repaint between chunks on large files.
        await Future<void>.delayed(Duration.zero);
      }
      req.add(epilogue);
      onProgress?.call(1.0);

      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode < 200 || res.statusCode >= 300) {
        String code = 'unknown';
        String msg = body;
        try {
          final d = jsonDecode(body);
          if (d is Map<String, dynamic>) {
            code = (d['code'] as String?) ?? code;
            msg = (d['message'] as String?) ?? msg;
          }
        } catch (_) {}
        throw ConnectError(res.statusCode, code, msg, 0);
      }
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        // The backend wraps the result under `media` or `upload`; tolerate both
        // and a flat envelope.
        final inner = (decoded['media'] as Map?) ??
            (decoded['upload'] as Map?) ??
            decoded;
        return MediaUpload.fromJson(inner.cast<String, dynamic>());
      }
      throw ConnectError(res.statusCode, 'internal', 'bad upload response', 0);
    } finally {
      client.close();
    }
  }

  // Convenience overload for callers that hold a path string (e.g. file_picker
  // returns String paths on desktop).
  Future<MediaUpload> uploadPath(
    String path, {
    void Function(double progress)? onProgress,
    String? filename,
  }) {
    return uploadFile(File(path),
        onProgress: onProgress, filename: filename);
  }

  String _escape(String s) => s.replaceAll('"', '\\"').replaceAll('\n', ' ');

  String _guessMime(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.png')) return 'image/png';
    if (n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'image/jpeg';
    if (n.endsWith('.gif')) return 'image/gif';
    if (n.endsWith('.webp')) return 'image/webp';
    if (n.endsWith('.mp4')) return 'video/mp4';
    if (n.endsWith('.webm')) return 'video/webm';
    if (n.endsWith('.mp3')) return 'audio/mpeg';
    if (n.endsWith('.pdf')) return 'application/pdf';
    if (n.endsWith('.txt')) return 'text/plain';
    if (n.endsWith('.zip')) return 'application/zip';
    return 'application/octet-stream';
  }
}

// http.MultipartFile companion not used by MediaUploader above (we stream
// manually), but kept for callers that just want a quick non-progress upload
// path via the standard package:http transport.
Future<MediaUpload> simpleUpload({
  required String baseUrl,
  required String? token,
  required File file,
  String? filename,
}) async {
  final uri = Uri.parse('$baseUrl/v1/media/upload');
  final req = http.MultipartRequest('POST', uri);
  if (token != null && token.isNotEmpty) {
    req.headers['Authorization'] = 'Bearer $token';
  }
  final bytes = await file.readAsBytes();
  req.files.add(http.MultipartFile.fromBytes(
    'file',
    bytes,
    filename: filename ?? file.uri.pathSegments.last,
  ));
  final res = await http.Response.fromStream(await req.send());
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw ConnectError(res.statusCode, 'unknown', res.body, 0);
  }
  final decoded = jsonDecode(res.body) as Map<String, dynamic>;
  final inner = (decoded['media'] as Map?) ??
      (decoded['upload'] as Map?) ??
      decoded;
  return MediaUpload.fromJson(inner.cast<String, dynamic>());
}
