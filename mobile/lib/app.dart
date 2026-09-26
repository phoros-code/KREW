import 'dart:async';

import 'package:flutter/material.dart';

import 'models/buddy_event.dart';
import 'models/task_item.dart';
import 'models/task_notification.dart';
import 'screens/chat_screen.dart';
import 'screens/pairing_screen.dart';
import 'screens/preview_screen.dart';
import 'screens/task_list_screen.dart';
import 'services/ble_proximity.dart';
import 'services/buddy_api.dart';
import 'services/proximity_service.dart';
import 'services/secure_store.dart';
import 'theme/buddy_theme.dart';
import 'widgets/status_header.dart';
import 'widgets/task_notification_banner.dart';

/// App shell: owns pairing state, the SSE subscription, the folded task
/// list, and proximity state. Every tab renders inside the console-column
/// primitive with the 56px [StatusHeader] always visible.
class BuddyApp extends StatefulWidget {
  const BuddyApp({super.key, SecureStore? store})
    : _storeOverride = store;

  final SecureStore? _storeOverride;

  /// Ordered shutdown contract (Track A5.10): stream subscriptions die
  /// first, the BLE reader fully disposes second, and the proximity
  /// notifier goes last — no RSSI update can land on a disposed
  /// ChangeNotifier. Factored as a static so the order is unit-pinned;
  /// [State.dispose] delegates to it.
  @visibleForTesting
  static Future<void> shutdownOrder({
    required Future<void> Function() cancelStreams,
    required Future<void> Function() disposeReader,
    required void Function() disposeProximity,
  }) async {
    await cancelStreams();
    await disposeReader();
    disposeProximity();
  }

  @override
  State<BuddyApp> createState() => _BuddyAppState();
}

/// SSE auto-reconnect backoff (Track A5.8): 1s, 2s, 4s, 8s, 16s, then capped
/// at 30s. [failures] counts consecutive stream failures (≥1). Pure — unit
/// tested. Manual Reconnect resets the count; so does a fresh `connected`
/// frame.
Duration sseReconnectDelay(int failures) {
  final int step = failures < 1 ? 1 : (failures > 6 ? 6 : failures);
  final int seconds = 1 << (step - 1); // 1, 2, 4, 8, 16, 32
  return Duration(seconds: seconds > 30 ? 30 : seconds);
}

class _BuddyAppState extends State<BuddyApp> with WidgetsBindingObserver {
  late final SecureStore _store;
  final ProximityService _proximity = ProximityService();
  final TaskList _tasks = TaskList();
  final List<BuddyEvent> _events = <BuddyEvent>[];

  BuddyApi? _api;
  String? _savedHost;
  String? _certFingerprint;
  String? _btDeviceId;
  bool _booting = true;
  String? _bootError;
  int _tab = 0;

  StreamSubscription<BuddyEvent>? _subscription;
  BleProximityReader? _bleReader;
  StreamSubscription<int?>? _bleSub;
  StreamSubscription<String?>? _bleCauseSub;
  String? _streamError;
  bool _streamConnected = false;
  int _connectAttempt = 0;

  /// Auto-reconnect state (Track A5.8): consecutive-failure count + pending
  /// timer + the 30s no-frame-no-comment stall watchdog.
  Timer? _reconnectTimer;
  Timer? _stallTimer;
  int _backoffFailures = 0;

  /// Lifecycle suspend counter (Track A5.5): bumped when leaving the Screen
  /// tab or backgrounding; [ScreenPreview] revokes + unmounts on every bump.
  int _previewSuspend = 0;
  bool _backgrounded = false;

  /// Pairing generation (Track A5.12): guards the async BT-id restore in
  /// [_onPaired] so a stale read can never land on a newer pairing.
  int _pairingGeneration = 0;
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    _store = widget._storeOverride ?? SecureStore();
    _proximity.addListener(_onProximityChanged);
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  void _onProximityChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _boot() async {
    try {
      final PairingInfo? saved = await _store.readPairing();
      if (!mounted) return;
      _btDeviceId = await _store.readBtDeviceId();
      if (!mounted) return;
      _certFingerprint = await _store.readCertFingerprint();
      if (!mounted) return;
      BuddyApi? attached;
      setState(() {
        _booting = false;
        _bootError = null;
        if (saved != null) {
          try {
            _attachApi(saved.host, saved.token, _certFingerprint, initialTab: 1);
            attached = _api;
          } on BuddyApiException {
            // Stale saved host that fails the strict gate: stay unpaired
            // instead of crashing boot — the user simply re-pairs.
          }
        }
      });
      if (attached != null) {
        _connectEvents();
        _refreshProximityConfig();
      }
    } catch (_) {
      // Secure-storage failure (locked keystore, missing plugin): a designed
      // retry state, never a red screen or a hang on the spinner.
      if (!mounted) return;
      setState(() {
        _booting = false;
        _bootError =
            'Secure storage is unavailable — pairing details could not be read.';
      });
    }
  }

  void _retryBoot() {
    setState(() {
      _booting = true;
      _bootError = null;
    });
    _boot();
  }

  void _attachApi(String host, String token, String? certFingerprint, {int? initialTab}) {
    _api?.close();
    _api = BuddyApi(host: host, token: token, certFingerprint: certFingerprint);
    _savedHost = host;
    _certFingerprint = certFingerprint;
    _proximity.setUnknown();
    if (initialTab != null) _tab = initialTab;
  }

  void _onPaired(String host, String token, String certFingerprint) {
    _pairingGeneration++;
    final int generation = _pairingGeneration;
    setState(() {
      _attachApi(host, token, certFingerprint);
      _tab = 1;
      _events.clear();
      _tasks.clear();
      _streamError = null;
    });
    // A fresh validation just succeeded — treat the laptop as near until
    // the stream or a command says otherwise (fail-closed stays the default
    // everywhere else: boot, errors, and unreadable signals all yield FAR).
    _proximity.markNear();
    _connectEvents();
    _store.readBtDeviceId().then((String? id) {
      // Generation-guarded (Track A5.12): an unpair/re-pair racing this
      // read must not land a stale BT id on the new pairing.
      if (!mounted || generation != _pairingGeneration) return;
      _btDeviceId = id;
      if (mounted) setState(() {});
      _refreshProximityConfig();
    });
  }

  /// Phase 4.2: fetch mode + threshold once per pairing/boot, then start
  /// the BLE watch only when the server is in lan_plus_bluetooth AND a
  /// device id was saved. Anything missing → BLE stays off (fail closed).
  Future<void> _refreshProximityConfig() async {
    final BuddyApi? api = _api;
    if (api == null) return;
    try {
      final ProximityConfig cfg = await api.fetchProximityConfig();
      _proximity.setThreshold(cfg.rssiNearThreshold);
      if (cfg.usesBluetooth) {
        await _startBleWatch();
      } else {
        await _stopBleWatch();
      }
    } on BuddyApiException {
      // Keep the compiled-in default threshold; the indicator degrades to
      // server-403 behavior instead of breaking pairing.
      await _stopBleWatch();
    }
  }

  Future<void> _startBleWatch() async {
    final String? id = _btDeviceId;
    if (id == null || id.isEmpty) return;
    _bleReader ??= liveBleProximityReader();
    await _bleSub?.cancel();
    await _bleCauseSub?.cancel();
    _bleSub = _bleReader!.rssi.listen((int? rssi) {
      _proximity.updateRssi(rssi);
    });
    // Known-cause surfacing (Track A5.9): permission/adapter problems flow
    // into the calibrate screen + header FAR reason instead of silent FAR.
    _bleCauseSub = _bleReader!.cause.listen((String? cause) {
      _proximity.setBleCause(cause);
    });
    await _bleReader!.start(id);
  }

  Future<void> _stopBleWatch() async {
    await _bleSub?.cancel();
    _bleSub = null;
    await _bleCauseSub?.cancel();
    _bleCauseSub = null;
    await _bleReader?.stop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        // Foreground return re-arms per the existing rules (config fetch →
        // BLE watch only when lan_plus_bluetooth + saved id). The preview
        // itself never auto-restarts.
        _backgrounded = false;
        if (_api != null) _rearmSensitive();
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        if (!_backgrounded) {
          _backgrounded = true;
          _suspendSensitive();
        }
    }
  }

  /// Leaving the Screen tab or backgrounding (Track A5.5): stop the preview
  /// (revoke + player unmount via the suspend counter) and pause the BLE
  /// watch. Nothing keeps running in the background.
  void _suspendSensitive() {
    if (!mounted) return;
    setState(() => _previewSuspend++);
    unawaited(_stopBleWatch());
  }

  /// Returning re-arms per the existing rules (see didChangeAppLifecycleState).
  void _rearmSensitive() {
    unawaited(_refreshProximityConfig());
  }

  /// Tab switch with the lifecycle signal (Track A5.5): leaving Screen
  /// suspends (preview revoke + BLE pause); entering Screen re-arms.
  void _onTab(int i) {
    if (i == _tab) return;
    final bool leavingScreen = _tab == 3 && i != 3;
    final bool enteringScreen = _tab != 3 && i == 3;
    setState(() => _tab = i);
    if (leavingScreen) _suspendSensitive();
    if (enteringScreen && _api != null) _rearmSensitive();
  }

  Future<void> _onUnpair() async {
    _pairingGeneration++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stallTimer?.cancel();
    _stallTimer = null;
    _backoffFailures = 0;
    await _store.clear();
    await _subscription?.cancel();
    await _stopBleWatch();
    _messengerKey.currentState?.clearSnackBars();
    _subscription = null;
    _api?.close();
    _api = null;
    if (!mounted) return;
    setState(() {
      _savedHost = null;
      _certFingerprint = null;
      _btDeviceId = null;
      _tab = 0;
      _events.clear();
      _tasks.clear();
      _streamError = null;
      _streamConnected = false;
    });
    _proximity.markFar();
    _proximity.setUnknown();
    _proximity.setBleCause(null);
  }

  /// Manual (re)connect: resets the backoff, cancels any pending auto-retry
  /// and the stall watchdog, then opens the stream. Wired to every
  /// Reconnect button.
  void _connectEvents() {
    _backoffFailures = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _connectNow();
  }

  void _connectNow() {
    _subscription?.cancel();
    _subscription = null;
    final BuddyApi? api = _api;
    if (api == null) return;
    _connectAttempt++;
    final int attempt = _connectAttempt;
    if (mounted) {
      setState(() {
        _streamError = null;
        _streamConnected = false;
      });
    }
    _proximity.setUnknown();
    _armStallWatchdog(attempt);
    _subscription = api.watchEvents(onActivity: () {
      if (attempt == _connectAttempt) _armStallWatchdog(attempt);
    }).listen(
      (BuddyEvent event) {
        if (!mounted || attempt != _connectAttempt) return;
        // Synthetic open-frame (Track A5.1): HTTP 200 arrived — the stream
        // is open. Mark online + connected WITHOUT waiting for the first
        // task frame, so a fresh pairing enables the command bar with an
        // empty log. Never enters the visible log.
        if (event.type == 'connected') {
          _backoffFailures = 0;
          setState(() {
            _streamConnected = true;
            _streamError = null;
          });
          _proximity.setOnline();
          _armStallWatchdog(attempt);
          return;
        }
        // Fallback title must be read BEFORE folding: completed/failed
        // frames carry result/error, not the command text.
        final String? taskId = event.taskId;
        final TaskNotification? notice = TaskNotification.fromEvent(
          event,
          fallbackTitle: taskId == null ? null : _tasks.byId(taskId)?.title,
        );
        setState(() {
          _streamConnected = true;
          _streamError = null;
          _events.insert(0, event);
          if (_events.length > 200) _events.removeLast();
          _tasks.applyEvent(event);
        });
        _proximity.setOnline();
        _armStallWatchdog(attempt);
        // In-app notification (Phase 4.3): a floating SnackBar over the
        // current console-column screen — no new layout shape, and it works
        // in FAR (notifications-only) mode too. "View" jumps to the Tasks
        // tab; the notice itself already carries the result/error summary.
        final ScaffoldMessengerState? messenger =
            _messengerKey.currentState;
        if (notice != null && messenger != null) {
          showTaskNotification(
            messenger,
            notification: notice,
            onView: () {
              if (mounted) setState(() => _tab = 2);
            },
          );
        }
      },
      onError: (Object err) {
        if (!mounted || attempt != _connectAttempt) return;
        // Any 401 on the stream means re-pair — decided from THIS response,
        // never by waiting for a token_expired SSE frame (which needs auth
        // to receive in the first place). See API.md error codes.
        String message = err is BuddyApiException
            ? err.message
            : 'The live stream dropped. Reconnect to resume updates.';
        bool authFailure = false;
        if (err is BuddyApiException &&
            (err.code == 'unauthorized' || err.code == 'token_expired')) {
          message = 'The laptop rejected the token. Re-pair from the Pair tab.';
          // Re-pair needs the user — never auto-retry an auth failure.
          authFailure = true;
        }
        if (err is BuddyApiException && err.code == 'forbidden') {
          _proximity.markFar();
        }
        if (err is BuddyApiException && err.code == 'unreachable') {
          _proximity.setOffline();
        }
        _onStreamDown(message, authFailure: authFailure);
      },
      onDone: () {
        if (!mounted || attempt != _connectAttempt) return;
        if (_streamError != null) return;
        // onError already recorded the message and scheduled the retry —
        // a bare close after an error adds nothing (and must not double
        // the backoff count).
        _onStreamDown('The live stream closed. Reconnect to resume.');
      },
      cancelOnError: false,
    );
  }

  /// Shared stream-down path (Track A5.8): error state + backed-off
  /// auto-reconnect, generation-guarded by [_connectAttempt] at the call
  /// sites. Auth failures skip the retry — they need a re-pair, not a loop.
  void _onStreamDown(String message, {bool authFailure = false}) {
    _stallTimer?.cancel();
    _stallTimer = null;
    if (!mounted) return;
    setState(() {
      _streamConnected = false;
      _streamError = message;
    });
    if (!authFailure) _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_api == null) return;
    _reconnectTimer?.cancel();
    _backoffFailures++;
    final Duration delay = sseReconnectDelay(_backoffFailures);
    _reconnectTimer = Timer(delay, () {
      if (!mounted || _api == null) return;
      _connectNow();
    });
  }

  /// Stall watchdog (Track A5.8): no frame AND no `:comment` heartbeat for
  /// 30s means the stream is dead even though the socket looks open —
  /// reconnect through the same backed-off path. Re-armed on every event
  /// and every raw line via `onActivity`.
  void _armStallWatchdog(int attempt) {
    _stallTimer?.cancel();
    _stallTimer = Timer(const Duration(seconds: 30), () {
      if (!mounted || attempt != _connectAttempt) return;
      _onStreamDown('The live stream went quiet — reconnecting…');
    });
  }

  Future<void> _sendCommand(String text) async {
    final BuddyApi? api = _api;
    if (api == null) {
      throw const BuddyApiException(
        code: 'unpaired',
        message: 'Pair with the laptop first.',
      );
    }
    try {
      final CommandResult result = await api.postCommand(
        text,
        rssi: _proximity.lastRssi?.toString(),
      );
      if (!mounted) return;
      setState(() => _tasks.setQueued(result.taskId, text));
      _proximity.setOnline();
      // POST /command is near-only: success proves nearness.
      _proximity.markNear();
    } on BuddyApiException catch (e) {
      if (e.code == 'forbidden') _proximity.markFar();
      if (e.code == 'unreachable') _proximity.setOffline();
      rethrow;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stallTimer?.cancel();
    _stallTimer = null;
    _proximity.removeListener(_onProximityChanged);
    // Ordered shutdown (Track A5.10): subscriptions, then the BLE reader,
    // then the proximity notifier — delegated to the pinned static.
    final StreamSubscription<BuddyEvent>? sub = _subscription;
    final StreamSubscription<int?>? bleSub = _bleSub;
    final StreamSubscription<String?>? bleCauseSub = _bleCauseSub;
    final BleProximityReader? reader = _bleReader;
    _subscription = null;
    _bleSub = null;
    _bleCauseSub = null;
    _bleReader = null;
    unawaited(
      BuddyApp.shutdownOrder(
        cancelStreams: () async {
          await sub?.cancel();
          await bleSub?.cancel();
          await bleCauseSub?.cancel();
        },
        disposeReader: () async {
          if (reader != null) await reader.dispose();
        },
        disposeProximity: _proximity.dispose,
      ),
    );
    _api?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_bootError != null) {
      // Designed boot-failure state (Track A5.6): secure storage unreadable.
      // One explanatory line + Retry — same tokens, no new styling.
      final String message = _bootError!;
      return MaterialApp(
        title: 'Everyday Buddy',
        scaffoldMessengerKey: _messengerKey,
        theme: BuddyTheme.light(),
        darkTheme: BuddyTheme.dark(),
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(BuddySpacing.s5),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Builder(
                    builder: (BuildContext inner) {
                      final bool dark =
                          Theme.of(inner).brightness == Brightness.dark;
                      return Icon(
                        Icons.error_outline,
                        size: 32,
                        color: dark
                            ? BuddyColors.errorOnDark
                            : BuddyColors.errorOnLight,
                      );
                    },
                  ),
                  const SizedBox(height: BuddySpacing.s3),
                  Text(
                    'Could not start',
                    style: Theme.of(context).textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: BuddySpacing.s2),
                  Text(
                    message,
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: BuddySpacing.s4),
                  ElevatedButton(
                    onPressed: _retryBoot,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return MaterialApp(
      title: 'Everyday Buddy',
      scaffoldMessengerKey: _messengerKey,
      theme: BuddyTheme.light(),
      darkTheme: BuddyTheme.dark(),
      home: _booting
          ? const Scaffold(
              body: Center(
                child: SizedBox(
                  width: BuddySpacing.s5,
                  height: BuddySpacing.s5,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          : Scaffold(
              appBar: StatusHeader(
                proximity: _proximity.mode,
                connection: _proximity.connection,
                runningCount: _tasks.runningCount,
                farReason: _proximity.bleCause,
              ),
              body: IndexedStack(
                index: _tab,
                children: <Widget>[
                  PairingScreen(
                    store: _store,
                    initialHost: _savedHost,
                    initialBtDeviceId: _btDeviceId,
                    initialCertFingerprint: _certFingerprint,
                    onPaired: _onPaired,
                  ),
                  ChatScreen(
                    api: _api,
                    events: _events,
                    proximity: _proximity,
                    onSend: _sendCommand,
                    streamError: _streamError,
                    streamConnected: _streamConnected,
                    onRetryStream: _connectEvents,
                  ),
                  TaskListScreen(
                    tasks: _tasks,
                    isPaired: _api != null,
                    streamError: _streamError,
                    onRetry: _connectEvents,
                  ),
                  PreviewScreen(
                    api: _api,
                    proximity: _proximity.mode,
                    proximityService: _proximity,
                    onCalibrated: _refreshProximityConfig,
                    suspendSignal: _previewSuspend,
                  ),
                ],
              ),
              bottomNavigationBar: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (_api != null)
                    _UnpairStrip(savedHost: _savedHost, onUnpair: _onUnpair),
                  // Track C1: M3 NavigationBar (not M2 BottomNavigationBar).
                  // 4 destinations + labels + behavior identical; styling
                  // (8px indicator, primary/ink colors) comes from
                  // BuddyTheme.navigationBarTheme.
                  NavigationBar(
                    selectedIndex: _tab,
                    onDestinationSelected: _onTab,
                    labelBehavior:
                        NavigationDestinationLabelBehavior.alwaysShow,
                    destinations: const <NavigationDestination>[
                      NavigationDestination(
                        icon: Icon(Icons.link_outlined),
                        selectedIcon: Icon(Icons.link),
                        label: 'Pair',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.chat_bubble_outline),
                        selectedIcon: Icon(Icons.chat_bubble),
                        label: 'Chat',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.assignment_outlined),
                        selectedIcon: Icon(Icons.assignment),
                        label: 'Tasks',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.monitor_outlined),
                        selectedIcon: Icon(Icons.monitor),
                        label: 'Screen',
                      ),
                    ],
                  ),
                ],
              ),
            ),
    );
  }
}

/// Slim "paired to <host>" strip with an unpair action — whitespace and one
/// text button, not another card.
class _UnpairStrip extends StatelessWidget {
  const _UnpairStrip({required this.savedHost, required this.onUnpair});

  final String? savedHost;
  final VoidCallback onUnpair;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color muted = dark
        ? BuddyColors.inkMutedOnDark
        : BuddyColors.inkMutedOnLight;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: BuddySpacing.s4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              savedHost == null ? 'Paired' : 'Paired to $savedHost',
              style: BuddyTheme.mono(muted, size: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () async {
              final bool? confirm = await showDialog<bool>(
                context: context,
                builder: (BuildContext ctx) => AlertDialog(
                  title: const Text('Unpair this laptop?'),
                  content: const Text(
                    'The token is deleted from secure storage. You can re-pair at any time from the laptop.',
                  ),
                  actions: <Widget>[
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: const Text('Unpair'),
                    ),
                  ],
                ),
              );
              if (confirm == true) onUnpair();
            },
            child: const Text('Unpair'),
          ),
        ],
      ),
    );
  }
}
