## 0.0.5

* **Android minimum lowered from API 28 to API 24 (Android 7.0)**, matching Flutter's default
  `minSdkVersion`. See "Android version differences" in `doc/advanced.md`.
* Flutter 3.50 support:
  * The example app moves to AGP 9.3.1, Gradle 9.5.0 and Kotlin 2.4.20. The old versions were
    below Flutter 3.50's hard minimums.
  * The plugin now applies the Kotlin Gradle Plugin only when AGP 9's built-in Kotlin is off.
    This clears Flutter's "plugins that apply KGP will fail" warning and keeps AGP 8 apps working.
* Android performance: Keystore key generation, key lookups, file I/O and the post-prompt
  sign/decrypt now run on `Dispatchers.IO` instead of the UI thread. RSA key generation on
  StrongBox could freeze the UI for seconds.
* Android: the identity-change check on every resume is skipped when nothing listens to
  `onIdentityChanged`, and no longer stacks on rapid resumes.
* Android fixes:
  * `PresencePromptConfig.biometricStrength` was ignored and is now honored. `weak` +
    `allowDeviceCredentials` now offers PIN/pattern fallback below API 30.
  * Concurrent `persistAcrossBackgrounding` calls no longer orphan each other.
  * A host activity that isn't a `FlutterFragmentActivity` now gets an explicit error message.
  * RSA-decrypted text is decoded explicitly as UTF-8.
  * The `onIdentityChanged` stream handler is cleared on engine detach.
* Android: replaced deprecated `lifecycle-common-java8` with `lifecycle-common`.

## 0.0.4

* **Breaking (native codegen only, not the Dart API):** regenerated Pigeon output now targets
  `suspend fun` (Kotlin) / `async throws` (Swift) instead of completion-handler style, matching
  the locked `pigeon: ^28.0.0`. The public Dart API (`LocalBiometric`) is unaffected.
* Implemented real `decryptPayload` on iOS/macOS (RSA-OAEP-SHA256 for RSA identities, ECIES for
  EC-only identities) -- previously always returned `IdentityError.unknown`/"Not implemented".
* `getIdentityStatus` on iOS/macOS now reports `algorithm`/`keySize`/`isHybridMode`/`publicKey`
  (previously only `exists` was ever populated); Android's `getIdentityStatus` now also reports
  `decryptingPublicKey`/`decryptingAlgorithm`/`decryptingKeySize` in `HYBRID_EC` mode.
* `onIdentityChanged` now actually emits `IdentityStatus.changed` on iOS/macOS when biometrics are
  re-enrolled (via `LAContext` domain-state comparison); previously it could only report
  `valid`/`unavailable` there. `acknowledgeIdentityChange` is no longer a no-op on iOS/macOS.
* Added `IdentityError.authenticationFailed` and `IdentityError.notInteractive` for finer-grained
  failure reporting (see the enum's doc comments in `pigeons/identity_messages.dart`).
* Added `IdentityEnrollmentConfig.requireAuthentication` -- when set to `false`, creates a key
  usable without any biometric/passcode gating ("device has the key" binding only). Read the doc
  comment before using this; it is a real security-model change, not a convenience default.
* Added `persistAcrossBackgrounding` to `PresencePromptConfig`, `IdentitySignatureConfig`,
  `IdentityDecryptConfig`, and `IdentityEnrollmentConfig` -- automatically retries the *entire*
  operation from scratch if the app is backgrounded mid-prompt, instead of failing with
  `systemCanceled`.
* Added `PresencePromptConfig.sensitiveTransaction` (Android only) -- forces explicit confirmation
  after a passive biometric match (e.g. passive Face Unlock).
* Added `LocalBiometric.stopAuthentication()` to cancel an in-flight prompt (not supported on
  Windows).
* Fixed Windows `SignPayloadBytes`/`DecryptPayload`, which were empty-body stubs that never
  resolved their Dart `Future`, hanging the caller forever. `SignPayload` now actually populates
  `signature`/`publicKey`/`algorithm` on success (previously it reported success with an empty
  result). **`DecryptPayload` on Windows now attempts real decryption via an undocumented,
  unsupported Windows API** (`NCrypt` against the Passport Key Storage Provider) -- see the
  Platform Support table in `README.md` and the warning in `CLAUDE.md` before relying on it; it may
  stop working after a future Windows update with no warning.
* Added `lib/src/identity_error_extensions.dart` (`IdentityErrorX` on `IdentityError`) with
  `isRecoverable`/`userMessage` helpers, exported from the main library.
* Loosened `meta`/`flutter_lints`/`pigeon` version constraints in `pubspec.yaml`.

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
