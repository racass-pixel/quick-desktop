// Hold-to-record glue around the `record` package.
//
// Why a wrapper: the composer's hold-to-record UX needs a few extras the
// stock `AudioRecorder` doesn't bake in:
//   * Live amplitude level (0..1) for the pulsing mic glow during recording.
//   * 64-bucket peak waveform suitable for the receiver's VoiceBubble.
//   * Wall-clock duration captured at start/stop so we don't depend on the
//     decoded media duration (small recordings often have ragged tails).
//
// Codec choice on Windows: `record_windows` doesn't expose opus — it routes
// through Media Foundation which gives us aacLc / aacEld / aacHe / amrNb /
// amrWb / flac / pcm16bits / wav. We pick **aacLc** at 64kbps mono 32kHz —
// small enough for voice messages (~8 KB/s) and supported natively by every
// HTML5 audio stack the backend's proxy might re-stream to. The backend
// accepts whatever container we upload (see api/voice.ts in quick-web; the
// server re-encodes with ffmpeg if a downstream client needs a different mime).
//
// Peaks: the `record` package's `onAmplitudeChanged` stream emits dBFS values
// at the requested interval. We sample at 50ms (so ~20Hz) and bucket the
// samples into 64 bins by averaging when the stream produces more samples
// than buckets, or by stretching the captured run when it produces fewer.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:path_provider/path_provider.dart' as path_provider;
import 'package:record/record.dart';

const int kVoicePeakBuckets = 64;

class VoiceRecordingResult {
  VoiceRecordingResult({
    required this.file,
    required this.durationMs,
    required this.peaks,
  });

  final File file;
  final int durationMs;
  final List<int> peaks; // 64 values, 0..255
}

// Live state exposed to the composer while recording.
class VoiceRecorderTick {
  const VoiceRecorderTick({required this.elapsedMs, required this.level});
  final int elapsedMs;
  final double level; // 0..1, derived from rolling dBFS
}

// Translates a Record-package dBFS value (current amplitude) to a 0..1 level.
// dBFS is typically in the range [-160, 0]; speech sits around -45..-10.
// We clamp to [-60, 0] and lerp so the UI level is responsive but doesn't
// flicker on background noise.
double _dbfsToLevel(double dbfs) {
  if (!dbfs.isFinite) return 0;
  if (dbfs <= -60) return 0;
  if (dbfs >= 0) return 1;
  return (dbfs + 60) / 60;
}

// Compute path_provider-based temp file path for the next recording. Each
// recording gets a unique name so a re-record while an upload is in flight
// can't overwrite the bytes mid-read.
Future<String> _nextRecordingPath() async {
  final dir = await path_provider.getTemporaryDirectory();
  final ts = DateTime.now().microsecondsSinceEpoch;
  final voiceDir = Directory('${dir.path}/quick_voice');
  if (!await voiceDir.exists()) {
    await voiceDir.create(recursive: true);
  }
  return '${voiceDir.path}/rec_$ts.m4a';
}

class VoiceRecorder {
  VoiceRecorder() : _recorder = AudioRecorder();

  final AudioRecorder _recorder;
  final List<double> _levelSamples = <double>[];
  final StreamController<VoiceRecorderTick> _ticks =
      StreamController<VoiceRecorderTick>.broadcast();
  StreamSubscription<Amplitude>? _ampSub;
  Timer? _tickTimer;
  DateTime? _startedAt;
  String? _outPath;
  double _lastLevel = 0;
  bool _disposed = false;

  Stream<VoiceRecorderTick> get ticks => _ticks.stream;

  Future<bool> hasPermission() => _recorder.hasPermission();

  // Begin a new recording. Throws if the OS denies mic permission or no
  // input device is available — the composer surfaces those as an inline
  // error pill.
  Future<void> start() async {
    if (_disposed) {
      throw StateError('VoiceRecorder used after dispose');
    }
    final granted = await _recorder.hasPermission();
    if (!granted) {
      throw const VoicePermissionDeniedException();
    }
    _levelSamples.clear();
    _outPath = await _nextRecordingPath();
    const config = RecordConfig(
      // aacLc → m4a container. See file header for the Windows rationale.
      encoder: AudioEncoder.aacLc,
      bitRate: 64000,
      sampleRate: 32000,
      numChannels: 1,
      autoGain: true,
      echoCancel: true,
      noiseSuppress: true,
    );
    await _recorder.start(config, path: _outPath!);
    _startedAt = DateTime.now();

    // 50ms amplitude polling → ~20 samples/sec; we average into the 64 peak
    // buckets at stop time. The same callback updates the live-level value
    // the composer reads off `ticks`.
    _ampSub = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 50))
        .listen((amp) {
      final level = _dbfsToLevel(amp.current);
      _lastLevel = level;
      _levelSamples.add(level);
    });

    // A separate 60ms ticker drives the UI even when amplitude callbacks are
    // sparse (the platform sometimes coalesces them). We compute elapsedMs
    // from wall-clock so a paused recording doesn't drift.
    _tickTimer = Timer.periodic(const Duration(milliseconds: 60), (_) {
      final start = _startedAt;
      if (start == null || _ticks.isClosed) return;
      _ticks.add(VoiceRecorderTick(
        elapsedMs: DateTime.now().difference(start).inMilliseconds,
        level: _lastLevel,
      ));
    });
  }

  // Stop recording and return the captured artefact. Throws StateError if
  // start() wasn't called first.
  Future<VoiceRecordingResult> stop() async {
    final start = _startedAt;
    final outPath = _outPath;
    if (start == null || outPath == null) {
      throw StateError('VoiceRecorder.stop called before start');
    }
    _tickTimer?.cancel();
    _tickTimer = null;
    await _ampSub?.cancel();
    _ampSub = null;
    // The recorder returns the same path we passed in; we keep the platform
    // return value as the source of truth so file:// translations on macOS
    // don't bite us if we ever ship there.
    final returned = await _recorder.stop();
    final file = File(returned ?? outPath);
    final durationMs = DateTime.now().difference(start).inMilliseconds;
    final peaks = _bucketPeaks(_levelSamples);
    _startedAt = null;
    _outPath = null;
    return VoiceRecordingResult(
      file: file,
      durationMs: durationMs,
      peaks: peaks,
    );
  }

  // Stop and discard. Used by slide-to-cancel and by the composer's cleanup
  // path. Best-effort delete of the temp file — we don't want a stuck file
  // lock to mask the real cancel intent.
  Future<void> cancel() async {
    _tickTimer?.cancel();
    _tickTimer = null;
    await _ampSub?.cancel();
    _ampSub = null;
    try {
      await _recorder.cancel();
    } catch (_) {
      // already stopped or never started — fine.
    }
    final outPath = _outPath;
    if (outPath != null) {
      try {
        final f = File(outPath);
        if (await f.exists()) await f.delete();
      } catch (_) {
        // ignore — temp dir gets cleaned up by the OS anyway
      }
    }
    _startedAt = null;
    _outPath = null;
  }

  Future<void> dispose() async {
    _disposed = true;
    _tickTimer?.cancel();
    await _ampSub?.cancel();
    await _ticks.close();
    await _recorder.dispose();
  }
}

// Convert the captured level samples (one entry per amplitude callback, in
// [0, 1]) into 64 ints in [0, 255], normalised so the loudest bucket sits at
// 255. This matches the web's encoding so receivers render an identical
// waveform whether the message was sent from web or desktop.
List<int> _bucketPeaks(List<double> samples) {
  final out = List<int>.filled(kVoicePeakBuckets, 0);
  if (samples.isEmpty) return out;

  // Choose per-bucket aggregation: for a 4-second recording sampled at 20Hz
  // we have ~80 samples → ~1.25 per bucket; for 30 seconds, ~600 samples →
  // ~9 per bucket. In both cases we take the bucket's PEAK (matches the web
  // computePeaks() pass), not the mean, so transients survive.
  final n = samples.length;
  final perBucket = n / kVoicePeakBuckets;
  double globalMax = 0;
  final raw = List<double>.filled(kVoicePeakBuckets, 0);
  for (var b = 0; b < kVoicePeakBuckets; b++) {
    final start = (b * perBucket).floor();
    final end = b == kVoicePeakBuckets - 1
        ? n
        : ((b + 1) * perBucket).ceil();
    if (start >= n) {
      raw[b] = 0;
      continue;
    }
    var peak = 0.0;
    for (var i = start; i < end && i < n; i++) {
      final v = samples[i];
      if (v > peak) peak = v;
    }
    raw[b] = peak;
    if (peak > globalMax) globalMax = peak;
  }

  if (globalMax <= 0) return out;
  final scale = 255 / globalMax;
  for (var i = 0; i < kVoicePeakBuckets; i++) {
    final v = (raw[i] * scale).round();
    out[i] = math.max(0, math.min(255, v));
  }
  return out;
}

class VoicePermissionDeniedException implements Exception {
  const VoicePermissionDeniedException();
  @override
  String toString() => 'Microphone permission denied';
}
