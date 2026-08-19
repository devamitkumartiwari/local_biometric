## 0.0.3

* Raised iOS/macOS deployment targets to iOS 16.0 / macOS 13.0 and bumped Swift to 6.0.
* Added Swift Package Manager support (`Package.swift` for iOS and macOS) alongside the existing
  CocoaPods podspecs.
* Fixed a macOS build bug in the shared iOS/macOS Swift source: platform-conditional imports
  (`Flutter`/`UIKit` vs `FlutterMacOS`) and `FlutterPluginRegistrar.messenger` (method on iOS,
  property on macOS) were previously iOS-only and did not compile for macOS.
* Verified and documented the plugin's UIScene safety; example app now supports multiple scenes.
* Bumped `androidx.biometric` and `kotlinx-coroutines-android` to their latest available versions.
* Bumped `meta` to `^1.19.0`.
* Moved `pigeon` from `dependencies` to `dev_dependencies` (it's a codegen-only tool, never imported
  at runtime).

## 0.0.2

* Enhanced biometric lockout handling for both iOS and Android.
* Added support for distinguishing between temporary (30s) and permanent lockouts on Android.
* Implemented proactive lockout detection that alerts users immediately on page load.
* Added a unified "Unlock with Passcode" recovery flow for both simple and encrypted authentication.
* Refined native iOS mapping for biometric lockout codes (-7 and -8).
* Fixed UI overflow issues in the example app and improved status reporting.
* Improved Android build configuration with unified JVM targets and modern Kotlin DSL.

## 0.0.1

* Initial release of `local_biometric`.
* Added support for Simple Biometric Authentication (`verifyPresence`).
* Added support for Encrypted Biometric Authentication with RSA/ECDSA signatures.
* Added multi-page example app.
* Standardized error codes across platforms.
