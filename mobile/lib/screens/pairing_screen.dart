import 'package:flutter/material.dart';

import '../services/buddy_api.dart';
import '../services/secure_store.dart';
import '../theme/buddy_theme.dart';
import '../widgets/console_column.dart';

/// Pairing screen: laptop IP + token entry, stored in [SecureStore].
///
/// States (all designed, per DESIGN.md hard rules):
/// - empty: no laptop paired yet (first run)
/// - form: entering credentials
/// - testing: validating against the server
/// - error: wrong token (401 {"error":{"code":...,"message":...}} shape),
///   unreachable host, or locked-out account — human text, never raw JSON.
class PairingScreen extends StatefulWidget {
  const PairingScreen({
    super.key,
    required this.store,
    required this.onPaired,
    this.initialHost,
    this.initialBtDeviceId,
  });

  final SecureStore store;
  final void Function(String host, String token) onPaired;
  final String? initialHost;

  /// Previously saved laptop Bluetooth id, if any (prefill only).
  final String? initialBtDeviceId;

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _hostController;
  late final TextEditingController _tokenController;
  late final TextEditingController _btController;
  bool _testing = false;
  bool _obscured = true;
  String? _errorMessage;
  String? _errorCode;

  @override
  void initState() {
    super.initState();
    _hostController = TextEditingController(text: widget.initialHost ?? '');
    _tokenController = TextEditingController();
    _btController = TextEditingController(text: widget.initialBtDeviceId ?? '');
  }

  @override
  void dispose() {
    _hostController.dispose();
    _tokenController.dispose();
    _btController.dispose();
    super.dispose();
  }

  String? _validateHost(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Enter the laptop IP shown by the pairing script.';
    }
    final parsed = BuddyApi.splitHostPort(value);
    if (parsed.host.isEmpty) return 'That host does not look valid.';
    return null;
  }

  String? _validateToken(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Enter the pairing token from the laptop.';
    }
    if (value.trim().length < 8) return 'That token looks too short.';
    return null;
  }

  Future<void> _testAndSave() async {
    if (!_formKey.currentState!.validate()) return;
    final String host = _hostController.text.trim();
    final String token = _tokenController.text.trim();
    setState(() {
      _testing = true;
      _errorMessage = null;
      _errorCode = null;
    });
    final BuddyApi probe = BuddyApi(host: host, token: token);
    try {
      await probe.validatePairing();
      await widget.store.savePairing(host: host, token: token);
      // Optional: blank clears the saved id and disables the BLE watch.
      await widget.store.saveBtDeviceId(_btController.text);
      if (!mounted) return;
      widget.onPaired(host, token);
    } on BuddyApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorCode = e.code;
        _errorMessage = _humanize(e);
      });
    } finally {
      probe.close();
      if (mounted) setState(() => _testing = false);
    }
  }

  /// Map the API.md error envelope to human pairing guidance.
  String _humanize(BuddyApiException e) {
    switch (e.code) {
      case 'unauthorized':
        return 'Wrong token — the laptop said "${e.message}". Check for a trailing space, or generate a fresh token on the laptop and try again.';
      case 'token_expired':
        return 'That token reached its age limit — the laptop said "${e.message}". Generate a fresh token on the laptop and pair again.';
      case 'locked_out':
        return 'Too many wrong attempts — the laptop is temporarily locked. Wait a few minutes, then try again.';
      case 'unreachable':
        return e.message;
      case 'forbidden':
        return 'The laptop only allows this from near proximity. Join the same Wi-Fi and try again.';
      default:
        return e.message;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color muted = dark
        ? BuddyColors.inkMutedOnDark
        : BuddyColors.inkMutedOnLight;
    final Color hairline = dark
        ? BuddyColors.hairlineOnDark
        : BuddyColors.hairlineOnLight;
    final TextStyle? small = Theme.of(context).textTheme.bodySmall;

    return ConsoleColumn(
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('Pair with your laptop', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: BuddySpacing.s2),
            Text(
              'This is the trust moment: pairing gives this phone full remote control of the laptop agent. Stay on the same Wi-Fi and confirm the laptop screen before you save.',
              style: small,
            ),
            const SizedBox(height: BuddySpacing.s5),

            // Empty state — shown above the form on first run.
            if (widget.initialHost == null)
              Container(
                padding: const EdgeInsets.all(BuddySpacing.s4),
                decoration: BoxDecoration(
                  border: Border.all(color: hairline),
                  borderRadius: const BorderRadius.all(
                    Radius.circular(BuddyRadii.container),
                  ),
                ),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.laptop_outlined, size: 20, color: muted),
                    const SizedBox(width: BuddySpacing.s3),
                    Expanded(
                      child: Text(
                        'No laptop yet. Run the pairing script on the laptop to get its IP and token, then enter them below.',
                        style: small,
                      ),
                    ),
                  ],
                ),
              ),
            if (widget.initialHost == null)
              const SizedBox(height: BuddySpacing.s5),

            Text('Laptop IP', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: BuddySpacing.s2),
            TextFormField(
              controller: _hostController,
              validator: _validateHost,
              keyboardType: TextInputType.text,
              autofillHints: const <String>[AutofillHints.url],
              decoration: const InputDecoration(
                hintText: '192.168.1.10',
                prefixIcon: Icon(Icons.lan_outlined, size: 18),
              ),
              style: BuddyTheme.mono(
                dark ? BuddyColors.inkOnDark : BuddyColors.inkOnLight,
                size: 13.5,
              ),
            ),
            const SizedBox(height: BuddySpacing.s4),
            Text('Pairing token', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: BuddySpacing.s2),
            TextFormField(
              controller: _tokenController,
              validator: _validateToken,
              obscureText: _obscured,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                hintText: 'paste the token from the laptop',
                prefixIcon: const Icon(Icons.key_outlined, size: 18),
                suffixIcon: IconButton(
                  tooltip: _obscured ? 'Show token' : 'Hide token',
                  icon: Icon(
                    _obscured ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                    size: 18,
                  ),
                  onPressed: () =>
                      setState(() => _obscured = !_obscured),
                ),
              ),
              style: BuddyTheme.mono(
                dark ? BuddyColors.inkOnDark : BuddyColors.inkOnLight,
                size: 13.5,
              ),
            ),
            const SizedBox(height: BuddySpacing.s2),
            Text(
              'Saved in secure storage (Keystore / Keychain), never in plain files. Port defaults to 8443 over HTTPS.',
              style: small,
            ),
            const SizedBox(height: BuddySpacing.s4),
            Text(
              'Laptop Bluetooth ID (optional)',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: BuddySpacing.s2),
            TextFormField(
              controller: _btController,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.text,
              decoration: const InputDecoration(
                hintText: 'AA:BB:CC:DD:EE:FF (Android) or UUID (iOS)',
                prefixIcon: Icon(Icons.bluetooth_outlined, size: 18),
              ),
              style: BuddyTheme.mono(
                dark ? BuddyColors.inkOnDark : BuddyColors.inkOnLight,
                size: 13.5,
              ),
            ),
            const SizedBox(height: BuddySpacing.s2),
            Text(
              'Enables the near/far indicator from Bluetooth signal strength. Leave blank to skip it — proximity then follows server responses only. Find the ID in the laptop OS Bluetooth settings; the laptop must stay discoverable or paired.',
              style: small,
            ),

            // Error state — human text for the 401/429/unreachable shapes.
            if (_errorMessage != null) ...<Widget>[
              const SizedBox(height: BuddySpacing.s4),
              Container(
                padding: const EdgeInsets.all(BuddySpacing.s4),
                decoration: BoxDecoration(
                  border: Border.all(color: BuddyColors.error),
                  borderRadius: const BorderRadius.all(
                    Radius.circular(BuddyRadii.container),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Icon(
                      Icons.error_outline,
                      size: 18,
                      color: BuddyColors.error,
                    ),
                    const SizedBox(width: BuddySpacing.s3),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'Pairing failed',
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  color: BuddyColors.error,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          const SizedBox(height: BuddySpacing.s1),
                          Text(_errorMessage!, style: small),
                          if (_errorCode != null) ...<Widget>[
                            const SizedBox(height: BuddySpacing.s2),
                            Text(
                              'code: $_errorCode',
                              style: BuddyTheme.mono(muted, size: 11),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: BuddySpacing.s5),
            SizedBox(
              height: BuddySpacing.s7,
              child: ElevatedButton(
                onPressed: _testing ? null : _testAndSave,
                child: _testing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Test connection and save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
