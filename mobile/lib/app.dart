import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'l10n/strings.dart';
import 'models/buddy_event.dart';
import 'models/notification_history.dart';
import 'models/task_item.dart';
import 'models/task_log.dart';
import 'models/task_notification.dart';
import 'screens/chat_screen.dart';
import 'screens/pairing_screen.dart';
import 'screens/preview_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/task_detail_screen.dart';
import 'screens/task_list_screen.dart';
import 'services/ble_proximity.dart';
import 'services/buddy_api.dart';
import 'services/proximity_service.dart';
import 'services/secure_store.dart';
import 'theme/buddy_theme.dart';
import 'widgets/a11y.dart';
import 'widgets/onboarding_overlay.dart';
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

  /// Track C3: in-memory bounded notification history (last 50) for the
  /// "Recent notifications" section in the Tasks tab. Process lifetime
  /// only — never persisted.
  final NotificationHistory _history = NotificationHistory();

  BuddyApi? _api;
  String? _savedHost;
  String? _certFingerprint;
  String? _btDeviceId;

  /// Track C3: ISO-8601 pairing timestamp (Settings → Pairing status),
  /// in-app notification toggle (persisted), and the once-only onboarding
  /// overlay flag (persisted; shown only when paired).
  String? _pairedOn;
  bool _notificationsEnabled = true;
  bool _showOnboarding = false;
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

  /// Track C4 SSE batching: events arriving in the same microtask/frame are
  /// folded in ONE setState. [_pendingEvents] holds arrivals since the last
  /// flush; [_flushScheduled] guards the single scheduled microtask;
  /// [_pendingAttempt] drops stale batches after a reconnect.
  final List<BuddyEvent> _pendingEvents = <BuddyEvent>[];
  bool _flushScheduled = false;
  int _pendingAttempt = 0;

  /// Track C2: last announced live-region state — prevents repeat
  /// announcements on unrelated rebuilds.
  ProximityMode? _lastAnnouncedMode;
  BuddyConnection? _lastAnnouncedConnection;

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
    // Track C4 rebuild scoping: NO setState here. The header (StatusHeader
    // via ListenableBuilder in build), the chat subtitle/command bar
    // (ListenableBuilders in ChatScreen), the preview gate (ListenableBuilder
    // in PreviewScreen), and the calibrate section (AnimatedBuilder) all
    // subscribe directly — a BLE pulse rebuilds ONLY those, never the whole
    // app or the chat log list.
    // Track C2: live-region announcements on NEAR↔FAR and offline/online
    // transitions only (polite, except offline which is assertive).
    final ProximityMode mode = _proximity.mode;
    final BuddyConnection connection = _proximity.connection;
    if (mode != _lastAnnouncedMode) {
      final ProximityMode? previous = _lastAnnouncedMode;
      _lastAnnouncedMode = mode;
      // Skip the very first emission (initial FAR at boot) — announce only
      // real transitions.
      if (previous != null) {
        announceLiveRegion(proximityAnnounceMessage(mode));
      }
    }
    if (connection != _lastAnnouncedConnection) {
      final BuddyConnection? previous = _lastAnnouncedConnection;
      _lastAnnouncedConnection = connection;
      // Skip the initial unknown at boot; announce online/offline only.
      if (previous != null &&
          (connection == BuddyConnection.online ||
              connection == BuddyConnection.offline)) {
        announceLiveRegion(
          connectionAnnounceMessage(connection),
          assertive: connectionIsAssertive(connection),
        );
      }
    }
  }

  Future<void> _boot() async {
    try {
      final PairingInfo? saved = await _store.readPairing();
      if (!mounted) return;
      _btDeviceId = await _store.readBtDeviceId();
      if (!mounted) return;
      _certFingerprint = await _store.readCertFingerprint();
      if (!mounted) return;
      _pairedOn = await _store.readPairedOn();
      if (!mounted) return;
      _notificationsEnabled = await _store.readNotificationsEnabled();
      if (!mounted) return;
      final bool onboardingSeen = await _store.readOnboardingSeen();
      if (!mounted) return;
      BuddyApi? attached;
      setState(() {
        _booting = false;
        _bootError = null;
        if (saved != null) {
          try {
            _attachApi(saved.host, saved.token, _certFingerprint, initialTab: 1);
            attached = _api;
            // Track C3: onboarding shows once, after a pairing exists —
            // never on a fresh (unpaired) first run.
            _showOnboarding = !onboardingSeen;
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
        _bootError = AppStrings.bootFailedMessage;
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
      _history.clear();
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
    // Track C3: pairing just saved (savePairing wrote the timestamp) —
    // refresh the local copy and show the once-only tour when unseen.
    _store.readPairedOn().then((String? pairedOn) {
      if (!mounted || generation != _pairingGeneration) return;
      if (mounted) setState(() => _pairedOn = pairedOn);
    });
    _store.readOnboardingSeen().then((bool seen) {
      if (!mounted || generation != _pairingGeneration) return;
      if (!seen && mounted) setState(() => _showOnboarding = true);
    });
  }

  /// Phase 4.2: fetch mode + threshold once per pairing/boot, then start
  /// the BLE watch only when the server is in lan_plus_bluetooth AND a
  /// device id was saved. Anything missing → BLE stays off (fail closed).
  ///
  /// Track C4: the threshold snapshot passed to SettingsScreen is refreshed
  /// here (one parent rebuild per config fetch — infrequent, server-driven).
  /// Per-reading BLE pulses (updateRssi → markNear/markFar) stay scoped via
  /// ListenableBuilders and never rebuild the shell.
  Future<void> _refreshProximityConfig() async {
    final BuddyApi? api = _api;
    if (api == null) return;
    try {
      final ProximityConfig cfg = await api.fetchProximityConfig();
      _proximity.setThreshold(cfg.rssiNearThreshold);
      if (mounted) setState(() {});
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
      _pairedOn = null;
      _showOnboarding = false;
      _tab = 0;
      _events.clear();
      _tasks.clear();
      _history.clear();
      _streamError = null;
      _streamConnected = false;
    });
    _proximity.markFar();
    _proximity.setUnknown();
    _proximity.setBleCause(null);
  }

  /// Track C3 pull-to-refresh (Chat console + task list): reconnect the SSE
  /// stream (backoff reset, like every Reconnect button) and refetch the
  /// proximity config (threshold + BLE re-arm rules).
  Future<void> _handleRefresh() async {
    _connectEvents();
    await _refreshProximityConfig();
  }

  /// Track C3: open the per-task log view for [taskId]. Resolves the folded
  /// task plus its full event list; a history row whose task already aged
  /// out of nothing (history only records live tasks) still finds its task
  /// because both fold from the same stream. Unknown ids are ignored.
  void _openTask(String taskId) {
    final TaskItem? task = _tasks.byId(taskId);
    if (task == null || !mounted) return;
    final List<BuddyEvent> events = eventsForTask(_events, taskId);
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) =>
              TaskDetailScreen(task: task, events: events),
        ),
      ),
    );
  }

  /// Track C3: Settings → clear the Bluetooth device id. Drops the saved
  /// id, stops the BLE watch (fail closed → server-403 behavior), and
  /// confirms with a SnackBar.
  Future<void> _onClearBt() async {
    await _store.saveBtDeviceId(null);
    await _stopBleWatch();
    if (!mounted) return;
    setState(() => _btDeviceId = null);
    _messengerKey.currentState?.showSnackBar(
      const SnackBar(content: Text(AppStrings.settingsBtCleared)),
    );
  }

  /// Track C3: Settings → notification toggle (persisted in SecureStore).
  Future<void> _onNotificationsChanged(bool enabled) async {
    await _store.saveNotificationsEnabled(enabled);
    if (!mounted) return;
    setState(() => _notificationsEnabled = enabled);
  }

  /// Track C3: onboarding Skip / Get started — persist the seen flag so the
  /// tour shows exactly once, then drop the overlay.
  Future<void> _onOnboardingDone() async {
    await _store.saveOnboardingSeen();
    if (!mounted) return;
    setState(() => _showOnboarding = false);
  }

  /// Track C3: Tasks-tab Clear-history button.
  void _clearHistory() {
    setState(() => _history.clear());
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
    // A new generation drops any unflushed batch from the old stream —
    // stale frames must never land on the new connection.
    _pendingEvents.clear();
    _flushScheduled = false;
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
        // Track C4 batching: collect per microtask/frame, fold once.
        _queueEvent(event, attempt);
      },
      onError: (Object err) {
        if (!mounted || attempt != _connectAttempt) return;
        // Any 401 on the stream means re-pair — decided from THIS response,
        // never by waiting for a token_expired SSE frame (which needs auth
        // to receive in the first place). See API.md error codes.
        String message = err is BuddyApiException
            ? err.message
            : AppStrings.streamDropped;
        bool authFailure = false;
        if (err is BuddyApiException &&
            (err.code == 'unauthorized' || err.code == 'token_expired')) {
          message = AppStrings.streamAuthFailure;
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
        _onStreamDown(AppStrings.streamClosed);
      },
      cancelOnError: false,
    );
  }

  /// Track C4 SSE batching: queue one arrival, flush the whole batch in a
  /// single setState on the next microtask. Bursts (reconnect replay,
  /// rapid tool calls) cost one rebuild, not N.
  void _queueEvent(BuddyEvent event, int attempt) {
    _pendingEvents.add(event);
    _pendingAttempt = attempt;
    if (_flushScheduled) return;
    _flushScheduled = true;
    scheduleMicrotask(_flushPendingEvents);
  }

  /// Test seam: force a synchronous flush of any queued SSE batch.
  @visibleForTesting
  void flushPendingEventsForTest() {
    if (_flushScheduled) {
      _flushPendingEvents();
    }
  }

  void _flushPendingEvents() {
    _flushScheduled = false;
    if (_pendingEvents.isEmpty) return;
    final int attempt = _pendingAttempt;
    if (!mounted || attempt != _connectAttempt) {
      _pendingEvents.clear();
      return;
    }
    final List<BuddyEvent> batch = List<BuddyEvent>.from(_pendingEvents);
    _pendingEvents.clear();
    // Fallback titles must be read BEFORE folding each frame (completed /
    // failed carry result/error, not the command text) — fold incrementally
    // so later frames in the same batch see earlier ones, exactly as the
    // old per-event path did.
    final List<TaskNotification> notices = <TaskNotification>[];
    for (final BuddyEvent event in batch) {
      final String? taskId = event.taskId;
      final TaskNotification? notice = TaskNotification.fromEvent(
        event,
        fallbackTitle: taskId == null ? null : _tasks.byId(taskId)?.title,
      );
      _tasks.applyEvent(event);
      if (notice != null) notices.add(notice);
    }
    setState(() {
      _streamConnected = true;
      _streamError = null;
      _events.insertAll(0, batch.reversed);
      if (_events.length > 200) {
        _events.removeRange(200, _events.length);
      }
      // Track C3: every task notice also lands in the bounded in-memory
      // history (last 50) for the Tasks-tab section — popup or not.
      for (final TaskNotification notice in notices) {
        _history.add(notice);
      }
    });
    _proximity.setOnline();
    _armStallWatchdog(attempt);
    // In-app notification (Phase 4.3): a floating SnackBar over the current
    // console-column screen — no new layout shape, and it works in FAR
    // (notifications-only) mode too. "View" jumps to the Tasks tab; the
    // notice itself already carries the result/error summary.
    // Track C3: gated by the Settings toggle (history still records).
    // Track C4: capped (removeCurrentSnackBar) + deduped (10s) inside
    // showTaskNotification; announce path unchanged.
    final ScaffoldMessengerState? messenger = _messengerKey.currentState;
    for (final TaskNotification notice in notices) {
      if (messenger != null && _notificationsEnabled) {
        showTaskNotification(
          messenger,
          notification: notice,
          onView: () {
            if (mounted) setState(() => _tab = 2);
          },
        );
        // Track C2: live-region announcement from the same notice path —
        // polite except failures (assertive).
        announceTaskNotification(notice);
      }
    }
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
      _onStreamDown(AppStrings.streamQuiet);
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
    // Track C3 i18n scaffold: English only (lib/l10n/strings.dart is the
    // copy table; full ARB flow out of scope).
    const List<LocalizationsDelegate<dynamic>> delegates =
        <LocalizationsDelegate<dynamic>>[
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ];
    const List<Locale> supported = <Locale>[Locale('en')];
    if (_bootError != null) {
      // Designed boot-failure state (Track A5.6): secure storage unreadable.
      // One explanatory line + Retry — same tokens, no new styling.
      // Track C2: container semantics + 48dp Retry target.
      final String message = _bootError!;
      return MaterialApp(
        title: 'Everyday Buddy',
        scaffoldMessengerKey: _messengerKey,
        theme: BuddyTheme.light(),
        darkTheme: BuddyTheme.dark(),
        localizationsDelegates: delegates,
        supportedLocales: supported,
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(BuddySpacing.s5),
              child: Semantics(
                label: '${AppStrings.bootFailedTitle}. $message',
                container: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Builder(
                      builder: (BuildContext inner) {
                        final bool dark =
                            Theme.of(inner).brightness == Brightness.dark;
                        return ExcludeSemantics(
                          child: Icon(
                            Icons.error_outline,
                            size: 32,
                            color: dark
                                ? BuddyColors.errorOnDark
                                : BuddyColors.errorOnLight,
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: BuddySpacing.s3),
                    Text(
                      AppStrings.bootFailedTitle,
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
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size(48, 48),
                          tapTargetSize: MaterialTapTargetSize.padded,
                        ),
                        onPressed: _retryBoot,
                        child: const Text(AppStrings.actionRetry),
                      ),
                    ),
                  ],
                ),
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
      localizationsDelegates: delegates,
      supportedLocales: supported,
      home: _booting
          ? Scaffold(
              body: Center(
                child: Semantics(
                  label: 'Starting Everyday Buddy, please wait',
                  liveRegion: true,
                  child: const SizedBox(
                    width: BuddySpacing.s5,
                    height: BuddySpacing.s5,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            )
          : Stack(
              children: <Widget>[
                Scaffold(
                  // Track C4 rebuild scoping: the 56px header subscribes
                  // directly to ProximityService — BLE pulses rebuild ONLY
                  // this (plus chat subtitle/bar, preview gate, and
                  // calibrate via their own listeners), never the whole
                  // IndexedStack or the chat log.
                  appBar: PreferredSize(
                    preferredSize: const Size.fromHeight(56),
                    child: ListenableBuilder(
                      listenable: _proximity,
                      builder: (BuildContext context, Widget? _) =>
                          StatusHeader(
                            proximity: _proximity.mode,
                            connection: _proximity.connection,
                            runningCount: _tasks.runningCount,
                            farReason: _proximity.bleCause,
                          ),
                    ),
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
                        onRefresh: _api == null ? null : _handleRefresh,
                      ),
                      TaskListScreen(
                        tasks: _tasks,
                        isPaired: _api != null,
                        streamError: _streamError,
                        onRetry: _connectEvents,
                        notifications: _history.items,
                        onClearHistory: _clearHistory,
                        onOpenTask: _openTask,
                        onRefresh: _api == null ? null : _handleRefresh,
                      ),
                      PreviewScreen(
                        api: _api,
                        proximity: _proximity.mode,
                        proximityService: _proximity,
                        onCalibrated: _refreshProximityConfig,
                        suspendSignal: _previewSuspend,
                      ),
                      SettingsScreen(
                        api: _api,
                        host: _savedHost,
                        pairedOn: _pairedOn,
                        btDeviceId: _btDeviceId,
                        threshold: _proximity.rssiNearThreshold,
                        notificationsEnabled: _notificationsEnabled,
                        onNotificationsChanged: _onNotificationsChanged,
                        onClearBt: _onClearBt,
                        onUnpair: _onUnpair,
                      ),
                    ],
                  ),
                  // Track C3: the old Pair-tab unpair strip is gone — unpair
                  // is a single destructive path in Settings.
                  //
                  // Track C4.7 fixed-height slot: verified — no conditional
                  // strip remains above the nav bar (C3 moved unpair into
                  // Settings; onboarding is a Positioned.fill overlay), so
                  // pair/unpair never shifts the NavigationBar and no
                  // fixed-height slot is needed. Skipped with this note.
                  //
                  // Track C1: M3 NavigationBar (not M2 BottomNavigationBar).
                  // 5 destinations + labels + behavior identical; styling
                  // (8px indicator, primary/ink colors) comes from
                  // BuddyTheme.navigationBarTheme.
                  // Track C2: tooltips mirror labels for screen readers.
                  bottomNavigationBar: NavigationBar(
                    selectedIndex: _tab,
                    onDestinationSelected: _onTab,
                    labelBehavior:
                        NavigationDestinationLabelBehavior.alwaysShow,
                    destinations: const <NavigationDestination>[
                      NavigationDestination(
                        icon: Icon(Icons.link_outlined),
                        selectedIcon: Icon(Icons.link),
                        label: AppStrings.tabPair,
                        tooltip: AppStrings.tabPair,
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.chat_bubble_outline),
                        selectedIcon: Icon(Icons.chat_bubble),
                        label: AppStrings.tabChat,
                        tooltip: AppStrings.tabChat,
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.assignment_outlined),
                        selectedIcon: Icon(Icons.assignment),
                        label: AppStrings.tabTasks,
                        tooltip: AppStrings.tabTasks,
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.monitor_outlined),
                        selectedIcon: Icon(Icons.monitor),
                        label: AppStrings.tabScreen,
                        tooltip: AppStrings.tabScreen,
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.settings_outlined),
                        selectedIcon: Icon(Icons.settings),
                        label: AppStrings.tabSettings,
                        tooltip: AppStrings.tabSettings,
                      ),
                    ],
                  ),
                ),
                // Track C3 onboarding: once-only overlay after first pairing.
                if (_showOnboarding && _api != null)
                  Positioned.fill(
                    child: OnboardingOverlay(onDone: _onOnboardingDone),
                  ),
              ],
            ),
    );
  }
}
