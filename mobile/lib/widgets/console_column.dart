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
    this.onRefresh,
    this.controller,
  });

  final Widget child;
  final Widget? bottomBar;

  /// Track C3 pull-to-refresh: when non-null the scrollable content region
  /// is wrapped in a [RefreshIndicator] (AlwaysScrollable physics so the
  /// gesture works even on short content). Screens pass the shell refresh
  /// (reconnect stream + refetch proximity config).
  final Future<void> Function()? onRefresh;

  /// Track C4: shared scroll controller seam. Passed to the
  /// [SingleChildScrollView] so virtualized screens (chat log, task detail)
  /// and plain columns share one controller pattern — follow/jump-to-newest
  /// listens on the same object the scroll view drives. Null keeps the
  /// previous behavior (an internal anonymous controller).
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color hairline = dark
        ? BuddyColors.hairlineOnDark
        : BuddyColors.hairlineOnLight;

    final Future<void> Function()? refresh = onRefresh;
    final Widget scroll = SingleChildScrollView(
      controller: controller,
      physics: refresh == null
          ? null
          : const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(BuddySpacing.s4),
      child: child,
    );
    return Column(
      children: <Widget>[
        Expanded(
          child: refresh == null
              ? scroll
              : RefreshIndicator(onRefresh: refresh, child: scroll),
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
