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
    this.initialCertFingerprint,
  });

  final SecureStore store;
  final void Function(String host, String token, String certFingerprint) onPaired;
  final String? initialHost;

  /// Previously saved laptop Bluetooth id, if any (prefill only).
  final String? initialBtDeviceId;

  /// Previously saved cert fingerprint, if any (prefill only).
  final String? initialCertFingerprint;

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _hostController;
  late final TextEditingController _tokenController;
  late final TextEditingController _btController;
  late final TextEditingController _fpController;
  bool _testing = false;
  bool _obscured = true;
  String? _errorMessage;
  String? _errorCode;

  /// Track C2: focus traversal for the pairing form + error-card focus.
  final FocusNode _hostFocus = FocusNode();
  final FocusNode _tokenFocus = FocusNode();
  final FocusNode _fpFocus = FocusNode();
  final FocusNode _btFocus = FocusNode();
  final FocusNode _errorFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _hostController = TextEditingController(text: widget.initialHost ?? '');
    _tokenController = TextEditingController();
    _btController = TextEditingController(text: widget.initialBtDeviceId ?? '');
    _fpController = TextEditingController(text: widget.initialCertFingerprint ?? '');
  }

  @override
  void didUpdateWidget(PairingScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Boot/bt-id restore lands after first build (Track A5.12): resync the
    // prefill controllers when the incoming props change. Only adopts the
    // new prop when it differs — never fights active typing, since a prop
    // change means the shell restored something newer.
    if (oldWidget.initialHost != widget.initialHost &&
        _hostController.text != (widget.initialHost ?? '')) {
      _hostController.text = widget.initialHost ?? '';
    }
    if (oldWidget.initialBtDeviceId != widget.initialBtDeviceId &&
        _btController.text != (widget.initialBtDeviceId ?? '')) {
      _btController.text = widget.initialBtDeviceId ?? '';
    }
    if (oldWidget.initialCertFingerprint != widget.initialCertFingerprint &&
        _fpController.text != (widget.initialCertFingerprint ?? '')) {
      _fpController.text = widget.initialCertFingerprint ?? '';
    }
  }

  @override
  void dispose() {
    _hostController.dispose();
    _tokenController.dispose();
    _btController.dispose();
    _fpController.dispose();
    _hostFocus.dispose();
    _tokenFocus.dispose();
    _fpFocus.dispose();
    _btFocus.dispose();
    _errorFocus.dispose();
    super.dispose();
  }

  String? _validateHost(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Enter the laptop IP shown by the pairing script.';
    }
    // Same strict gate the client constructs with (Track A5.7): userinfo,
    // spaces, #/? remnants, and out-of-range ports fail here with form
    // copy instead of a transport error.
    if (!BuddyApi.isValidHost(value)) {
      return 'That host does not look valid — use an IP or hostname, with an optional :port.';
    }
    return null;
  }

  String? _validateToken(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Enter the pairing token from the laptop.';
    }
    if (value.trim().length < 8) return 'That token looks too short.';
    return null;
  }

  String? _validateFingerprint(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Paste the cert fingerprint from the laptop pairing script.';
    }
    if (!BuddyApi.isValidFingerprint(value)) {
      return 'That does not look like a SHA-256 fingerprint (64 hex chars).';
    }
    return null;
  }

  Future<void> _testAndSave() async {
    if (!_formKey.currentState!.validate()) return;
    final String host = _hostController.text.trim();
    final String token = _tokenController.text.trim();
    final String fingerprint = _fpController.text.trim();
    setState(() {
      _testing = true;
      _errorMessage = null;
      _errorCode = null;
    });
    BuddyApi? probe;
    try {
      // Construction validates the host (Track A5.7) — inside the try so a
      // garbage host that slipped past validation still lands in the error
      // state instead of escaping uncaught (the old spinner-stop bug shape).
      probe = BuddyApi(host: host, token: token, certFingerprint: fingerprint);
      await probe.validatePairing();
      await widget.store.savePairing(host: host, token: token);
      await widget.store.saveCertFingerprint(fingerprint);
      // Optional: blank clears the saved id and disables the BLE watch.
      await widget.store.saveBtDeviceId(_btController.text);
      if (!mounted) return;
      widget.onPaired(host, token, fingerprint);
    } on BuddyApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorCode = e.code;
        _errorMessage = _humanize(e);
      });
      // Track C2: move focus to the error card when it appears.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _errorFocus.requestFocus();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorCode = 'unreachable';
        _errorMessage = BuddyApi.routeError.message;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _errorFocus.requestFocus();
      });
    } finally {
      probe?.close();
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
    final Color errorText = dark
        ? BuddyColors.errorOnDark
        : BuddyColors.errorOnLight;
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
              Semantics(
                label:
                    'No laptop yet. Run the pairing script on the laptop to get its IP and token, then enter them below.',
                container: true,
                child: Container(
                  padding: const EdgeInsets.all(BuddySpacing.s4),
                  decoration: BoxDecoration(
                    border: Border.all(color: hairline),
                    borderRadius: const BorderRadius.all(
                      Radius.circular(BuddyRadii.container),
                    ),
                  ),
                  child: Row(
                    children: <Widget>[
                      ExcludeSemantics(
                        child: Icon(
                          Icons.laptop_outlined,
                          size: 20,
                          color: muted,
                        ),
                      ),
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
              ),
            if (widget.initialHost == null)
              const SizedBox(height: BuddySpacing.s5),

            Text('Laptop IP', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: BuddySpacing.s2),
            TextFormField(
              controller: _hostController,
              focusNode: _hostFocus,
              validator: _validateHost,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.next,
              onFieldSubmitted: (_) => _tokenFocus.requestFocus(),
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
              focusNode: _tokenFocus,
              validator: _validateToken,
              obscureText: _obscured,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.next,
              onFieldSubmitted: (_) => _fpFocus.requestFocus(),
              decoration: InputDecoration(
                hintText: 'paste the token from the laptop',
                prefixIcon: const Icon(Icons.key_outlined, size: 18),
                suffixIcon: IconButton(
                  tooltip: _obscured ? 'Show token' : 'Hide token',
                  style: IconButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    tapTargetSize: MaterialTapTargetSize.padded,
                  ),
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
              'Laptop cert fingerprint (SHA-256)',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: BuddySpacing.s2),
            TextFormField(
              controller: _fpController,
              focusNode: _fpFocus,
              validator: _validateFingerprint,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.next,
              onFieldSubmitted: (_) => _btFocus.requestFocus(),
              decoration: const InputDecoration(
                hintText: '6c9caeac… (Cert SHA256 from pair_device.py)',
                prefixIcon: Icon(Icons.verified_outlined, size: 18),
              ),
              style: BuddyTheme.mono(
                dark ? BuddyColors.inkOnDark : BuddyColors.inkOnLight,
                size: 13.5,
              ),
            ),
            const SizedBox(height: BuddySpacing.s2),
            Text(
              'The app trusts exactly this certificate and nothing else. Copy it from the laptop pairing script output — colons and spaces are fine.',
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
              focusNode: _btFocus,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) {
                if (!_testing) _testAndSave();
              },
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
              Focus(
                focusNode: _errorFocus,
                child: Semantics(
                  label: 'Pairing failed: $_errorMessage',
                  container: true,
                  child: Container(
                    padding: const EdgeInsets.all(BuddySpacing.s4),
                    decoration: BoxDecoration(
                      border: Border.all(color: errorText),
                      borderRadius: const BorderRadius.all(
                        Radius.circular(BuddyRadii.container),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        ExcludeSemantics(
                          child: Icon(
                            Icons.error_outline,
                            size: 18,
                            color: errorText,
                          ),
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
                                      color: errorText,
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
                ),
              ),
            ],

            const SizedBox(height: BuddySpacing.s5),
            // Track C2: ConstrainedBox(minHeight:48) instead of a fixed
            // 48px box — grows with text scaling, never below the tap target.
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  tapTargetSize: MaterialTapTargetSize.padded,
                ),
                onPressed: _testing ? null : _testAndSave,
                child: _testing
                    ? Semantics(
                        label: 'Testing connection, please wait',
                        child: const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
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
