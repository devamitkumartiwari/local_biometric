# local_biometric: advanced guide

Every option, every result field, every error code, and the details your server needs.
For the basics, start with the [README](../README.md).

- [Setup details](#setup-details)
- [Configuration options](#configuration-options)
- [Method parameters](#method-parameters)
- [Output formats](#output-formats)
- [Result objects](#result-objects)
- [Error codes](#error-codes)
- [Server-side integration](#server-side-integration)
- [Platform support](#platform-support)
- [Android version differences](#android-version-differences)
- [Windows](#windows)
- [Limitations & known issues](#limitations--known-issues)

---

## Setup details

### Android permissions

You don't need to add anything. `androidx.biometric` declares both permissions in its own
manifest, and Gradle merges them into your app automatically.

| Permission | Used on | Use case |
|---|---|---|
| `android.permission.USE_BIOMETRIC` | Android 9+ (API 28+) | Required by the system `BiometricPrompt`, which handles fingerprint, face and iris for every prompt (`verifyPresence`, enroll, sign, decrypt). |
| `android.permission.USE_FINGERPRINT` | Android 7–8.1 (API 24–27) | Those versions have no `BiometricPrompt`, so `androidx.biometric` falls back to the older `FingerprintManager` fingerprint API, which requires this permission. It's deprecated from API 28 but still needed for these devices. |

- **No runtime request:** both are *normal* permissions. Android grants them at install time and
  the user never sees a permission dialog, so you don't need `requestPermissions` or
  `permission_handler`.
- **No separate face permission:** face and iris unlock go through `USE_BIOMETRIC`.
- **Optional:** you can declare them yourself to make them visible in your manifest. It's
  harmless:

```xml
<uses-permission android:name="android.permission.USE_BIOMETRIC" />
<uses-permission android:name="android.permission.USE_FINGERPRINT" />
```

### Android `MainActivity`

`BiometricPrompt` needs a `FragmentActivity`. Flutter's default template uses `FlutterActivity`,
so switch it:

```kotlin
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity()
```

Without this, every prompt-issuing call fails with the error message
`Activity required: MainActivity must extend FlutterFragmentActivity`.

### Android build tooling

- **Tested with:** Flutter 3.50, AGP 9.3, Gradle 9.5 and Kotlin 2.4.
- **Kotlin plugin:** the plugin applies the Kotlin Gradle Plugin only when AGP 9's built-in Kotlin
  is off. So it builds both with and without `android.builtInKotlin`, and on AGP 8.

### iOS

`NSFaceIDUsageDescription` in `Info.plist` is required. Without it, Face ID prompts fail.
Swift Package Manager only (`flutter config --enable-swift-package-manager`). There is no podspec,
so an app with SPM turned off can't use this plugin on iOS or macOS. Apps with SPM on work even if
other plugins they use are CocoaPods-only. The
plugin is UIScene-safe.

---

## Configuration options

All fields are optional. Leave a field out to use its default.

### `IdentityEnrollmentConfig` (`enrollIdentity`)

| Field | Type | Default | Description |
|---|---|---|---|
| `signatureType` | `IdentitySignatureType` | `rsa` | `rsa` (RSA-2048) or `ecdsa` (P-256). |
| `enforceBiometric` | `bool` | `false` | Show a biometric prompt during enrollment. |
| `useDeviceCredentials` | `bool` | `false` | Let the key be unlocked with PIN/passcode too. Android: API 30+ only. |
| `enableDecryption` | `bool` | `false` | Make the identity able to decrypt. On Android ECDSA this creates a separate decrypting key ("hybrid mode"). |
| `setInvalidatedByBiometricEnrollment` | `bool` | `true` | Invalidate the key when the enrolled biometrics change. |
| `failIfExists` | `bool` | `false` | Return `keyAlreadyExists` instead of replacing an existing alias. |
| `requireAuthentication` | `bool` | `true` | ⚠️ `false` = no prompt at all is needed to use the key. Background use only. |
| `persistAcrossBackgrounding` | `bool` | `false` | Retry the whole enrollment if the app is backgrounded mid-prompt. |
| `promptSubtitle` / `promptDescription` / `cancelButtonText` | `String` | platform default | Prompt text. |

### `IdentitySignatureConfig` (`signPayload`, `signPayloadBytes`) and `IdentityDecryptConfig` (`decryptPayload`)

| Field | Type | Default | Description |
|---|---|---|---|
| `allowDeviceCredentials` | `bool` | `false` | Allow PIN/passcode for this prompt. Android: API 30+ only. |
| `persistAcrossBackgrounding` | `bool` | `false` | Retry the whole call, including the prompt, if the app is backgrounded mid-prompt. |
| `promptSubtitle` / `promptDescription` / `cancelButtonText` | `String` | platform default | Prompt text. |

### `PresencePromptConfig` (`verifyPresence`)

| Field | Type | Default | Description |
|---|---|---|---|
| `allowDeviceCredentials` | `bool` | `false` | Allow PIN/passcode fallback. |
| `biometricStrength` | `IdentityBiometricStrength` | `strong` | Android: `weak` also accepts class-2 biometrics, and enables PIN fallback on Android 7–10. |
| `sensitiveTransaction` | `bool` | `false` | Android: require an explicit tap after a passive face match. |
| `persistAcrossBackgrounding` | `bool` | `false` | Show the prompt again if the app was backgrounded mid-prompt. |
| `subtitle` / `promptDescription` / `cancelButtonText` | `String` | platform default | Prompt text. |

### How `persistAcrossBackgrounding` works

When the system dismisses a prompt because the app went to the background, the plugin waits for
the app to come back. It then runs the **whole** call again from the start, including a new
prompt, up to 3 times. It never resumes halfway, because a half-finished crypto operation isn't
safe to continue.

On iOS/macOS, `stopAuthentication()` also ends the call with `systemCanceled`. So don't combine
`stopAuthentication()` with `persistAcrossBackgrounding: true` on the same call there.

---

## Method parameters

| Method | Parameters |
|---|---|
| `checkAvailability` | none |
| `isDeviceSecure` | none |
| `verifyPresence` | `promptMessage` (required), `config` |
| `enrollIdentity` | `keyAlias`, `config`, `keyFormat` (default `base64`), `promptMessage` |
| `signPayload` / `signPayloadBytes` | `payload` (required), `keyAlias`, `config`, `signatureFormat` (default `base64`), `keyFormat`, `promptMessage` |
| `decryptPayload` | `payload` (required), `keyAlias`, `payloadFormat` (default `base64`), `config`, `promptMessage` |
| `getIdentityStatus` | `keyAlias`, `checkValidity` (default `false`), `keyFormat` |
| `revokeIdentity` | `keyAlias` |
| `revokeAllIdentities` | none |
| `acknowledgeIdentityChange` | none |
| `stopAuthentication` | none. Returns `true` if a prompt was canceled. |
| `onIdentityChanged` | `Stream<IdentityStatus>`: `valid`, `changed`, `unavailable` |

If you leave out `keyAlias`, the call uses a single default identity.

---

## Output formats

| Enum | Values | Notes |
|---|---|---|
| `IdentityKeyFormat` | `base64`, `pem`, `hex`, `raw` | `raw` returns base64 text. Use `publicKeyBytes` for the actual bytes. |
| `IdentitySignatureFormat` | `base64`, `hex`, `raw` | `raw` returns base64 text. Use `signatureBytes` for the actual bytes. |
| `IdentityPayloadFormat` | `base64`, `hex`, `raw` | `raw` is parsed as base64. |

---

## Result objects

Every call reports failures in the result's `code` and `error` fields. Calls don't throw for
normal failures such as a cancel, a lockout or a missing key.

| Result | Fields |
|---|---|
| `IdentityAvailability` | `canAuthenticate`, `hasEnrolledBiometrics`, `availableBiometrics`, `reason` |
| `PresencePromptResult` | `success`, `code`, `error`, `authenticationType` |
| `IdentityEnrollmentResult` | `code`, `error`, `publicKey`, `publicKeyBytes`, `algorithm`, `keySize`, `isHybridMode`, `decryptingPublicKey`, `decryptingAlgorithm`, `decryptingKeySize`, `authenticationType` |
| `IdentitySignatureResult` | `code`, `error`, `signature`, `signatureBytes`, `publicKey`, `algorithm`, `keySize`, `authenticationType` |
| `IdentityDecryptResult` | `code`, `error`, `decryptedData` (UTF-8 text), `authenticationType` |
| `IdentityInfo` | `exists`, `isValid`, `algorithm`, `keySize`, `isHybridMode`, `publicKey`, `decryptingPublicKey`, `decryptingAlgorithm`, `decryptingKeySize` |

`authenticationType` (`IdentityAuthType`) tells you how the user unlocked: `biometric`,
`credential` (PIN/passcode) or `unknown`.

---

## Error codes

| `IdentityError` | Meaning | `isRecoverable` |
|---|---|---|
| `success` | Operation succeeded. | ✅ |
| `userCanceled` | User canceled, or `stopAuthentication()` was called (Android). | ✅ |
| `authenticationFailed` | One attempt didn't match. Safe to retry (mostly iOS/macOS). | ✅ |
| `systemCanceled` | The OS dismissed the prompt (e.g. the app was backgrounded), or `stopAuthentication()` was called (iOS/macOS). | ✅ |
| `notInteractive` | The prompt couldn't be shown right now (iOS/macOS). | ✅ |
| `promptError` | `verifyPresence` couldn't show a prompt, e.g. no `FlutterFragmentActivity` on Android. | ✅ |
| `lockedOut` | Too many attempts. Temporary. | ❌ |
| `lockedOutPermanent` | Biometrics are locked until the device passcode is entered. | ❌ |
| `notAvailable` | Biometric hardware is unavailable right now. | ❌ |
| `notEnrolled` | No biometrics enrolled on the device. | ❌ |
| `notSupported` | No biometric hardware, or the operation isn't supported. | ❌ |
| `passcodeNotSet` | No device lock is set. | ❌ |
| `securityUpdateRequired` | The OS needs a security update before biometrics can be used. | ❌ |
| `keyNotFound` | No identity exists for this alias. | ❌ |
| `keyInvalidated` | The key was invalidated (e.g. by biometric re-enrollment). Re-enroll. | ❌ |
| `keyAlreadyExists` | `failIfExists` was set and the alias is taken. | ❌ |
| `invalidInput` | Malformed input, e.g. a bad base64 or hex payload. | ❌ |
| `unknown` | Anything else. Check the `error` string. | ❌ |

The `IdentityErrorX` extension adds `isRecoverable` and `userMessage`, a short English fallback
text. Apps with localization should use their own text.

---

## Server-side integration

### Public keys

- Returned as **X.509 SubjectPublicKeyInfo (DER)**. The format is identical on Android and iOS.
- `base64` is the default. `pem` wraps it in `-----BEGIN PUBLIC KEY-----`.
- `publicKeyBytes` holds the raw DER bytes.

### Signatures (same on every platform)

| Identity | Algorithm | Encoding | Verify with (Java / OpenSSL name) |
|---|---|---|---|
| RSA-2048 | RSASSA-PKCS1-v1_5 with SHA-256 | raw | `SHA256withRSA` |
| ECDSA P-256 | ECDSA with SHA-256 | ASN.1 DER (X9.62) | `SHA256withECDSA` |

The message is hashed for you. Send the original payload to your server, not a digest.

### Encryption for `decryptPayload`

| Platform / identity | What to encrypt with | Payload layout |
|---|---|---|
| iOS/macOS, RSA | RSA-OAEP, SHA-256, **MGF1-SHA-256** | ciphertext |
| iOS/macOS, ECDSA | Apple ECIES `eciesEncryptionStandardX963SHA256AESGCM`, against `publicKey` | Apple's format: ephemeral key ‖ ciphertext ‖ tag |
| Android, RSA (`enableDecryption: true`) | RSA-OAEP, SHA-256 (MGF1 digest: see the note below) | ciphertext |
| Android, ECDSA (`enableDecryption: true`, hybrid) | ECDH P-256 against **`decryptingPublicKey`**, then ANSI X9.63 KDF with SHA-256 (no shared info). The first 32 bytes are the AES-256 key; the next 12 bytes are the GCM IV. | 65-byte uncompressed ephemeral public key ‖ AES-GCM ciphertext ‖ 16-byte tag |
| Windows, RSA | RSA-OAEP-SHA256 | ciphertext |

> **Under verification: Android vs iOS compatibility.**
> - iOS RSA uses MGF1-SHA-256. Android Keystore probably applies MGF1-**SHA-1** with the
>   transformation this plugin uses.
> - Android's hybrid-EC envelope is not the same format as Apple's ECIES.
>
> Until this is confirmed on devices, record each user's platform at enrollment and test your
> server encryption against both. iOS behavior will not change.

### How RSA works on iOS/macOS

The Secure Enclave only supports EC keys, so an RSA identity is built in two layers:
- A software RSA-2048 key, which does the actual signing and decrypting.
- A Secure Enclave EC key that encrypts the RSA key. The RSA key is decrypted in memory only after
  biometric approval, and only for that one operation.

---

## Platform support

| | Android | iOS | macOS | Windows |
|---|---|---|---|---|
| Minimum OS | API 24 (Android 7.0) | iOS 16.0 | macOS 13.0 | Windows 10+ with Windows Hello |
| `checkAvailability` | ✅ | ✅ | ✅ | ✅ |
| `verifyPresence` | ✅ | ✅ | ✅ | ⚠️ stub, always reports success |
| `enrollIdentity` / `signPayload` / `signPayloadBytes` | ✅ RSA + ECDSA | ✅ RSA + ECDSA | ✅ RSA + ECDSA | ✅ RSA only |
| `decryptPayload` | ✅ | ✅ | ✅ | ⚠️ undocumented Windows API |
| `onIdentityChanged` | ✅ | ✅ | ✅ | ❌ |
| `stopAuthentication` | ✅ | ✅ | ✅ | ❌ |
| `getIdentityStatus` / `revokeIdentity` / `revokeAllIdentities` / `isDeviceSecure` | ✅ | ✅ | ✅ | ⚠️ stub |
| Secure hardware | StrongBox, else TEE | Secure Enclave | Secure Enclave | TPM via Windows Hello |

macOS runs the same Swift code as iOS.

---

## Android version differences

Every feature works from Android 7.0 (API 24), but some behave differently on older versions:

| Feature | Android 7–8.1 (API 24–27) | Android 9–10 (API 28–29) | Android 11+ (API 30+) |
|---|---|---|---|
| Presence, enroll, sign, decrypt, `onIdentityChanged` | ✅ | ✅ | ✅ |
| Biometric types | Fingerprint only | Fingerprint; face/iris only where the OEM ships a class-3 sensor | Same as API 28–29 |
| PIN/pattern fallback for key operations (`useDeviceCredentials` / `allowDeviceCredentials`) | ❌ Biometric-only | ❌ Biometric-only | ✅ |
| PIN/pattern fallback for `verifyPresence` | ✅ With `biometricStrength: weak` | ✅ With `biometricStrength: weak` | ✅ |
| StrongBox-backed keys | ❌ (TEE) | ✅ Where present | ✅ Where present |
| `sensitiveTransaction` | No effect | No effect on API 28; hint on API 29 | Hint |
| `lockedOutPermanent` | API 24–25 report only `lockedOut` | ✅ | ✅ |
| `securityUpdateRequired` | — | — | ✅ |

---

## Windows

- Built on `KeyCredentialManager` (Windows Hello) for enroll and sign. RSA only.
- These methods are **stubs**: they return a default or success value without doing real work.
  - `verifyPresence`, `getIdentityStatus`, `isDeviceSecure`
  - `revokeIdentity`, `revokeAllIdentities`, `acknowledgeIdentityChange`

  Don't use `verifyPresence` on Windows as a security gate.
- `decryptPayload` uses an **undocumented** NCrypt path against the Microsoft Passport KSP. It may
  stop working after a Windows update.
- `stopAuthentication`, `persistAcrossBackgrounding`, `sensitiveTransaction` and
  `requireAuthentication: false` have no effect.

---

## Limitations & known issues

- **Emulators and simulators** can't fully exercise biometrics or secure hardware. Test on a real
  device. Android emulators can simulate a fingerprint with `adb -e emu finger touch 1`.
- **A device lock is required.** If the user removes their passcode or lock screen, all identities
  are permanently invalidated.
- **Lockouts** can only be cleared by the user entering the device passcode. There is no
  programmatic reset.
- **Android `getIdentityStatus(checkValidity: true)`** currently reports `isValid: true` whenever
  the key exists. Rely on `onIdentityChanged`, or on `keyInvalidated` from sign and decrypt.
- **Android missing-key error:** sign and decrypt on a missing identity currently report `unknown`
  with the message "Identity not found", not `keyNotFound`.
- **Android PIN fallback for key operations** (`useDeviceCredentials` / `allowDeviceCredentials`)
  needs Android 11+. Below that it quietly becomes biometric-only.
- **Cross-platform decryption formats** are under verification. See
  [Server-side integration](#server-side-integration).
