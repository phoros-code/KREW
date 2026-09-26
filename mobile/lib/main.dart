import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'theme/buddy_theme.dart';

void main() {
  // Synchronous framework errors: surface through the reporter (debug
  // console / release log) instead of killing the process silently.
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
  };
  // Widget-build failures: a small token-styled box, never the default
  // grey/red "something broke" banner (Track A5.6). Plain TextStyle on
  // purpose — theme/font loading may be the thing that failed.
  ErrorWidget.builder = (FlutterErrorDetails details) {
    return Container(
      padding: const EdgeInsets.all(BuddySpacing.s4),
      decoration: BoxDecoration(
        border: Border.all(color: BuddyColors.error),
        borderRadius: const BorderRadius.all(
          Radius.circular(BuddyRadii.container),
        ),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline, size: 18, color: BuddyColors.error),
          SizedBox(width: BuddySpacing.s2),
          Expanded(
            child: Text(
              'Something went wrong showing this part — restart the app. Nothing was sent anywhere.',
              style: TextStyle(color: BuddyColors.error, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  };
  // Async errors outside Flutter's zone (no telemetry backend by design —
  // local-first, SECURITY.md): route them through the same reporter.
  runZonedGuarded(
    () => runApp(const BuddyApp()),
    (Object error, StackTrace stack) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack),
      );
    },
  );
}
