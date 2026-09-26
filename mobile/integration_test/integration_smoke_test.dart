import 'dart:io';

import 'package:everyday_buddy/app.dart';
import 'package:everyday_buddy/services/secure_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal integration smoke (Track A6.14).
///
/// A stub [SecureStore] (the app shell's pairing seam — BuddyApp builds its
/// own BuddyApi from saved pairing, so store-stubbing IS the fake here)
/// drives the REAL BuddyApp: boot, tab shell, and first-frame rendering are
/// all production code. flutter_test only — no new dependencies.
///
/// Full server-backed integration (real TLS server, live SSE stream, BLE
/// sightings, consent approval) stays a human/device gate per
/// HARDWARE_VERIFICATION.md and is NOT attempted here.

/// Unpaired stub: no saved pairing, no BT id, no fingerprint.
class _StubStore extends SecureStore {
  _StubStore() : super();

  @override
  Future<PairingInfo?> readPairing() async => null;

  @override
  Future<String?> readBtDeviceId() async => null;

  @override
  Future<String?> readCertFingerprint() async => null;
}

/// HttpClient that fails fast (microtask, FakeAsync-friendly) with a refused
/// socket — hermetic paired-boot with zero real sockets: errors arrive while
/// the shell is subscribed, so onError handles them deterministically and
/// nothing leaks across tests.
class _FailFastClient implements HttpClient {
  @override
  set badCertificateCallback(
    bool Function(X509Certificate cert, String host, int port)? cb,
  ) {}

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    throw const SocketException('refused');
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FailFastOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _FailFastClient();
}

void main() {
  // Track C1: google_fonts removed — no test font config needed.

  testWidgets('unpaired shell renders all 4 tabs', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(BuddyApp(store: _StubStore()));
    await tester.pumpAndSettle();
    // Track C1: M3 NavigationBar (not M2 BottomNavigationBar).
    expect(find.byType(NavigationBar), findsOneWidget);
    for (final label in <String>['Pair', 'Chat', 'Tasks', 'Screen']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    // First tab is the pairing screen with its trust-moment copy.
    expect(find.text('Pair with your laptop'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('paired shell lands on Chat with all 4 tabs', (
    WidgetTester tester,
  ) async {
    // Hermetic: fail-fast transport instead of real sockets (a refused
    // localhost connection otherwise completes on the real event loop at an
    // arbitrary moment — possibly after unmount, as an uncaught error).
    // Save/restore: the widget binding owns a global 400-mock — resetting
    // to null would leak real sockets into later tests.
    final HttpOverrides? previousOverrides = HttpOverrides.current;
    HttpOverrides.global = _FailFastOverrides();
    addTearDown(() => HttpOverrides.global = previousOverrides);
    await tester.pumpWidget(BuddyApp(store: _PairedStubStore()));
    // Bounded pumps only: the shell opens a stream plus a 30s stall timer
    // — settling would loop on the reconnect path.
    for (int i = 0; i < 5; i++) {
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(NavigationBar), findsOneWidget);
    for (final label in <String>['Pair', 'Chat', 'Tasks', 'Screen']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('Agent log'), findsOneWidget);
    // Unmount cancels the pending stream/stall timers — clean teardown.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(tester.takeException(), isNull);
  });
}

/// Paired stub: localhost pairing (connection-refused fails fast on device;
/// never completes under fake async — either way no timers are left behind
/// after unmount).
class _PairedStubStore extends SecureStore {
  _PairedStubStore() : super();

  @override
  Future<PairingInfo?> readPairing() async =>
      const PairingInfo(host: '127.0.0.1', token: 'tok12345');

  @override
  Future<String?> readBtDeviceId() async => null;

  @override
  Future<String?> readCertFingerprint() async => null;
}
