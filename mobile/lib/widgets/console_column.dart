import 'package:flutter/material.dart';

import '../theme/buddy_theme.dart';

/// The "console column" layout primitive (DESIGN.md): every screen is a
/// single column — the 56px [StatusHeader] lives in the app shell, this
/// widget provides the scrollable content region plus an optional fixed
/// bottom bar (the command bar on input screens).
///
/// Screens differ by what is in the content region, never by layout shape.
/// No sidebars, no card grids.
class ConsoleColumn extends StatelessWidget {
  const ConsoleColumn({
    super.key,
    required this.child,
    this.bottomBar,
  });

  final Widget child;
  final Widget? bottomBar;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color hairline = dark
        ? BuddyColors.hairlineOnDark
        : BuddyColors.hairlineOnLight;

    return Column(
      children: <Widget>[
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(BuddySpacing.s4),
            child: child,
          ),
        ),
        if (bottomBar != null)
          Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: hairline)),
            ),
            padding: const EdgeInsets.all(BuddySpacing.s4),
            child: SafeArea(top: false, child: bottomBar!),
          ),
      ],
    );
  }
}
