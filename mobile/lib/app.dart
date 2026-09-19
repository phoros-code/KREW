import 'dart:async';

import 'package:flutter/material.dart';

import 'models/buddy_event.dart';
import 'models/task_item.dart';
import 'screens/chat_screen.dart';
import 'screens/pairing_screen.dart';
import 'screens/preview_screen.dart';
import 'screens/task_list_screen.dart';
import 'services/buddy_api.dart';
import 'services/proximity_service.dart';
import 'services/secure_store.dart';
import 'theme/buddy_theme.dart';
import 'widgets/status_header.dart';

/// App shell: owns pairing state, the SSE subscription, the folded task
/// list, and proximity state. Every tab renders inside the console-column
/// primitive with the 56px [StatusHeader] always visible.
class BuddyApp extends StatefulWidget {
  const BuddyApp({super.key, SecureStore? store})
    : _storeOverride = store;

  final SecureStore? _storeOverride;

  @override
  State<BuddyApp> createState() => _BuddyAppState();
}

class _BuddyAppState extends State<BuddyApp> {
  late final SecureStore _store;
  final ProximityService _proximity = ProximityService();
  final TaskList _tasks = TaskList();
  final List<BuddyEvent> _events = <BuddyEvent>[];

  BuddyApi? _api;
  String? _savedHost;
  bool _booting = true;
  int _tab = 0;

  StreamSubscription<BuddyEvent>? _subscription;
  String? _streamError;
  bool _streamConnected = false;
  int _connectAttempt = 0;

  @override
  void initState() {
    super.initState();
    _store = widget._storeOverride ?? SecureStore();
    _proximity.addListener(_onProximityChanged);
    _boot();
  }

  void _onProximityChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _boot() async {
    final PairingInfo? saved = await _store.readPairing();
    if (!mounted) return;
    setState(() {
      _booting = false;
      if (saved != null) {
        _attachApi(saved.host, saved.token, initialTab: 1);
      }
    });
    if (saved != null) _connectEvents();
  }

  void _attachApi(String host, String token, {int? initialTab}) {
    _api?.close();
    _api = BuddyApi(host: host, token: token);
    _savedHost = host;
    _proximity.setUnknown();
    if (initialTab != null) _tab = initialTab;
  }

  void _onPaired(String host, String token) {
    setState(() {
      _attachApi(host, token);
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
  }

  Future<void> _onUnpair() async {
    await _store.clear();
    await _subscription?.cancel();
    _subscription = null;
    _api?.close();
    _api = null;
    if (!mounted) return;
    setState(() {
      _savedHost = null;
      _tab = 0;
      _events.clear();
      _tasks.clear();
      _streamError = null;
      _streamConnected = false;
    });
    _proximity.markFar();
    _proximity.setUnknown();
  }

  void _connectEvents() {
    _subscription?.cancel();
    _subscription = null;
    final BuddyApi? api = _api;
    if (api == null) return;
    _connectAttempt++;
    final int attempt = _connectAttempt;
    setState(() {
      _streamError = null;
      _streamConnected = false;
    });
    _proximity.setUnknown();
    _subscription = api.watchEvents().listen(
      (BuddyEvent event) {
        if (!mounted || attempt != _connectAttempt) return;
        setState(() {
          _streamConnected = true;
          _streamError = null;
          _events.insert(0, event);
          if (_events.length > 200) _events.removeLast();
          _tasks.applyEvent(event);
        });
        _proximity.setOnline();
      },
      onError: (Object err) {
        if (!mounted || attempt != _connectAttempt) return;
        final String message = err is BuddyApiException
            ? err.message
            : 'The live stream dropped. Reconnect to resume updates.';
        if (err is BuddyApiException && err.code == 'forbidden') {
          _proximity.markFar();
        }
        if (err is BuddyApiException && err.code == 'unreachable') {
          _proximity.setOffline();
        }
        setState(() {
          _streamConnected = false;
          _streamError = message;
        });
      },
      onDone: () {
        if (!mounted || attempt != _connectAttempt) return;
        setState(() {
          _streamConnected = false;
          _streamError ??= 'The live stream closed. Reconnect to resume.';
        });
      },
      cancelOnError: false,
    );
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
      final CommandResult result = await api.postCommand(text);
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
    _proximity.removeListener(_onProximityChanged);
    _proximity.dispose();
    _subscription?.cancel();
    _api?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Everyday Buddy',
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
              ),
              body: IndexedStack(
                index: _tab,
                children: <Widget>[
                  PairingScreen(
                    store: _store,
                    initialHost: _savedHost,
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
                  ),
                ],
              ),
              bottomNavigationBar: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (_api != null)
                    _UnpairStrip(savedHost: _savedHost, onUnpair: _onUnpair),
                  BottomNavigationBar(
                    currentIndex: _tab,
                    onTap: (int i) => setState(() => _tab = i),
                    items: const <BottomNavigationBarItem>[
                      BottomNavigationBarItem(
                        icon: Icon(Icons.link_outlined),
                        activeIcon: Icon(Icons.link),
                        label: 'Pair',
                      ),
                      BottomNavigationBarItem(
                        icon: Icon(Icons.chat_bubble_outline),
                        activeIcon: Icon(Icons.chat_bubble),
                        label: 'Chat',
                      ),
                      BottomNavigationBarItem(
                        icon: Icon(Icons.assignment_outlined),
                        activeIcon: Icon(Icons.assignment),
                        label: 'Tasks',
                      ),
                      BottomNavigationBarItem(
                        icon: Icon(Icons.monitor_outlined),
                        activeIcon: Icon(Icons.monitor),
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
