import 'dart:async';
import 'dart:ui' show FlutterView, PlatformDispatcher, TextDirection;

import 'package:flutter/semantics.dart';

import '../models/task_notification.dart';
import '../services/proximity_service.dart';

/// Track C2 accessibility helpers: live-region message builders (pure,
/// unit-tested) + a thin engine wrapper.
///
/// Message builders return the exact announcement strings so tests can assert
/// them without touching the engine. [announceLiveRegion] is the only place
/// that talks to the platform; it takes an optional [announceForTest] seam so
/// widget/unit tests can capture calls without mocking the engine channel.
///
/// Politeness policy (Track C2 §3): everything announces politely EXCEPT
/// offline connection + failed tasks, which are assertive.
typedef AnnounceFn = void Function(String message, {bool assertive});

/// Proximity NEAR↔FAR announcement (always polite).
String proximityAnnounceMessage(ProximityMode mode) {
  switch (mode) {
    case ProximityMode.near:
      return 'Proximity near — full control available';
    case ProximityMode.far:
      return 'Proximity far — notifications only, commands blocked';
  }
}

/// Connection online/offline announcement.
String connectionAnnounceMessage(BuddyConnection connection) {
  switch (connection) {
    case BuddyConnection.online:
      return 'Connection online — laptop reachable';
    case BuddyConnection.offline:
      return 'Connection offline — no route to laptop';
    case BuddyConnection.unknown:
      return 'Connection connecting — opening the live stream';
  }
}

/// Only offline interrupts (assertive); online/connecting stay polite.
bool connectionIsAssertive(BuddyConnection connection) =>
    connection == BuddyConnection.offline;

/// Task notice announcement reuses the SnackBar semantic label.
String taskAnnounceMessage(TaskNotification notification) =>
    notification.semanticLabel;

/// Only failures interrupt; completions stay polite.
bool taskIsAssertive(TaskNotification notification) =>
    notification.kind == TaskNotificationKind.failed;

/// Preview ready announcement per source (polite).
String previewReadyMessage({required bool webcam}) => webcam
    ? 'Laptop webcam preview, live'
    : 'Laptop screen preview, live';

/// Preview ended announcement (polite).
String get previewEndedMessage => 'Preview ended';

/// Preview denied announcement (polite).
String get previewDeniedMessage =>
    'Preview request denied by the laptop';

/// Voice recording started announcement (polite, Track B4).
String get voiceRecordingStartedMessage =>
    'Recording voice command. Tap Stop when done.';

/// Voice transcription ready-for-review announcement (polite, Track B4).
String get voiceTranscriptionReadyMessage =>
    'Voice command transcribed and ready for review.';

/// Thin engine wrapper: posts [message] as a live-region announcement.
/// Failures are swallowed — announcements must never break UI. In tests pass
/// [announceForTest] to capture instead of touching the engine channel.
void announceLiveRegion(
  String message, {
  bool assertive = false,
  AnnounceFn? announceForTest,
}) {
  if (announceForTest != null) {
    announceForTest(message, assertive: assertive);
    return;
  }
  try {
    final FlutterView? view = PlatformDispatcher.instance.implicitView;
    if (view == null) return;
    unawaited(
      SemanticsService.sendAnnouncement(
        view,
        message,
        TextDirection.ltr,
        assertiveness: assertive
            ? Assertiveness.assertive
            : Assertiveness.polite,
      ),
    );
  } catch (_) {
    // Announcements are best-effort only.
  }
}

/// Convenience: announce a proximity transition (polite).
void announceProximity(ProximityMode mode, {AnnounceFn? announceForTest}) {
  announceLiveRegion(
    proximityAnnounceMessage(mode),
    announceForTest: announceForTest,
  );
}

/// Convenience: announce a connection transition (assertive only for offline).
void announceConnection(
  BuddyConnection connection, {
  AnnounceFn? announceForTest,
}) {
  announceLiveRegion(
    connectionAnnounceMessage(connection),
    assertive: connectionIsAssertive(connection),
    announceForTest: announceForTest,
  );
}

/// Convenience: announce a task notice (assertive only for failures).
void announceTaskNotification(
  TaskNotification notification, {
  AnnounceFn? announceForTest,
}) {
  announceLiveRegion(
    taskAnnounceMessage(notification),
    assertive: taskIsAssertive(notification),
    announceForTest: announceForTest,
  );
}

/// Convenience: announce voice recording start (polite, Track B4).
void announceVoiceRecording({AnnounceFn? announceForTest}) {
  announceLiveRegion(
    voiceRecordingStartedMessage,
    announceForTest: announceForTest,
  );
}

/// Convenience: announce transcription ready for review (polite, Track B4).
void announceVoiceReady({AnnounceFn? announceForTest}) {
  announceLiveRegion(
    voiceTranscriptionReadyMessage,
    announceForTest: announceForTest,
  );
}
