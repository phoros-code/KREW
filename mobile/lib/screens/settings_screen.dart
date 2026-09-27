import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../l10n/strings.dart';
import '../services/buddy_api.dart';
import '../theme/buddy_theme.dart';
import '../widgets/console_column.dart';
import 'pairing_screen.dart' show curatedPairingMessage;

/// Track C3: Settings tab (5th destination). Console-column primitive,
/// DESIGN.md tokens only, no new hues.
///
/// Sections: Pairing status (host, paired-on, Test connection reusing
/// [BuddyApi.validatePairing]), Bluetooth device id (view + clear),
/// Proximity threshold (compact read + note — editing stays in the Screen
/// tab), Notifications (in-app toggle, persisted in SecureStore by the
/// shell), About (app version via package_info_plus, server /health line,
/// licenses link). Unpair lives here as a destructive row with the confirm
/// dialog (single unpair path — the old Pair-tab strip is gone).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.api,
    required this.host,
    required this.pairedOn,
    required this.btDeviceId,
    required this.threshold,
    required this.notificationsEnabled,
    required this.onNotificationsChanged,
    required this.onClearBt,
    required this.onUnpair,
  });

  final BuddyApi? api;
  final String? host;
  final String? pairedOn;
  final String? btDeviceId;
  final int threshold;
  final bool notificationsEnabled;
  final ValueChanged<bool> onNotificationsChanged;
  final VoidCallback onClearBt;
  final VoidCallback onUnpair;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _version = AppStrings.settingsVersionUnknown;
  String? _health;
  bool _testing = false;
  String? _testResult;
  bool? _testOk;

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _probeHealth();
  }

  Future<void> _loadVersion() async {
    try {
      final PackageInfo info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _version = '${info.version}+${info.buildNumber}';
      });
    } catch (_) {
      // Version stays "unknown" — a designed fallback, never a crash.
    }
  }

  Future<void> _probeHealth() async {
    final BuddyApi? api = widget.api;
    if (api == null) {
      if (mounted) setState(() => _health = null);
      return;
    }
    try {
      await api.checkHealth();
      if (!mounted) return;
      setState(() => _health = AppStrings.settingsServerOk);
    } on BuddyApiException {
      if (!mounted) return;
      setState(() => _health = AppStrings.settingsServerUnreachable);
    } catch (_) {
      if (!mounted) return;
      setState(() => _health = AppStrings.settingsServerUnreachable);
    }
  }

  Future<void> _testConnection() async {
    final BuddyApi? api = widget.api;
    if (api == null || _testing) return;
    setState(() {
      _testing = true;
      _testResult = null;
      _testOk = null;
    });
    try {
      await api.validatePairing();
      if (!mounted) return;
      setState(() {
        _testResult = AppStrings.settingsTestOk;
        _testOk = true;
      });
    } on BuddyApiException catch (e) {
      if (!mounted) return;
      setState(() {
        // Curated copy (Track C3) — same mapper as the pairing screen, so
        // raw server messages never render here either.
        _testResult = curatedPairingMessage(e);
        _testOk = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _testResult = AppStrings.settingsServerUnreachable;
        _testOk = false;
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _confirmUnpair() async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text(AppStrings.unpairTitle),
        content: const Text(AppStrings.unpairMessage),
        actions: <Widget>[
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              tapTargetSize: MaterialTapTargetSize.padded,
            ),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(AppStrings.actionCancel),
          ),
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              tapTargetSize: MaterialTapTargetSize.padded,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(AppStrings.actionUnpair),
          ),
        ],
      ),
    );
    if (confirm == true) widget.onUnpair();
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
    final Color successText = dark
        ? BuddyColors.successOnDark
        : BuddyColors.successOnLight;
    final TextStyle? small = Theme.of(context).textTheme.bodySmall;
    final bool paired = widget.api != null && widget.host != null;

    return ConsoleColumn(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            AppStrings.settingsTitle,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: BuddySpacing.s4),

          // Pairing status.
          const _SectionTitle(text: AppStrings.settingsPairingSection),
          _SectionBox(
            hairline: hairline,
            semanticLabel: paired
                ? 'Paired to ${widget.host}'
                : AppStrings.settingsNotPaired,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  paired ? widget.host! : AppStrings.settingsNotPaired,
                  style: BuddyTheme.mono(
                    dark ? BuddyColors.inkOnDark : BuddyColors.inkOnLight,
                    size: 13,
                  ),
                ),
                const SizedBox(height: BuddySpacing.s1),
                Text(
                  '${AppStrings.settingsPairedOn}: '
                  '${paired ? (widget.pairedOn ?? AppStrings.settingsPairedOnUnknown) : '—'}',
                  style: small,
                ),
                const SizedBox(height: BuddySpacing.s3),
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      tapTargetSize: MaterialTapTargetSize.padded,
                    ),
                    onPressed: paired && !_testing ? _testConnection : null,
                    child: _testing
                        ? Semantics(
                            label: AppStrings.settingsTesting,
                            child: const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : const Text(AppStrings.settingsTestButton),
                  ),
                ),
                if (_testResult != null) ...<Widget>[
                  const SizedBox(height: BuddySpacing.s2),
                  Semantics(
                    label: _testResult,
                    liveRegion: true,
                    child: Text(
                      _testResult!,
                      style: small?.copyWith(
                        color: _testOk == true ? successText : errorText,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: BuddySpacing.s4),

          // Bluetooth device id.
          const _SectionTitle(text: AppStrings.settingsBtSection),
          _SectionBox(
            hairline: hairline,
            semanticLabel:
                '${AppStrings.settingsBtSection}: ${widget.btDeviceId ?? AppStrings.settingsBtNotSet}',
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    widget.btDeviceId ?? AppStrings.settingsBtNotSet,
                    style: BuddyTheme.mono(
                      dark ? BuddyColors.inkOnDark : BuddyColors.inkOnLight,
                      size: 12.5,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: BuddySpacing.s2),
                TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    tapTargetSize: MaterialTapTargetSize.padded,
                  ),
                  onPressed: widget.btDeviceId == null ? null : widget.onClearBt,
                  child: const Text(AppStrings.settingsBtClear),
                ),
              ],
            ),
          ),
          const SizedBox(height: BuddySpacing.s4),

          // Proximity threshold (read-only here; editing in Screen tab).
          const _SectionTitle(text: AppStrings.settingsThresholdSection),
          _SectionBox(
            hairline: hairline,
            semanticLabel:
                '${AppStrings.settingsThresholdSection}: ${widget.threshold} dBm',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${widget.threshold} dBm',
                  style: BuddyTheme.mono(
                    dark ? BuddyColors.inkOnDark : BuddyColors.inkOnLight,
                    size: 16,
                  ),
                ),
                const SizedBox(height: BuddySpacing.s1),
                Text(AppStrings.settingsThresholdNote, style: small),
              ],
            ),
          ),
          const SizedBox(height: BuddySpacing.s4),

          // Notifications toggle.
          const _SectionTitle(text: AppStrings.settingsNotificationsSection),
          _SectionBox(
            hairline: hairline,
            semanticLabel: AppStrings.settingsNotificationsToggle,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        AppStrings.settingsNotificationsToggle,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                    Switch(
                      value: widget.notificationsEnabled,
                      onChanged: widget.onNotificationsChanged,
                    ),
                  ],
                ),
                Text(AppStrings.settingsNotificationsHint, style: small),
              ],
            ),
          ),
          const SizedBox(height: BuddySpacing.s4),

          // About.
          const _SectionTitle(text: AppStrings.settingsAboutSection),
          _SectionBox(
            hairline: hairline,
            semanticLabel: AppStrings.settingsAboutSection,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _AboutRow(
                  label: AppStrings.settingsAppVersion,
                  value: _version,
                  muted: muted,
                ),
                const SizedBox(height: BuddySpacing.s2),
                _AboutRow(
                  label: AppStrings.settingsServer,
                  value: _health ?? AppStrings.settingsServerUnreachable,
                  muted: muted,
                ),
                const SizedBox(height: BuddySpacing.s2),
                TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    tapTargetSize: MaterialTapTargetSize.padded,
                    padding: EdgeInsets.zero,
                  ),
                  onPressed: () => showLicensePage(context: context),
                  child: const Text(AppStrings.settingsLicenses),
                ),
              ],
            ),
          ),
          const SizedBox(height: BuddySpacing.s4),

          // Unpair (destructive — the single unpair path).
          const _SectionTitle(text: AppStrings.settingsUnpairSection),
          _SectionBox(
            hairline: hairline,
            semanticLabel: AppStrings.settingsUnpairSection,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  tapTargetSize: MaterialTapTargetSize.padded,
                  foregroundColor: errorText,
                  side: BorderSide(color: errorText),
                ),
                onPressed: paired ? _confirmUnpair : null,
                child: const Text(AppStrings.actionUnpair),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: BuddySpacing.s2),
      child: Text(text, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}

class _SectionBox extends StatelessWidget {
  const _SectionBox({
    required this.hairline,
    required this.child,
    this.semanticLabel,
  });

  final Color hairline;
  final Widget child;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final Widget box = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(BuddySpacing.s4),
      decoration: BoxDecoration(
        border: Border.all(color: hairline),
        borderRadius: const BorderRadius.all(
          Radius.circular(BuddyRadii.container),
        ),
      ),
      child: child,
    );
    final String? label = semanticLabel;
    if (label == null) return box;
    return Semantics(label: label, container: true, child: box);
  }
}

class _AboutRow extends StatelessWidget {
  const _AboutRow({required this.label, required this.value, required this.muted});

  final String label;
  final String value;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
        ),
        const SizedBox(width: BuddySpacing.s2),
        Flexible(
          child: Text(
            value,
            style: BuddyTheme.mono(muted, size: 12),
            textAlign: TextAlign.end,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
