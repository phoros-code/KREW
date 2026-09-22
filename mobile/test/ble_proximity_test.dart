import 'dart:async';

import 'package:everyday_buddy/services/ble_proximity.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake scan backend: the test pushes sighting batches by hand.
class FakeBle {
  FakeBle() : sightings = StreamController<Sightings>.broadcast();

  final StreamController<Sightings> sightings;
  final List<List<String>> startCalls = <List<String>>[];
  int stopCalls = 0;
  bool throwOnStart = false;

  Future<void> startScan(List<String> ids) async {
    startCalls.add(ids);
    if (throwOnStart) throw Exception('Bluetooth off');
  }

  Future<void> stopScan() async {
    stopCalls += 1;
  }
}

BleProximityReader readerOf(
  FakeBle ble, {
  Duration staleAfter = const Duration(milliseconds: 30),
}) => BleProximityReader(
  sightings: ble.sightings.stream,
  startScan: ble.startScan,
  stopScan: ble.stopScan,
  staleAfter: staleAfter,
);

/// One sighting: sidesteps inline record-literal parsing quirks in lists.
({String id, int rssi}) sight(String id, int rssi) => (id: id, rssi: rssi);

void main() {
  group('BleProximityReader (fail closed)', () {
    test('sighting of the watched id emits its RSSI', () async {
      final ble = FakeBle();
      final reader = readerOf(ble);
      final List<int?> seen = <int?>[];
      final sub = reader.rssi.listen(seen.add);
      await reader.start('AA:BB:CC:DD:EE:FF');
      ble.sightings.add([sight('11:22:33:44:55:66', -90), sight('aa:bb:cc:dd:ee:ff', -55)]);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(seen, contains(-55));
      expect(ble.startCalls, hasLength(1));
      await sub.cancel();
      await reader.dispose();
      await ble.sightings.close();
    });

    test('other devices are ignored', () async {
      final ble = FakeBle();
      final reader = readerOf(ble);
      final List<int?> seen = <int?>[];
      final sub = reader.rssi.listen(seen.add);
      await reader.start('AA:BB:CC:DD:EE:FF');
      ble.sightings.add([sight('11:22:33:44:55:66', -40)]);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(seen, isEmpty);
      await sub.cancel();
      await reader.dispose();
      await ble.sightings.close();
    });

    test('silence past staleAfter yields null (FAR)', () async {
      final ble = FakeBle();
      final reader = readerOf(ble);
      final List<int?> seen = <int?>[];
      final sub = reader.rssi.listen(seen.add);
      await reader.start('AA:BB:CC:DD:EE:FF');
      ble.sightings.add([sight('aa:bb:cc:dd:ee:ff', -55)]);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(seen, contains(-55));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(seen, contains(null));
      await sub.cancel();
      await reader.dispose();
      await ble.sightings.close();
    });

    test('blank id never scans — caller stays FAR', () async {
      final ble = FakeBle();
      final reader = readerOf(ble);
      await reader.start('   ');
      expect(ble.startCalls, isEmpty);
      expect(reader.isWatching, isFalse);
      await reader.dispose();
      await ble.sightings.close();
    });

    test('scan failure surfaces as null, never throws', () async {
      final ble = FakeBle()..throwOnStart = true;
      final reader = readerOf(ble);
      final List<int?> seen = <int?>[];
      final sub = reader.rssi.listen(seen.add);
      await reader.start('AA:BB:CC:DD:EE:FF'); // must not throw
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(seen, contains(null));
      await sub.cancel();
      await reader.dispose();
      await ble.sightings.close();
    });

    test('stop ends the watch and calls stopScan', () async {
      final ble = FakeBle();
      final reader = readerOf(ble);
      await reader.start('AA:BB:CC:DD:EE:FF');
      expect(reader.isWatching, isTrue);
      await reader.stop();
      expect(reader.isWatching, isFalse);
      expect(ble.stopCalls, greaterThanOrEqualTo(1));
      await reader.dispose();
      await ble.sightings.close();
    });

    test('iOS UUID path matches case-insensitively (same gate as MAC)', () async {
      // iOS reports the laptop as a UUID, not a MAC — the matcher must treat
      // it identically: trim + lowercase compare, emit RSSI on sighting.
      const uuid = 'A1B2C3D4-E5F6-7890-ABCD-EF1234567890';
      final ble = FakeBle();
      final reader = readerOf(ble);
      final List<int?> seen = <int?>[];
      final sub = reader.rssi.listen(seen.add);
      await reader.start(uuid);
      ble.sightings.add([sight('11:22:33:44:55:66', -90), sight(uuid.toLowerCase(), -62)]);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(seen, contains(-62));
      await sub.cancel();
      await reader.dispose();
      await ble.sightings.close();
    });

    test('UUID with surrounding whitespace still matches (trimmed)', () async {
      const uuid = 'A1B2C3D4-E5F6-7890-ABCD-EF1234567890';
      final ble = FakeBle();
      final reader = readerOf(ble);
      final List<int?> seen = <int?>[];
      final sub = reader.rssi.listen(seen.add);
      await reader.start('  $uuid  ');
      ble.sightings.add([sight(uuid, -70)]);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(seen, contains(-70));
      await sub.cancel();
      await reader.dispose();
      await ble.sightings.close();
    });

    test('UUID mismatch stays FAR (wrong device ignored)', () async {
      final ble = FakeBle();
      final reader = readerOf(ble);
      final List<int?> seen = <int?>[];
      final sub = reader.rssi.listen(seen.add);
      await reader.start('A1B2C3D4-E5F6-7890-ABCD-EF1234567890');
      ble.sightings.add([sight('FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF', -50)]);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(seen, isEmpty);
      await sub.cancel();
      await reader.dispose();
      await ble.sightings.close();
    });
  });
}
