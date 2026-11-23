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

- **Android** and **iOS** are the complete, maintained implementations, including real
  `decryptPayload` and `onIdentityChanged`-detected biometric re-enrollment on both.
- **macOS** shares the iOS Swift source, so it has the same feature set as iOS.
- **Windows** is a partial implementation using `Windows.Security.Credentials.KeyCredentialManager`
  for enroll/sign. `GetIdentityStatus`, `VerifyPresence`, `RevokeIdentity`, `RevokeAllIdentities`,
  `IsDeviceSecure`, and `AcknowledgeIdentityChange` are still stubs that return a default/success
  value without doing real work (see `windows/LocalBiometricPlugin.cpp`) — don't assume a method
  that works on Android/iOS also works on Windows here.
- **`DecryptPayload` on Windows relies on an unsupported, undocumented Windows API** —
  `KeyCredentialManager` is sign-only by design, so decryption goes through the lower-level CNG
  `NCrypt` API directly against the "Microsoft Passport Key Storage Provider"
  (`windows/LocalNCryptDecryptor.cpp`), which requires setting an undocumented property
  (`NgcCacheType`) to arm the Windows Hello prompt. There is no official Microsoft API reference
  for this usage — the only precedent is third-party reverse engineering of `KeyCredentialManager`
  itself, and Microsoft's own stated guidance is to use `KeyCredentialManager` instead (which can't
  decrypt at all). This can behave inconsistently across Windows builds and may stop working
  entirely after a future Windows update with no changelog entry to warn you — do not treat it as
  equivalent in reliability to the Android/iOS decrypt paths. `SignPayloadBytes` is a real
  implementation (not a stub) sharing `SignPayload`'s `KeyCredentialManager` code path.
- `requireAuthentication: false`, `persistAcrossBackgrounding`, and `sensitiveTransaction` are all
  no-ops on Windows (documented inline in `LocalBiometricPlugin.cpp`'s `StopAuthentication`, which
  is itself unsupported there — `KeyCredentialManager`/the NCrypt path expose no cancellation
  handle).

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

**Kotlin/Swift codegen style**: this plugin is pinned to `pigeon: ^28.0.0`, which changed the
default Kotlin/Swift generators to emit `suspend fun`/`async throws` for every `@async`-annotated
`HostApi` method (older Pigeon versions emitted completion-handler/`callback` style). All
`LocalBiometricApi` methods use plain `@async` and are implemented as `suspend fun`
(`LocalBiometricPlugin.kt`) / `async throws` (`LocalBiometricPlugin.swift`) accordingly — do not
add `@asyncCallback` to revert an individual method to callback style without a good reason, since
that would make it inconsistent with every other method's calling convention. The C++ (Windows)
generator has no such distinction; it always emits `std::function<void(ErrorOr<T>)>` callbacks
regardless of the annotation, so `windows/LocalBiometricPlugin.cpp` is unaffected either way.

Every generated method still follows the plugin's own convention of reporting recoverable failures
*in-band* via the `code`/`error` fields on the returned result object, not by throwing — a thrown
Kotlin/Swift error from a `HostApi` method is reserved for truly exceptional plugin-internal
failures, not routine things like a locked-out sensor or a canceled prompt.

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
  payload decryption). Also exposes `getDecryptingPublicKey` (reads the persisted ephemeral EC public
  key file, no biometric prompt needed) so `getIdentityStatus` can report `decryptingPublicKey`/
  `decryptingAlgorithm`/`decryptingKeySize` in `HYBRID_EC` mode.
- `LocalBiometricAuthenticator` — wraps `androidx.biometric.BiometricPrompt` into a single
  suspend-style `authenticate(...)` call, and detects available biometric sensor types. Tracks the
  in-flight `BiometricPrompt`/continuation so `stopAuthentication()` can cancel it, and supports
  `sensitiveTransaction` (`setConfirmationRequired`).
- `LocalBiometricErrorMapper` — maps platform exceptions/`BiometricManager` int codes to the shared
  `IdentityError` enum. Lockout codes are matched by raw int (`7`/`9`) rather than named constants
  because the meaning is stable across AndroidX biometric library versions where constant names
  have shifted.
- `LocalIdentityChangeMonitor` — `EventChannel.StreamHandler` + `LifecycleObserver` that detects when
  the device's enrolled biometrics change and emits `IdentityStatus` events on
  `com.amit.local_biometric/changes`.
- `LocalPendingAuthRetryObserver` — separate, single-purpose `LifecycleObserver` backing
  `persistAcrossBackgrounding` (kept apart from `LocalIdentityChangeMonitor`, which has its own,
  unrelated lifecycle-driven job). On `onResume`, unblocks any call parked awaiting the app returning
  to foreground so it can retry from scratch.
- `LocalBiometricConstants` — key alias / filename naming scheme shared across the above.

**Android minSdk is 24** (Flutter's own default; androidx.biometric's floor is 23). Every API above
24 must stay behind a `Build.VERSION.SDK_INT` check: StrongBox (28), `setUserAuthenticationParameters`
and `STRONG | DEVICE_CREDENTIAL` (30). Run `./gradlew :local_biometric:lintDebug` from
`example/android` and keep `NewApi` at zero. Keep `appcompat`: the
`Theme_AppCompat` set in `LocalBiometricAuthenticator.authenticate` is what lets androidx's
fingerprint dialog render on API 24–27.

**Threading:** Pigeon dispatches every `LocalBiometricApi` method on `Dispatchers.Main`. Keystore
key generation and lookups, file I/O, and the post-prompt `sign()`/`doFinal()` go through the
plugin's `io { }` helper (`Dispatchers.IO`). Only `authenticator.authenticate()` (BiometricPrompt)
stays on Main.

**Gradle/Kotlin:** `android/build.gradle.kts` applies the Kotlin Gradle Plugin only when AGP 9's
built-in Kotlin is inactive (AGP < 9, or the app sets `android.builtInKotlin=false`). Configure
Kotlin through `tasks.withType<KotlinCompile>`, not the `kotlin {}` accessor, so both modes keep
compiling.

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
  (`kSecAttrTokenIDSecureEnclave`) and persists a wrapped RSA blob alongside it for hybrid mode. Also
  persists the RSA public key's SPKI bytes separately (`saveRsaPublicKeySpki`/`getRsaPublicKeySpki`)
  so `getIdentityStatus` can report it without unwrapping the private key (which would require a
  biometric prompt), and persists an `LAContext.evaluatedPolicyDomainState` snapshot
  (`saveDomainState`/`getDomainState`) used by `LocalIdentityChangeMonitor` to detect biometric
  re-enrollment.
- `LocalIdentityCryptoEngine` — key/signature formatting helpers (base64/pem/hex/raw), plus
  `decodePayload` for parsing incoming ciphertext (`decryptPayload`).
- `LocalIdentityChangeMonitor` — `FlutterStreamHandler` for the same change-notification event channel
  as Android. Unlike a hardware-invalidation probe (which iOS has no cheap equivalent of), this
  compares the current `LAContext.evaluatedPolicyDomainState` against the baseline saved at
  enrollment and emits `.changed` on a mismatch, sticky until `acknowledgeIdentityChange` clears it —
  tracks only the default alias (a known limitation shared with Android's own multi-alias handling).
- `LocalPendingAuthRetryWaiter` — backs `persistAcrossBackgrounding`; awaits
  `UIApplication`/`NSApplication` `didBecomeActiveNotification` so an interrupted prompt-issuing call
  can retry itself from scratch on foreground. Mirrors `LocalPendingAuthRetryObserver.kt` on Android.

`decryptPayload` is fully implemented: RSA identities unwrap the ECIES-wrapped software RSA key (the
same way `signPayload`'s RSA path does) then decrypt with RSA-OAEP-SHA256; EC-only identities decrypt
directly against the Secure Enclave key via ECIES (`eciesEncryptionStandardX963SHA256AESGCM`). This is
the encryption scheme server-side integrators must encrypt against.

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

`authenticationFailed`/`notInteractive` (added alongside `requireAuthentication`/
`persistAcrossBackgrounding`/`stopAuthentication`/`sensitiveTransaction`) have real, distinct
triggers on iOS/macOS (`LAError.authenticationFailed`/`.notInteractive`) but essentially no reachable
trigger on Android today — AndroidX `BiometricPrompt` reports a single failed attempt via the
non-terminal `onAuthenticationFailed()` callback (prompt stays open), not any of the terminal error
codes this plugin maps a result from, so `authenticationFailed` is expected to be rare/unreached on
Android. Don't "fix" this by inventing a mapping that doesn't correspond to real framework behavior.

`systemCanceled` is what `persistAcrossBackgrounding` watches for to decide whether to retry: Android
maps `BiometricPrompt.ERROR_CANCELED` (raw code `"5"`) to it, disambiguated from an explicit
`stopAuthentication()` call (which resumes the waiting coroutine directly with `userCanceled` *before*
`ERROR_CANCELED` can fire — see `LocalBiometricAuthenticator.stopAuthentication`'s doc comment, since
Android reports both with the identical raw code). iOS maps `LAError.systemCancel`/`.appCancel` to it
in `verifyPresence`/`enrollIdentity`'s inline switches, and `errSecInteractionNotAllowed` (best-effort,
unverified against real-device behavior, unlike the `-7`/`-8` lockout codes elsewhere in this file
which were empirically confirmed) in `mapKeyLookupFailure` for the `signPayload`/`decryptPayload` key-
lookup path.

### Security-sensitive config flags

- **`IdentityEnrollmentConfig.requireAuthentication: false`** creates a key usable to sign/decrypt
  with *no* biometric or passcode gating at all — "device has the key" binding only, not "user is
  present." Default (`true`/unset) preserves today's behavior. Never suggest `false` as a default;
  it's for narrow background/silent-operation use cases (e.g. periodic device-attestation pings), not
  general signing/decryption.
- **`persistAcrossBackgrounding`** (on all four config classes) retries the *entire* interrupted
  operation from scratch on foreground, never resumes mid-flight. This matters most for
  `signPayload`/`signPayloadBytes`/`decryptPayload`/`enrollIdentity`: a backgrounded Android
  `Cipher`/`Signature` `CryptoObject` is not guaranteed safely resumable, so a retried call may
  re-prompt from the very beginning rather than continuing silently — document this to app developers
  if you build UI around it, don't assume it "just resumes."

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
