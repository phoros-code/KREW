# Everyday Buddy release R8 rules (Track D).
#
# The Flutter Gradle plugin already injects its own `flutter_proguard_rules.pro`
# (keeps FlutterPlugin implementations + the embedding) plus the default
# `proguard-android-optimize.txt` — so this file keeps ONLY what our four
# plugins need. Verified 2026-09-27 against the pub cache: NONE of the four
# ships `consumer-rules.pro` / `consumerProguardFiles`, so without these keeps
# R8 full-mode would strip their MethodChannel entry points.
#
# Plugin -> Android package (from android/src package statements):
#   flutter_secure_storage  -> com.it_nomads.fluttersecurestorage(.ciphers)
#   flutter_blue_plus       -> com.jmx.flutter_blue_plus   (federated: flutter_blue_plus_android)
#   permission_handler      -> com.baseflow.permissionhandler (federated: permission_handler_android)
#   package_info_plus       -> dev.fluttercommunity.plus.packageinfo

# flutter_secure_storage: MethodChannel plugin + AES cipher helpers.
-keep class com.it_nomads.fluttersecurestorage.** { *; }

# flutter_blue_plus: MethodChannel plugin + BLE scan/advertising callbacks
# invoked from Android framework classes (kept whole — reflection-adjacent).
-keep class com.jmx.flutter_blue_plus.** { *; }

# permission_handler: MethodChannel plugin + Activity-result permission callbacks.
-keep class com.baseflow.permissionhandler.** { *; }

# package_info_plus: MethodChannel plugin reading PackageManager info.
-keep class dev.fluttercommunity.plus.packageinfo.** { *; }
