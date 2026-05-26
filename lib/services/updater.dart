import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// Tagged union of possible updater states. Plain sealed class hierarchy keeps
/// us free of code-gen (freezed) and the analyzer can still exhaustively switch.
sealed class UpdateState {
  const UpdateState();
}

class UpdateIdle extends UpdateState {
  const UpdateIdle();
}

class UpdateChecking extends UpdateState {
  const UpdateChecking();
}

class UpdateAvailable extends UpdateState {
  final String currentVersion;
  final String newVersion;
  final Uri downloadUrl;
  final int sizeBytes;
  const UpdateAvailable({
    required this.currentVersion,
    required this.newVersion,
    required this.downloadUrl,
    required this.sizeBytes,
  });
}

class UpdateDownloading extends UpdateState {
  final String newVersion;
  // Range 0..1. Null when total size is unknown.
  final double? progress;
  const UpdateDownloading({required this.newVersion, required this.progress});
}

class UpdateReady extends UpdateState {
  final String newVersion;
  final String installerPath;
  const UpdateReady({required this.newVersion, required this.installerPath});
}

class UpdateError extends UpdateState {
  final String message;
  const UpdateError(this.message);
}

/// Polls a GitHub Releases endpoint for a newer build, downloads the installer
/// when the user opts in, then hands off to it. Designed to be constructed once
/// at app boot and shared via Riverpod / inherited widget.
class UpdaterService {
  // Hardcoded by design: ship a single canonical update channel. If we ever
  // need a beta channel we'll add a second service rather than parameterise.
  static const String _releaseApi =
      'https://api.github.com/repos/racass-pixel/quick-desktop/releases/latest';
  static const Duration _pollInterval = Duration(minutes: 30);

  final http.Client _http;
  final _controller = StreamController<UpdateState>.broadcast();
  Timer? _timer;
  UpdateState _last = const UpdateIdle();
  bool _busy = false;

  UpdaterService({http.Client? client}) : _http = client ?? http.Client();

  Stream<UpdateState> get state => _controller.stream;
  UpdateState get current => _last;

  void _emit(UpdateState s) {
    _last = s;
    if (!_controller.isClosed) _controller.add(s);
  }

  /// Kicks off an immediate check and schedules subsequent ones every 30 min.
  void startPeriodicCheck() {
    _timer?.cancel();
    // Fire-and-forget the boot check; the timer takes over from there.
    unawaited(checkNow());
    _timer = Timer.periodic(_pollInterval, (_) => unawaited(checkNow()));
  }

  Future<void> checkNow() async {
    // Once an update has been surfaced (downloading / ready), polling must not
    // overwrite that state — the user has already engaged with it.
    if (_busy) return;
    if (_last is UpdateDownloading || _last is UpdateReady) return;

    _emit(const UpdateChecking());
    try {
      final res = await _http.get(
        Uri.parse(_releaseApi),
        headers: const {'Accept': 'application/vnd.github+json'},
      );
      if (res.statusCode == 404) {
        // No releases published yet — silently return to idle, do not alarm.
        _emit(const UpdateIdle());
        return;
      }
      if (res.statusCode != 200) {
        _emit(UpdateError('GitHub returned ${res.statusCode}'));
        return;
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final tag = (body['tag_name'] as String?)?.trim() ?? '';
      final latest = _stripV(tag);
      if (latest.isEmpty) {
        _emit(const UpdateIdle());
        return;
      }
      final info = await PackageInfo.fromPlatform();
      final currentVersion = info.version;
      if (_compareSemver(latest, currentVersion) <= 0) {
        _emit(const UpdateIdle());
        return;
      }
      final assets = (body['assets'] as List?) ?? const [];
      final asset = assets
          .cast<Map<String, dynamic>>()
          .firstWhere(
            (a) {
              final name = (a['name'] as String?) ?? '';
              return name.endsWith('-windows-x64.exe');
            },
            orElse: () => <String, dynamic>{},
          );
      if (asset.isEmpty) {
        _emit(const UpdateError('No Windows installer in latest release'));
        return;
      }
      _emit(UpdateAvailable(
        currentVersion: currentVersion,
        newVersion: latest,
        downloadUrl: Uri.parse(asset['browser_download_url'] as String),
        sizeBytes: (asset['size'] as num?)?.toInt() ?? 0,
      ));
    } catch (e) {
      _emit(UpdateError(e.toString()));
    }
  }

  Future<void> startDownload() async {
    final s = _last;
    if (s is! UpdateAvailable) return;
    if (_busy) return;
    _busy = true;
    try {
      _emit(UpdateDownloading(newVersion: s.newVersion, progress: 0.0));
      final dir = await getTemporaryDirectory();
      final outPath =
          '${dir.path}${Platform.pathSeparator}quick-desktop-update-v${s.newVersion}.exe';
      final out = File(outPath);
      if (await out.exists()) await out.delete();

      final req = http.Request('GET', s.downloadUrl);
      final resp = await _http.send(req);
      if (resp.statusCode != 200) {
        _emit(UpdateError('Download failed: HTTP ${resp.statusCode}'));
        return;
      }
      final total = resp.contentLength;
      final sink = out.openWrite();
      int received = 0;
      // Throttle UI emits to ~25 per download — the banner only needs coarse
      // progress and a per-chunk emit storm jitters the progress bar.
      double lastEmitted = -1;
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total != null && total > 0) {
          final p = received / total;
          if (p - lastEmitted >= 0.04 || p >= 1.0) {
            lastEmitted = p;
            _emit(UpdateDownloading(newVersion: s.newVersion, progress: p));
          }
        } else {
          _emit(UpdateDownloading(newVersion: s.newVersion, progress: null));
        }
      }
      await sink.flush();
      await sink.close();
      _emit(UpdateReady(newVersion: s.newVersion, installerPath: outPath));
    } catch (e) {
      _emit(UpdateError(e.toString()));
    } finally {
      _busy = false;
    }
  }

  /// Spawns the installer detached so Inno Setup can close+rewrite our exe,
  /// then exits the current process so the file lock is released.
  Future<void> launchAndQuit() async {
    final s = _last;
    if (s is! UpdateReady) return;
    await Process.start(
      s.installerPath,
      const ['/SILENT', '/CLOSEAPPLICATIONS', '/RESTARTAPPLICATIONS'],
      mode: ProcessStartMode.detached,
      runInShell: false,
    );
    // Give the installer a beat to grab the lock before we relinquish ours.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    exit(0);
  }

  /// User-initiated retry after a failure — re-enters the check flow.
  Future<void> retry() async {
    _busy = false;
    _emit(const UpdateIdle());
    await checkNow();
  }

  void dispose() {
    _timer?.cancel();
    _http.close();
    _controller.close();
  }

  static String _stripV(String tag) =>
      tag.startsWith('v') || tag.startsWith('V') ? tag.substring(1) : tag;

  /// Returns >0 if a>b, <0 if a<b, 0 if equal. Compares dot-separated numeric
  /// components only; pre-release suffixes are not part of our release scheme.
  static int _compareSemver(String a, String b) {
    final pa = a.split('-').first.split('.').map(int.tryParse).toList();
    final pb = b.split('-').first.split('.').map(int.tryParse).toList();
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final ai = i < pa.length ? (pa[i] ?? 0) : 0;
      final bi = i < pb.length ? (pb[i] ?? 0) : 0;
      if (ai != bi) return ai - bi;
    }
    return 0;
  }
}
