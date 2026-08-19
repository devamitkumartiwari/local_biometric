# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`local_biometric` is a Flutter plugin for biometric authentication and hardware-backed cryptographic
identities. It has two feature surfaces:

- **Simple presence verification** (`verifyPresence`) — just confirms the user is present via
  biometrics/passcode, no keys involved.
- **Encrypted identity** (`enrollIdentity`, `signPayload`/`signPayloadBytes`, `decryptPayload`) — creates
  an RSA or ECDSA key pair inside secure hardware (iOS Secure Enclave / Android Keystore+StrongBox) and
  signs or decrypts data without ever exposing the private key to Dart or app code.

The Dart API is a thin wrapper (`lib/local_biometric.dart`) around a Pigeon-generated platform channel.
All real logic lives in the native platform implementations under `android/`, `ios/`, and `windows/`.
`macos/` has no native source of its own — it reuses the iOS Swift implementation directly (it compiles
against `LocalAuthentication`/Secure Enclave APIs that exist on both platforms). Both CocoaPods and
Swift Package Manager distribution are supported: `macos/local_biometric.podspec` points its
`source_files` at `../ios/local_biometric/Sources/local_biometric/**/*`, and
`macos/local_biometric/Package.swift` reaches the same sources via a tracked symlink
(`macos/local_biometric/Sources` → `../../ios/local_biometric/Sources`) — there is still only one copy
of the Swift source on disk; don't duplicate it when adding files, add them under
`ios/local_biometric/Sources/local_biometric/` and both distribution paths pick them up.

iOS/macOS deployment targets are iOS 16.0 / macOS 13.0 (set in both the podspecs and the
`Package.swift` manifests — keep them in sync if bumped again).

## Platform support status (important — don't assume parity)

- **Android** and **iOS** are the complete, maintained implementations.
- **macOS** shares the iOS Swift source, so it has the same feature set as iOS.
- **Windows** is a partial implementation using `Windows.Security.Credentials.KeyCredentialManager`.
  Several API methods are stubs that return a default/success value without doing real work:
  `SignPayloadBytes`, `DecryptPayload`, `GetIdentityStatus`, `VerifyPresence` (see
  `windows/LocalBiometricPlugin.cpp`). Don't assume a method that works on Android/iOS also works on
  Windows — check the stub list first.
- On iOS/macOS, `decryptPayload` is explicitly unimplemented (`LocalBiometricPlugin.swift`) and returns
  `IdentityError.unknown` with `"Not implemented"`.

## Architecture

### API surface generation (Pigeon)

`pigeons/identity_messages.dart` is the single source of truth for the entire cross-platform API: all
enums (`IdentityError`, `IdentityAuthType`, `IdentitySignatureType`, etc.), data classes
(`IdentityEnrollmentConfig`, `IdentitySignatureResult`, ...), and the `LocalBiometricApi` HostApi method
signatures. Editing this file and regenerating is the only correct way to change the plugin's public
contract — do not hand-edit the generated files.

Generated outputs (declared via `@ConfigurePigeon` at the top of the file):
- `lib/local_biometric_api.pigeon.dart` (Dart)
- `android/src/main/kotlin/com/amit/local_biometric/LocalBiometricApi.kt` (Kotlin)
- `ios/local_biometric/Sources/local_biometric/LocalBiometricApi.swift` (Swift)
- `windows/local_biometric_api.g.cpp` / `.g.h` (C++)

Regenerate after editing the pigeon file:
```bash
dart run pigeon --input pigeons/identity_messages.dart
```

After regenerating, the corresponding native `*Api` interface changes shape, so the hand-written
plugin classes (`LocalBiometricPlugin.kt`, `LocalBiometricPlugin.swift`,
`windows/LocalBiometricPlugin.cpp`) that implement it will need matching updates.

Pigeon's Dart output doesn't always match the locally installed Dart SDK's formatter conventions
(observed drift: collapsed short enums, trailing commas) — run `dart format lib/` after regenerating so
`pana`'s static-analysis score doesn't regress on formatting alone.

### Android (`android/src/main/kotlin/com/amit/local_biometric/`)

- `LocalBiometricPlugin.kt` — Pigeon `LocalBiometricApi` implementation; wires Flutter lifecycle
  (`FlutterPlugin`/`ActivityAware`) and dispatches to the classes below. Owns a
  `CoroutineScope(Dispatchers.Main + SupervisorJob())` for all async native calls.
- `LocalBiometricManager` — Android Keystore key lifecycle: generates RSA/EC key pairs
  (`KeyGenParameterSpec`), the AES "master key" used for hybrid EC decryption, deletes identities, and
  infers a key's `LocalKeyMode` (`RSA`, `EC_SIGN_ONLY`, `HYBRID_EC`) by inspecting the Keystore entry.
  Prefers StrongBox when the device supports it (`tryEnableStrongBox`).
- `LocalCryptographyProvider` — builds `Cipher`/`Signature` crypto objects for `BiometricPrompt`, and
  implements the hybrid-EC decrypt path (EC key wraps/unwraps an AES master key used for the actual
  payload decryption).
- `LocalBiometricAuthenticator` — wraps `androidx.biometric.BiometricPrompt` into a single
  suspend-style `authenticate(...)` call, and detects available biometric sensor types.
- `LocalBiometricErrorMapper` — maps platform exceptions/`BiometricManager` int codes to the shared
  `IdentityError` enum. Lockout codes are matched by raw int (`7`/`9`) rather than named constants
  because the meaning is stable across AndroidX biometric library versions where constant names
  have shifted.
- `LocalIdentityChangeMonitor` — `EventChannel.StreamHandler` + `LifecycleObserver` that detects when
  the device's enrolled biometrics change and emits `IdentityStatus` events on
  `com.amit.local_biometric/changes`.
- `LocalBiometricConstants` — key alias / filename naming scheme shared across the above.

Key generation always sets `setUserAuthenticationRequired(true)`; `EC_SIGN_ONLY` keys support signing
only, `HYBRID_EC` mode additionally has a wrapped AES master key on disk (`filesDir`) enabling
decryption via an EC-key-protected envelope, since Android Keystore EC keys can't do decryption
themselves. RSA keys can do decryption natively when `enableDecryption` is set.

### iOS/macOS (`ios/local_biometric/Sources/local_biometric/`)

- `LocalBiometricPlugin.swift` — Pigeon `LocalBiometricApi` implementation using `LocalAuthentication`
  (`LAContext`/`LAPolicy`) and Security framework (`SecKey*`). Lockout detection is done by matching
  raw `LAError` codes `-7`/`-8` in addition to the named `.biometryLockout`, because iOS has been
  observed returning undocumented codes for lockout in some contexts — see the inline comments before
  changing this logic.
- `LocalSecureIdentityStorage` — wraps Secure Enclave EC key creation/lookup/deletion
  (`kSecAttrTokenIDSecureEnclave`) and persists a wrapped RSA blob alongside it for hybrid mode.
- `LocalIdentityCryptoEngine` — key/signature formatting helpers (base64/pem/hex/raw).
- `LocalIdentityChangeMonitor` — `FlutterStreamHandler` for the same change-notification event channel
  as Android.

Because Secure Enclave only supports EC keys natively, RSA "identities" on iOS are actually implemented
as: generate an EC key in the Secure Enclave, generate a software RSA key pair, encrypt the RSA private
key with the EC public key (`eciesEncryptionStandardX963SHA256AESGCM`), and store the wrapped blob.
Signing/decrypting first unwraps the RSA key (itself gated by Secure Enclave biometric auth) then
operates with it in memory. This mirrors Android's `HYBRID_EC` concept but is the default/only path for
RSA on iOS, not an opt-in.

The plugin is UIScene-safe: `LAContext.evaluatePolicy` presents its own system biometric UI without the
plugin referencing `UIWindow`/`keyWindow`/`rootViewController`, so it works unchanged in apps supporting
multiple scenes. The example app demonstrates this (`UIApplicationSupportsMultipleScenes = true` in
`example/ios/Runner/Info.plist`, with `SceneDelegate.swift` wired up).

`LocalBiometricPlugin.swift` and `LocalIdentityChangeMonitor.swift` are genuinely shared between iOS and
macOS, so anything platform-specific in them must be `#if os(iOS) / #elseif os(macOS)` guarded: import
`Flutter` (iOS) vs `FlutterMacOS` (macOS), `registrar.messenger()` (a method on iOS) vs
`registrar.messenger` (a property on macOS), and `UIApplication.didBecomeActiveNotification` vs
`NSApplication.didBecomeActiveNotification`. These platform branches were only exercised for the first
time when SPM support was added (SPM's stricter per-target module resolution surfaced them as hard
compile errors) — actually build for macOS after touching either file, don't assume CocoaPods alone
proves it compiles.

### Error code mapping

`IdentityError` (defined once in the pigeon file) is the cross-platform contract. Every platform has
its own mapper translating native errors into this enum — when adding a new failure case, update the
enum in `pigeons/identity_messages.dart`, regenerate, then add matching cases in
`LocalBiometricErrorMapper.kt` (Android) and the inline `mapCFError`/`LAError` switches in
`LocalBiometricPlugin.swift` (iOS/macOS).

## Common commands

Run these from the repo root unless noted.

```bash
# Fetch dependencies
flutter pub get

# Regenerate the pigeon-generated platform channel code (after editing pigeons/identity_messages.dart)
dart run pigeon --input pigeons/identity_messages.dart

# Static analysis / lint (uses flutter_lints via analysis_options.yaml)
flutter analyze

# Run the example app's widget test
cd example && flutter test

# Run a single test file
cd example && flutter test test/widget_test.dart

# Run the on-device integration test (requires a connected device/simulator with biometrics
# for meaningful coverage — see Testing note below)
cd example && flutter test integration_test/plugin_integration_test.dart

# Launch the example app to manually exercise the plugin
cd example && flutter run
```

There is no automated test suite for the native plugin code itself (no Android/iOS unit tests in this
repo); verification is manual via the example app on a physical device.

## Testing note (biometric hardware limitation)

Biometric authentication and secure hardware (Secure Enclave/StrongBox) cannot be fully exercised on
simulators/emulators. Changes to native crypto/auth code should ideally be validated on a physical
device with biometrics enrolled. When that isn't possible, at minimum verify the Dart-side analyzer/
widget tests pass and reason carefully about the native code change instead of assuming simulator
output reflects real device behavior.

## Example app (`example/`)

`example/lib/pages/` has three pages demonstrating the plugin's three usage areas —
`simple_auth_page.dart` (presence-only), `encrypted_auth_page.dart` (enroll/sign/decrypt), and
`management_page.dart` (identity status/revocation) — plus `home_page.dart` as the entry point. This is
the primary place to manually validate behavior changes, since there's no native unit test harness.
