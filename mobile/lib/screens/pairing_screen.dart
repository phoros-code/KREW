import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../services/buddy_api.dart';
import '../services/secure_store.dart';
import '../theme/buddy_theme.dart';
import '../widgets/console_column.dart';

/// Curated pairing error copy (Track C3): maps the API.md error envelope to
/// human guidance. Pure — unit tested.
///
/// Curated copy only — the raw server message/code NEVER renders inline.
/// The code is available behind the "Details" expander; raw JSON never
/// reaches the UI. `unreachable` passes through untouched because the
/// BuddyApi envelopes are already curated (route vs cert).
String curatedPairingMessage(BuddyApiException e) {
  switch (e.code) {
    case 'unauthorized':
      return AppStrings.pairErrorUnauthorized;
    case 'token_expired':
      return AppStrings.pairErrorTokenExpired;
    case 'locked_out':
      return AppStrings.pairErrorLockedOut;
    case 'unreachable':
      return e.message;
    case 'forbidden':
      return AppStrings.pairErrorForbidden;
    default:
      return AppStrings.pairErrorGeneric;
  }
}

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

  /// Track C3: raw server codes stay hidden until the user opens Details.
  bool _showDetails = false;

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
      return AppStrings.pairHostEmpty;
    }
    // Same strict gate the client constructs with (Track A5.7): userinfo,
    // spaces, #/? remnants, and out-of-range ports fail here with form
    // copy instead of a transport error.
    if (!BuddyApi.isValidHost(value)) {
      return AppStrings.pairHostInvalid;
    }
    return null;
  }

  String? _validateToken(String? value) {
    if (value == null || value.trim().isEmpty) {
      return AppStrings.pairTokenEmpty;
    }
    if (value.trim().length < 8) return AppStrings.pairTokenShort;
    return null;
  }

  String? _validateFingerprint(String? value) {
    if (value == null || value.trim().isEmpty) {
      return AppStrings.pairFingerprintEmpty;
    }
    if (!BuddyApi.isValidFingerprint(value)) {
      return AppStrings.pairFingerprintInvalid;
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
      _showDetails = false;
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

  /// Map the API.md error envelope to curated human pairing guidance
  /// (Track C3): curated copy only — the raw server message/code NEVER
  /// renders inline. The code is available behind the "Details" expander;
  /// raw JSON never reaches the UI. Delegates to [curatedPairingMessage].
  String _humanize(BuddyApiException e) => curatedPairingMessage(e);

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
            Text(AppStrings.pairTitle, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: BuddySpacing.s2),
            Text(
              AppStrings.pairSubtitle,
              style: small,
            ),
            const SizedBox(height: BuddySpacing.s5),

            // Empty state — shown above the form on first run.
            if (widget.initialHost == null)
              Semantics(
                label: AppStrings.pairEmptyMessage,
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
                          AppStrings.pairEmptyMessage,
                          style: small,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (widget.initialHost == null)
              const SizedBox(height: BuddySpacing.s5),

            Text(AppStrings.pairHostLabel, style: Theme.of(context).textTheme.labelLarge),
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
                hintText: AppStrings.pairHostHint,
                prefixIcon: Icon(Icons.lan_outlined, size: 18),
              ),
              style: BuddyTheme.mono(
                dark ? BuddyColors.inkOnDark : BuddyColors.inkOnLight,
                size: 13.5,
              ),
            ),
            const SizedBox(height: BuddySpacing.s4),
            Text(AppStrings.pairTokenLabel, style: Theme.of(context).textTheme.labelLarge),
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
                hintText: AppStrings.pairTokenHint,
                prefixIcon: const Icon(Icons.key_outlined, size: 18),
                suffixIcon: IconButton(
                  tooltip: _obscured ? AppStrings.pairShowToken : AppStrings.pairHideToken,
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
              AppStrings.pairTokenNote,
              style: small,
            ),
            const SizedBox(height: BuddySpacing.s4),
            Text(
              AppStrings.pairFingerprintLabel,
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
                hintText: AppStrings.pairFingerprintHint,
                prefixIcon: Icon(Icons.verified_outlined, size: 18),
              ),
              style: BuddyTheme.mono(
                dark ? BuddyColors.inkOnDark : BuddyColors.inkOnLight,
                size: 13.5,
              ),
            ),
            const SizedBox(height: BuddySpacing.s2),
            Text(
              AppStrings.pairFingerprintNote,
              style: small,
            ),
            const SizedBox(height: BuddySpacing.s4),
            Text(
              AppStrings.pairBtLabel,
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
                hintText: AppStrings.pairBtHint,
                prefixIcon: Icon(Icons.bluetooth_outlined, size: 18),
              ),
              style: BuddyTheme.mono(
                dark ? BuddyColors.inkOnDark : BuddyColors.inkOnLight,
                size: 13.5,
              ),
            ),
            const SizedBox(height: BuddySpacing.s2),
            Text(
              AppStrings.pairBtNote,
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
                                AppStrings.pairFailedTitle,
                                style: Theme.of(context).textTheme.labelLarge
                                    ?.copyWith(
                                      color: errorText,
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                              const SizedBox(height: BuddySpacing.s1),
                              Text(_errorMessage!, style: small),
                              if (_errorCode != null) ...<Widget>[
                                TextButton(
                                  style: TextButton.styleFrom(
                                    minimumSize: const Size(48, 48),
                                    tapTargetSize:
                                        MaterialTapTargetSize.padded,
                                    padding: EdgeInsets.zero,
                                  ),
                                  onPressed: () => setState(
                                    () => _showDetails = !_showDetails,
                                  ),
                                  child: const Text(
                                    AppStrings.pairDetailsLabel,
                                  ),
                                ),
                                if (_showDetails)
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
                        label: AppStrings.pairTestingLabel,
                        child: const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                      )
                    : const Text(AppStrings.pairSaveButton),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
