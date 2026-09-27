// Everyday Buddy — Android app module build config (Track D).
//
// RELEASE SIGNING: wired to `android/key.properties` (never committed — see
// .gitignore). Generate once per release machine, OUTSIDE the repo:
//
//   keytool -genkeypair -v `
//     -keystore C:\secure\everyday-buddy-release.keystore `
//     -alias everyday-buddy -keyalg RSA -keysize 2048 -validity 10000
//
// then copy `android/key.properties.example` to `android/key.properties` and
// fill in storeFile (absolute path with forward slashes, or relative to the
// `android/` folder), storePassword, keyAlias, keyPassword. When
// key.properties is ABSENT the release build falls back to the debug signing
// config so CI and local `flutter build apk --release` still work — but that
// APK is NEVER shippable.

import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Load release-signing secrets (stays empty when key.properties is absent).
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

android {
    namespace = "com.everydaybuddy"
    // Pinned explicitly (Track D) instead of the flutter.* SDK defaults, so an
    // SDK upgrade is a deliberate diff. Values match the Flutter 3.47.5
    // defaults (min 24 / target 36 / compile 36) — behavior is unchanged.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.everydaybuddy"
        // minSdk 24: BLE scan/connect permission model needs API 31+ paths
        // guarded at runtime; legacy Bluetooth caps are kept to maxSdk 30.
        minSdk = 24
        targetSdk = 36
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                // Resolved against android/ so both absolute and android/-relative paths work.
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig =
                if (keystorePropertiesFile.exists()) {
                    signingConfigs.getByName("release")
                } else {
                    // CI / local dev without key.properties: debug keys, NOT shippable.
                    signingConfigs.getByName("debug")
                }
            // R8 full mode (Track D): minify + resource shrink.
            isMinifyEnabled = true
            isShrinkResources = true
            // The Flutter Gradle plugin auto-adds its own
            // flutter_proguard_rules.pro plus the default Android rules;
            // proguard-rules.pro only adds OUR plugins' keeps.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    // ABI STRATEGY (Track D): owned by the Flutter Gradle plugin, NOT hand-written.
    // `flutter build apk --release --split-per-abi` passes -Psplit-per-abi and
    // the plugin configures splits.abi { isEnable=true; reset();
    // isUniversalApk=false } + per-arch includes itself; without the flag it
    // sets ndk.abiFilters instead. A hand-written splits { abi { ... } } block
    // here BREAKS project configuration (AGP: ndk abiFilters cannot be present
    // when splits abi filters are set — verified 2026-09-27), so per-ABI
    // output is requested via the build flag, never via this file.
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
