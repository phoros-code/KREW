import 'package:flutter/material.dart';

import '../services/buddy_api.dart';
import '../services/proximity_service.dart';
import '../theme/buddy_theme.dart';
import '../widgets/console_column.dart';
import '../widgets/screen_preview.dart';

/// Screen-preview tab: a consent-gated placeholder pointed at GET /screen.
/// The preview never auto-starts; [ScreenPreview] owns the consent flow and
/// the 501 / 403 / offline states.
class PreviewScreen extends StatelessWidget {
  const PreviewScreen({
    super.key,
    required this.api,
    required this.proximity,
  });

  final BuddyApi? api;
  final ProximityMode proximity;

  @override
  Widget build(BuildContext context) {
    return ConsoleColumn(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'Laptop screen',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: BuddySpacing.s2),
          Text(
            'Near-only, consent-gated live view. Nothing starts until you ask it to.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: BuddySpacing.s4),
          ScreenPreview(api: api, proximity: proximity),
        ],
      ),
    );
  }
}
