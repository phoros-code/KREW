import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../theme/buddy_theme.dart';

/// Track C3: first-run onboarding overlay. Shown once, after the first
/// pairing (never before — no laptop yet); the seen flag is persisted in
/// SecureStore by the shell.
///
/// Three pages: trust model (LAN-only + token + consent), proximity
/// (NEAR/FAR meaning), tabs tour. Skip + Get started both dismiss. Token
/// styling only (outlined icons in primary/muted, hairline box) — no
/// gradients, no emoji, console-column spacing.
class OnboardingOverlay extends StatefulWidget {
  const OnboardingOverlay({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<OnboardingOverlay> createState() => _OnboardingOverlayState();
}

class _OnboardingOverlayState extends State<OnboardingOverlay> {
  final PageController _pages = PageController();
  int _page = 0;

  static const List<({IconData icon, String title, String body})> _slides =
      <({IconData icon, String title, String body})>[
    (
      icon: Icons.verified_outlined,
      title: AppStrings.onboardingTrustTitle,
      body: AppStrings.onboardingTrustBody,
    ),
    (
      icon: Icons.radar_outlined,
      title: AppStrings.onboardingProximityTitle,
      body: AppStrings.onboardingProximityBody,
    ),
    (
      icon: Icons.view_column_outlined,
      title: AppStrings.onboardingTabsTitle,
      body: AppStrings.onboardingTabsBody,
    ),
  ];

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
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
    final bool last = _page == _slides.length - 1;

    return Semantics(
      label: 'Welcome to Everyday Buddy, page ${_page + 1} of ${_slides.length}',
      container: true,
      child: Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(BuddySpacing.s5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      tapTargetSize: MaterialTapTargetSize.padded,
                    ),
                    onPressed: widget.onDone,
                    child: const Text(AppStrings.onboardingSkip),
                  ),
                ),
                Expanded(
                  child: PageView.builder(
                    controller: _pages,
                    itemCount: _slides.length,
                    onPageChanged: (int i) => setState(() => _page = i),
                    itemBuilder: (BuildContext context, int i) {
                      final ({IconData icon, String title, String body}) slide =
                          _slides[i];
                      return Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[
                          Container(
                            padding: const EdgeInsets.all(BuddySpacing.s5),
                            decoration: BoxDecoration(
                              border: Border.all(color: hairline),
                              borderRadius: const BorderRadius.all(
                                Radius.circular(BuddyRadii.container),
                              ),
                            ),
                            child: ExcludeSemantics(
                              child: Icon(
                                slide.icon,
                                size: 40,
                                color: BuddyColors.primary,
                              ),
                            ),
                          ),
                          const SizedBox(height: BuddySpacing.s5),
                          Text(
                            slide.title,
                            style: Theme.of(context).textTheme.headlineSmall,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: BuddySpacing.s3),
                          Text(
                            slide.body,
                            style: Theme.of(context).textTheme.bodyMedium,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      );
                    },
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    for (int i = 0; i < _slides.length; i++)
                      Semantics(
                        label: 'Page ${i + 1} of ${_slides.length}',
                        selected: i == _page,
                        child: ExcludeSemantics(
                          child: Container(
                            width: 6,
                            height: 6,
                            margin: const EdgeInsets.symmetric(
                              horizontal: BuddySpacing.s1,
                            ),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i == _page
                                  ? BuddyColors.primary
                                  : muted.withValues(alpha: 0.4),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: BuddySpacing.s4),
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      tapTargetSize: MaterialTapTargetSize.padded,
                    ),
                    onPressed: last
                        ? widget.onDone
                        : () => _pages.nextPage(
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeOut,
                          ),
                    child: Text(
                      last
                          ? AppStrings.onboardingDone
                          : AppStrings.onboardingNext,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
