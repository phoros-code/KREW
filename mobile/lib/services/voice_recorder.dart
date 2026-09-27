import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

/// Phone mic capture seam (Track B4).
///
/// The UI drives [VoiceRecorder], never `AudioRecorder` directly, so widget
/// tests inject fakes without microphone hardware. Production is
/// [RecordVoiceRecorder] (wav, 16kHz mono — STT-sized, well under the 5MB
/// server cap for a 30s take).
abstract class VoiceRecorder {
  /// Start capturing to [path]. Throws on mic failure.
  Future<void> start(String path);

  /// Stop and return the recorded file path (null when nothing recorded).
  Future<String?> stop();

  /// Discard the take. Never throws.
  Future<void> cancel();

  /// Release native resources.
  Future<void> dispose();

  /// Live amplitude ticks (dBFS) feeding the DESIGN.md listening meter —
  /// real recorder levels, never synthetic.
  Stream<Amplitude> amplitudeTicks(Duration interval);
}

/// Production recorder: wav @16kHz mono via the `record` plugin.
class RecordVoiceRecorder implements VoiceRecorder {
  RecordVoiceRecorder({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  /// STT capture config: wav container, 16kHz mono. A full 30s take is
  /// ~1MB — comfortably under the 5MB voice cap.
  static const RecordConfig voiceConfig = RecordConfig(
    encoder: AudioEncoder.wav,
    sampleRate: 16000,
    numChannels: 1,
  );

  @override
  Future<void> start(String path) =>
      _recorder.start(voiceConfig, path: path);

  @override
  Future<String?> stop() => _recorder.stop();

  @override
  Future<void> cancel() => _recorder.cancel();

  @override
  Future<void> dispose() => _recorder.dispose();

  @override
  Stream<Amplitude> amplitudeTicks(Duration interval) =>
      _recorder.onAmplitudeChanged(interval);
}

/// Injectable mic-permission gate (Track B4): production requests the OS
/// microphone permission; tests inject `() async => true/false` so no test
/// ever touches the permission channel.
typedef MicPermissionGate = Future<bool> Function();

/// Production gate — granted only (microphone has no "limited" state).
/// A channel failure means "do not record" (false), never a crash.
Future<bool> requestMicPermission() async {
  try {
    final PermissionStatus status = await Permission.microphone.request();
    return status.isGranted;
  } catch (_) {
    return false;
  }
}
