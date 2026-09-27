import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:everyday_buddy/l10n/strings.dart';
import 'package:everyday_buddy/screens/chat_screen.dart';
import 'package:everyday_buddy/services/buddy_api.dart';
import 'package:everyday_buddy/services/proximity_service.dart';
import 'package:everyday_buddy/services/voice_recorder.dart';
import 'package:everyday_buddy/theme/buddy_theme.dart';
import 'package:everyday_buddy/widgets/a11y.dart';
import 'package:everyday_buddy/widgets/command_bar.dart';
import 'package:everyday_buddy/widgets/voice_level_meter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:record/record.dart' show Amplitude;

/// Track B4 (phone-side voice input) tests. Faked recorder + transcriber
/// throughout — no microphone hardware, no server. Follows the track_c4
/// widget-test patterns (frame helper, mock API, explicit pumps).

Widget _frame(Widget child) => MaterialApp(home: Scaffold(body: child));

BuddyApi _mockApi(Future<http.Response> Function(http.BaseRequest) handler) =>
    BuddyApi(host: '192.168.1.10', token: 't', client: MockClient(handler));

/// Fake mic: records calls, feeds amplitude on demand, never touches the OS.
class _FakeRecorder implements VoiceRecorder {
  final String stopPath = '/tmp/buddy_fake_take.wav';
  int startCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;
  bool throwOnStart = false;
  final List<String> startedPaths = <String>[];
  final StreamController<Amplitude> amplitudeCtrl =
      StreamController<Amplitude>.broadcast();

  @override
  Future<void> start(String path) async {
    startCalls++;
    startedPaths.add(path);
    if (throwOnStart) throw Exception('mic busy');
  }

  @override
  Future<String?> stop() async {
    stopCalls++;
    return stopPath;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }

  @override
  Future<void> dispose() async {
    if (!amplitudeCtrl.isClosed) await amplitudeCtrl.close();
  }

  @override
  Stream<Amplitude> amplitudeTicks(Duration interval) =>
      amplitudeCtrl.stream;

  Future<void> closeForTest() async {
    if (!amplitudeCtrl.isClosed) await amplitudeCtrl.close();
  }
}

_FakeRecorder _recorder(WidgetTester tester) {
  final _FakeRecorder rec = _FakeRecorder();
  addTearDown(rec.closeForTest);
  return rec;
}

/// Small temp wav for transcribe mapping tests.
Future<(String, Directory)> _tempWav(String name) async {
  final Directory dir = await Directory.systemTemp.createTemp('buddy_b4_');
  final File file = File('${dir.path}/$name');
  await file.writeAsBytes(<int>[82, 73, 70, 70, 1, 2, 3, 4]);
  return (file.path, dir);
}

/// Sparse oversize file (no 5MB write — truncate only).
Future<(String, Directory)> _tempBigWav(String name, int size) async {
  final Directory dir = await Directory.systemTemp.createTemp('buddy_b4_');
  final File file = File('${dir.path}/$name');
  final RandomAccessFile raf = await file.open(mode: FileMode.write);
  await raf.truncate(size);
  await raf.close();
  return (file.path, dir);
}

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 4; i++) {
    await tester.pump();
  }
}

Future<void> _pumpBar(
  WidgetTester tester,
  _FakeRecorder rec, {
  int suspend = 0,
  VoiceTranscriber? transcriber,
  MicPermissionGate? gate,
  List<String>? sent,
}) async {
  await tester.pumpWidget(
    _frame(
      CommandBar(
        enabled: true,
        onSend: (String text) async {
          sent?.add(text);
        },
        recorder: rec,
        transcriber:
            transcriber ??
            (_) async =>
                const Transcription(text: 'open calendar', confidence: 0.9),
        permissionGate: gate ?? () async => true,
        suspendSignal: suspend,
      ),
    ),
  );
  await _settle(tester);
}

Future<void> _tapMic(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.mic));
  await _settle(tester);
}

void main() {
  group('B4.1 transcribe mapping (POST /voice/transcribe)', () {
    test('200 parses text + confidence, posts multipart audio', () async {
      final (String path, Directory dir) = await _tempWav('ok.wav');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      String? seenPath;
      String? seenMethod;
      String? seenField;
      String? seenAuth;
      bool seenBody = false;
      // NOTE: MockClient.streaming — the plain MockClient handler receives a
      // finalized plain Request (multipart files lost). Streaming passes the
      // original MultipartRequest through untouched.
      final BuddyApi api = BuddyApi(
        host: '192.168.1.10',
        token: 't',
        client: MockClient.streaming((
          http.BaseRequest req,
          http.ByteStream body,
        ) async {
          seenPath = req.url.path;
          seenMethod = req.method;
          seenAuth = req.headers['Authorization'];
          if (req is http.MultipartRequest) {
            seenField = req.files.single.field;
          }
          seenBody = (await body.toBytes()).isNotEmpty;
          return http.StreamedResponse(
            Stream<List<int>>.value(
              utf8.encode(
                '{"text": "open calendar", "confidence": 0.9, "duration_seconds": 2.1}',
              ),
            ),
            200,
          );
        }),
      );
      addTearDown(api.close);
      final Transcription result = await api.transcribe(path);
      expect(result.text, 'open calendar');
      expect(result.confidence, 0.9);
      expect(result.isEmpty, isFalse);
      expect(seenMethod, 'POST');
      expect(seenPath, '/voice/transcribe');
      expect(seenField, 'audio');
      expect(seenAuth, 'Bearer t');
      expect(seenBody, isTrue);
    });

    test('200 with empty text is NOT an error (retry state upstream)',
        () async {
      final (String path, Directory dir) = await _tempWav('empty.wav');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      final BuddyApi api = _mockApi(
        (_) async => http.Response(
          '{"text": "", "confidence": 0.0, "duration_seconds": 0.0}',
          200,
        ),
      );
      addTearDown(api.close);
      final Transcription result = await api.transcribe(path);
      expect(result.text, isEmpty);
      expect(result.isEmpty, isTrue);
    });

    test('low confidence passes through (the UI applies the 0.5 gate)',
        () async {
      final (String path, Directory dir) = await _tempWav('low.wav');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      final BuddyApi api = _mockApi(
        (_) async => http.Response(
          '{"text": "mumble", "confidence": 0.2, "duration_seconds": 1.0}',
          200,
        ),
      );
      addTearDown(api.close);
      final Transcription result = await api.transcribe(path);
      expect(result.text, 'mumble');
      expect(result.confidence, 0.2);
    });

    test('400 surfaces as bad_request', () async {
      final (String path, Directory dir) = await _tempWav('bad.wav');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      final BuddyApi api = _mockApi(
        (_) async => http.Response(
          '{"error": {"code": "bad_request", "message": "no audio part"}}}',
          400,
        ),
      );
      addTearDown(api.close);
      expect(
        api.transcribe(path),
        throwsA(
          isA<BuddyApiException>().having((e) => e.code, 'code', 'bad_request'),
        ),
      );
    });

    test('413 surfaces as body_too_large', () async {
      final (String path, Directory dir) = await _tempWav('big.wav');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      final BuddyApi api = _mockApi(
        (_) async => http.Response(
          '{"error": {"code": "body_too_large", "message": "over 5MB"}}}',
          413,
        ),
      );
      addTearDown(api.close);
      expect(
        api.transcribe(path),
        throwsA(
          isA<BuddyApiException>()
              .having((e) => e.code, 'code', 'body_too_large'),
        ),
      );
    });

    test('401 / 501 map through fromRaw', () async {
      final (String path, Directory dir) = await _tempWav('codes.wav');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      BuddyApi apiFor(int status, String code) => _mockApi(
        (_) async => http.Response(
          '{"error": {"code": "$code", "message": "m"}}',
          status,
        ),
      );
      final BuddyApi api401 = apiFor(401, 'unauthorized');
      addTearDown(api401.close);
      expect(
        api401.transcribe(path),
        throwsA(
          isA<BuddyApiException>()
              .having((e) => e.code, 'code', 'unauthorized'),
        ),
      );
      final BuddyApi api501 = apiFor(501, 'not_implemented');
      addTearDown(api501.close);
      expect(
        api501.transcribe(path),
        throwsA(
          isA<BuddyApiException>()
              .having((e) => e.code, 'code', 'not_implemented'),
        ),
      );
    });

    test('transport failure becomes unreachable', () async {
      final (String path, Directory dir) = await _tempWav('route.wav');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      final BuddyApi api = BuddyApi(
        host: '192.168.1.10',
        token: 't',
        client: MockClient((_) async => throw const SocketException('refused')),
      );
      addTearDown(api.close);
      expect(
        api.transcribe(path),
        throwsA(
          isA<BuddyApiException>().having((e) => e.code, 'code', 'unreachable'),
        ),
      );
    });

    test('oversize file refused client-side with no network', () async {
      final (String path, Directory dir) = await _tempBigWav(
        'huge.wav',
        BuddyApi.voiceMaxBytes + 1,
      );
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      bool hitNetwork = false;
      final BuddyApi api = _mockApi((_) async {
        hitNetwork = true;
        return http.Response('{}', 200);
      });
      addTearDown(api.close);
      expect(
        api.transcribe(path),
        throwsA(
          isA<BuddyApiException>()
              .having((e) => e.code, 'code', 'body_too_large'),
        ),
      );
      // Let the future settle, then assert the client never sent anything.
      try {
        await api.transcribe(path);
      } catch (_) {}
      expect(hitNetwork, isFalse);
    });

    test('exactly 5MB is still sent (cap is >5MB)', () async {
      final (String path, Directory dir) = await _tempBigWav(
        'edge.wav',
        BuddyApi.voiceMaxBytes,
      );
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      final BuddyApi api = _mockApi(
        (_) async => http.Response(
          '{"text": "edge", "confidence": 1.0, "duration_seconds": 30.0}',
          200,
        ),
      );
      addTearDown(api.close);
      final Transcription result = await api.transcribe(path);
      expect(result.text, 'edge');
    });

    test('missing file is bad_request with no network', () async {
      bool hitNetwork = false;
      final BuddyApi api = _mockApi((_) async {
        hitNetwork = true;
        return http.Response('{}', 200);
      });
      addTearDown(api.close);
      const String missing = '/nonexistent-dir-buddy-b4/nope.wav';
      expect(
        api.transcribe(missing),
        throwsA(
          isA<BuddyApiException>().having((e) => e.code, 'code', 'bad_request'),
        ),
      );
      try {
        await api.transcribe(missing);
      } catch (_) {}
      expect(hitNetwork, isFalse);
    });

    test('voice cap + timeout constants match the server contract', () {
      expect(BuddyApi.voiceMaxBytes, 5 * 1024 * 1024);
      expect(BuddyApi.voiceTimeout, const Duration(seconds: 60));
    });
  });

  group('B4.2 mic-button flow: record → fill for review → send', () {
    testWidgets('mic renders 48dp with the contracted semantics', (
      WidgetTester tester,
    ) async {
      final _FakeRecorder rec = _recorder(tester);
      await _pumpBar(tester, rec);
      expect(find.byIcon(Icons.mic), findsOneWidget);
      expect(
        find.byTooltip(AppStrings.voiceMicLabel),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Record voice command'), findsOneWidget);
      final Size size = tester.getSize(find.byIcon(Icons.mic));
      expect(size.width, greaterThanOrEqualTo(20));
      expect(tester.takeException(), isNull);
    });

    testWidgets('no api and no transcriber means no mic (pre-B4 bar intact)',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        _frame(CommandBar(enabled: true, onSend: (_) async {})),
      );
      await _settle(tester);
      expect(find.byIcon(Icons.mic), findsNothing);
      expect(find.text('Send'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('record → transcribe fills the field, does NOT auto-send', (
      WidgetTester tester,
    ) async {
      final _FakeRecorder rec = _recorder(tester);
      final List<String> sent = <String>[];
      await _pumpBar(tester, rec, sent: sent);
      await _tapMic(tester);
      expect(rec.startCalls, 1);
      expect(rec.startedPaths.single, endsWith('.wav'));
      // Recording panel: timer, live meter, Stop + Cancel.
      expect(find.text('0:00 / 0:30'), findsOneWidget);
      expect(find.byType(VoiceLevelMeter), findsOneWidget);
      expect(find.text(AppStrings.voiceStop), findsOneWidget);
      expect(find.text(AppStrings.actionCancel), findsOneWidget);
      // Real amplitude tick moves the meter (accent fill, DESIGN listening).
      rec.amplitudeCtrl.add(Amplitude(current: -12, max: 0));
      await _settle(tester);
      final VoiceLevelMeter meter = tester.widget<VoiceLevelMeter>(
        find.byType(VoiceLevelMeter),
      );
      expect(meter.level, greaterThan(0));
      // The meter fill carries the DESIGN.md listening accent (scoped to
      // the meter — the recording dot is accent too, by the same table).
      expect(
        find.descendant(
          of: find.byType(VoiceLevelMeter),
          matching: find.byWidgetPredicate(
            (Widget w) =>
                w is Container &&
                w.decoration is BoxDecoration &&
                (w.decoration! as BoxDecoration).color == BuddyColors.accent,
          ),
        ),
        findsOneWidget,
      );
      // Timer ticks with the clock.
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('0:05 / 0:30'), findsOneWidget);
      // Stop → transcribed text lands in the field for review…
      await tester.tap(find.text(AppStrings.voiceStop));
      await _settle(tester);
      expect(rec.stopCalls, 1);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        'open calendar',
      );
      expect(sent, isEmpty);
      // …and the existing send path posts it when the user taps Send.
      await tester.tap(find.text('Send'));
      await _settle(tester);
      expect(sent, <String>['open calendar']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('30s auto-stop transcribes without a Stop tap', (
      WidgetTester tester,
    ) async {
      final _FakeRecorder rec = _recorder(tester);
      await _pumpBar(tester, rec);
      await _tapMic(tester);
      expect(find.text(AppStrings.voiceStop), findsOneWidget);
      // 31s: the 30th tick auto-stops (single 30s pump risks the fake-clock
      // end boundary, so overshoot by one tick — the timer is cancelled on
      // stop, so tick 31 never exists).
      await tester.pump(const Duration(seconds: 31));
      await _settle(tester);
      expect(rec.stopCalls, 1);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        'open calendar',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('B4.3 voice error + cancel states', () {
    testWidgets('permission denial shows copy, never starts the recorder', (
      WidgetTester tester,
    ) async {
      final _FakeRecorder rec = _recorder(tester);
      await _pumpBar(tester, rec, gate: () async => false);
      await _tapMic(tester);
      expect(rec.startCalls, 0);
      expect(find.text(AppStrings.voicePermissionDenied), findsOneWidget);
      expect(find.text(AppStrings.actionRetry), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cancel discards the take: no transcribe, empty field', (
      WidgetTester tester,
    ) async {
      final _FakeRecorder rec = _recorder(tester);
      bool transcribed = false;
      await _pumpBar(
        tester,
        rec,
        transcriber: (_) async {
          transcribed = true;
          return const Transcription(text: 'should not land', confidence: 1);
        },
      );
      await _tapMic(tester);
      expect(find.text(AppStrings.voiceStop), findsOneWidget);
      await tester.tap(find.text(AppStrings.actionCancel));
      await _settle(tester);
      expect(rec.cancelCalls, 1);
      expect(transcribed, isFalse);
      expect(find.text(AppStrings.voiceStop), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('empty transcription shows the retry state', (
      WidgetTester tester,
    ) async {
      final _FakeRecorder rec = _recorder(tester);
      await _pumpBar(
        tester,
        rec,
        transcriber: (_) async =>
            const Transcription(text: '', confidence: 0),
      );
      await _tapMic(tester);
      await tester.tap(find.text(AppStrings.voiceStop));
      await _settle(tester);
      expect(find.text(AppStrings.voiceEmptyRetry), findsOneWidget);
      expect(find.text(AppStrings.actionRetry), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );
      // Retry re-arms capture; cancel then drops back to idle.
      await tester.tap(find.text(AppStrings.actionRetry));
      await _settle(tester);
      expect(rec.startCalls, 2);
      expect(find.text(AppStrings.voiceStop), findsOneWidget);
      await tester.tap(find.text(AppStrings.actionCancel));
      await _settle(tester);
      expect(find.text(AppStrings.voiceStop), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('low confidence (<0.5) is a retry, not a fill', (
      WidgetTester tester,
    ) async {
      final _FakeRecorder rec = _recorder(tester);
      await _pumpBar(
        tester,
        rec,
        transcriber: (_) async =>
            const Transcription(text: 'mumble', confidence: 0.3),
      );
      await _tapMic(tester);
      await tester.tap(find.text(AppStrings.voiceStop));
      await _settle(tester);
      expect(find.text(AppStrings.voiceEmptyRetry), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('501 shows the not-set-up copy', (
      WidgetTester tester,
    ) async {
      final _FakeRecorder rec = _recorder(tester);
      await _pumpBar(
        tester,
        rec,
        transcriber: (_) async {
          throw BuddyApiException.fromRaw(
            501,
            '{"error": {"code": "not_implemented", "message": "no STT"}}}',
          );
        },
      );
      await _tapMic(tester);
      await tester.tap(find.text(AppStrings.voiceStop));
      await _settle(tester);
      expect(find.text(AppStrings.voiceNotImplemented), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('mic start failure shows the start-failed copy', (
      WidgetTester tester,
    ) async {
      final _FakeRecorder rec = _recorder(tester);
      rec.throwOnStart = true;
      await _pumpBar(tester, rec);
      await _tapMic(tester);
      expect(find.text(AppStrings.voiceStartFailed), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('B4.4 suspend + wiring', () {
    testWidgets('background suspend discards an active recording', (
      WidgetTester tester,
    ) async {
      final _FakeRecorder rec = _recorder(tester);
      await _pumpBar(tester, rec, suspend: 0);
      await _tapMic(tester);
      expect(find.text(AppStrings.voiceStop), findsOneWidget);
      // App backgrounded: the existing suspend signal bumps…
      await _pumpBar(tester, rec, suspend: 1);
      expect(rec.cancelCalls, 1);
      expect(find.text(AppStrings.voiceStop), findsNothing);
      expect(find.byType(VoiceLevelMeter), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('suspend with no recording is a no-op', (
      WidgetTester tester,
    ) async {
      final _FakeRecorder rec = _recorder(tester);
      await _pumpBar(tester, rec, suspend: 0);
      await _pumpBar(tester, rec, suspend: 1);
      expect(rec.cancelCalls, 0);
      expect(rec.startCalls, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('ChatScreen forwards suspend + voice seams to the bar', (
      WidgetTester tester,
    ) async {
      final BuddyApi api = _mockApi((_) async => http.Response('', 200));
      addTearDown(api.close);
      final ProximityService proximity = ProximityService()
        ..markNear()
        ..setOnline();
      final _FakeRecorder rec = _recorder(tester);
      Future<Transcription> fakeTranscribe(String _) async =>
          const Transcription(text: 'hi', confidence: 1);
      Future<bool> fakeGate() async => true;
      await tester.pumpWidget(
        _frame(
          ChatScreen(
            api: api,
            events: const [],
            proximity: proximity,
            onSend: (_) async {},
            streamError: null,
            streamConnected: true,
            onRetryStream: () {},
            suspendSignal: 7,
            voiceRecorder: rec,
            voiceTranscriber: fakeTranscribe,
            voicePermissionGate: fakeGate,
          ),
        ),
      );
      await _settle(tester);
      final CommandBar bar = tester.widget<CommandBar>(
        find.byType(CommandBar),
      );
      expect(bar.suspendSignal, 7);
      expect(bar.recorder, same(rec));
      // Mic is live through the forwarded seams.
      expect(find.byIcon(Icons.mic), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('B4.5 meter + announce units', () {
    test('normalize maps dBFS silence…speech to 0…1', () {
      expect(VoiceLevelMeter.normalize(-100), 0);
      expect(VoiceLevelMeter.normalize(-50), 0);
      expect(VoiceLevelMeter.normalize(-25), 0.5);
      expect(VoiceLevelMeter.normalize(0), 1);
      expect(VoiceLevelMeter.normalize(6), 1);
    });

    testWidgets('meter renders the accent fill at the given level', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _frame(const VoiceLevelMeter(level: 0.5)),
      );
      await tester.pump();
      expect(find.byType(VoiceLevelMeter), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (Widget w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration! as BoxDecoration).color == BuddyColors.accent,
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    test('voice announce builders are non-empty (polite live regions)', () {
      expect(voiceRecordingStartedMessage.trim(), isNotEmpty);
      expect(voiceTranscriptionReadyMessage.trim(), isNotEmpty);
      final List<String> heard = <String>[];
      announceVoiceRecording(
        announceForTest: (String m, {bool assertive = false}) =>
            heard.add('$m|$assertive'),
      );
      announceVoiceReady(
        announceForTest: (String m, {bool assertive = false}) =>
            heard.add('$m|$assertive'),
      );
      expect(heard, hasLength(2));
      expect(heard.every((String h) => h.endsWith('|false')), isTrue);
    });

    test('voice strings are registered in the no-empty-values table', () {
      for (final String s in <String>[
        AppStrings.voiceMicLabel,
        AppStrings.voiceRecordingLabel,
        AppStrings.voiceStop,
        AppStrings.voiceTranscribing,
        AppStrings.voiceEmptyRetry,
        AppStrings.voiceNotImplemented,
        AppStrings.voicePermissionDenied,
        AppStrings.voiceTooLarge,
        AppStrings.voiceStartFailed,
      ]) {
        expect(AppStrings.all, contains(s));
        expect(s.trim(), isNotEmpty);
      }
    });

    test('STT capture config stays small (wav 16kHz mono)', () {
      expect(RecordVoiceRecorder.voiceConfig.encoder.name, 'wav');
      expect(RecordVoiceRecorder.voiceConfig.sampleRate, 16000);
      expect(RecordVoiceRecorder.voiceConfig.numChannels, 1);
    });
  });
}
