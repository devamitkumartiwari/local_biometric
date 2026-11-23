# local_biometric

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platforms](https://img.shields.io/badge/platforms-Android%20%7C%20iOS%20%7C%20macOS%20%7C%20Windows-informational)
![Flutter](https://img.shields.io/badge/Flutter-%3E%3D3.24.0-02569B?logo=flutter&logoColor=white)
![Android](https://img.shields.io/badge/Android-API%2024%2B-3DDC84?logo=android&logoColor=white)
![iOS](https://img.shields.io/badge/iOS-16%2B-black?logo=apple)

Biometric authentication and hardware-backed cryptographic identities for Flutter.

- **Presence check:** "is the real user here?" via fingerprint, face, or device passcode. No keys involved.
- **Hardware identity:** an RSA-2048 or ECDSA P-256 key pair created inside the iOS/macOS Secure
  Enclave or Android Keystore/StrongBox. You sign and decrypt with it behind a biometric prompt,
  and the private key is never exposed to Dart or app code.

---

## Contents

1. [Features](#features)
2. [Platform support & requirements](#platform-support--requirements)
3. [Installation & setup](#installation--setup)
4. [Quick start](#quick-start)
5. [Examples for every feature](#examples-for-every-feature)
6. [End-to-end example: passwordless login](#end-to-end-example-passwordless-login)
7. [Server-side integration (formats & algorithms)](#server-side-integration-formats--algorithms)
8. [Configuration reference](#configuration-reference)
9. [Result objects reference](#result-objects-reference)
10. [Error handling](#error-handling)
11. [Android version differences](#android-version-differences)
12. [Limitations & known issues](#limitations--known-issues)
13. [What's new](#whats-new)
14. [Example app](#example-app)
15. [Documentation, contact & license](#documentation-contact--license)

---

## Features

| Area | API | What you get |
|---|---|---|
| Device capability | `checkAvailability()` | Whether biometrics can be used, which types are present (fingerprint/face/iris), and why not if unavailable. |
| Device capability | `isDeviceSecure()` | Whether a device lock (PIN/pattern/password/passcode) is set. |
| Presence | `verifyPresence()` | Biometric (or passcode) prompt with no keys involved. Good for "unlock this screen" or "confirm before paying". |
| Identity | `enrollIdentity()` | Creates an RSA-2048 or ECDSA P-256 key pair in secure hardware and returns the public key. |
| Identity | `signPayload()` / `signPayloadBytes()` | Signs a string or raw bytes after a biometric prompt. |
| Identity | `decryptPayload()` | Decrypts data your server encrypted to the identity's public key. |
| Identity | `getIdentityStatus()` | Existence, algorithm, key size and public key, with no prompt. |
| Identity | `revokeIdentity()` / `revokeAllIdentities()` | Deletes one identity, or every identity the plugin created. |
| Multiple identities | `keyAlias` on every method | Separate keys for separate purposes (e.g. `login_key`, `payment_key`). |
| Change detection | `onIdentityChanged` + `acknowledgeIdentityChange()` | Stream that tells you when the device's enrolled biometrics changed and keys need re-enrolling. |
| Control | `stopAuthentication()` | Cancels the prompt currently on screen. |
| Control | `persistAcrossBackgrounding` | Retries an operation from scratch if the app was backgrounded mid-prompt. |
| Security options | `requireAuthentication`, `setInvalidatedByBiometricEnrollment`, `biometricStrength`, `sensitiveTransaction`, `allowDeviceCredentials` | Fine-grained control of how strongly each key and prompt is protected. |
| Errors | `IdentityError` + `isRecoverable` / `userMessage` | One error enum across all platforms, with ready-made helpers. |
| Output formats | `IdentityKeyFormat`, `IdentitySignatureFormat`, `IdentityPayloadFormat` | base64, PEM, hex, plus raw bytes on every result. |

Other properties:
- StrongBox (Android) and Secure Enclave (iOS/macOS) are preferred automatically, with fallback to the standard TEE.
- CocoaPods and Swift Package Manager are both supported.
- iOS is UIScene-safe (multi-window apps).

---

## Platform support & requirements

| | Android | iOS | macOS | Windows |
|---|---|---|---|---|
| Minimum OS | **API 24 (Android 7.0)** | **iOS 16.0** | **macOS 13.0** | Windows 10+ with Windows Hello |
| `checkAvailability` | ✅ | ✅ | ✅ | ✅ |
| `verifyPresence` | ✅ | ✅ | ✅ | ⚠️ stub, always reports success |
| `enrollIdentity` / `signPayload` / `signPayloadBytes` | ✅ RSA + ECDSA | ✅ RSA + ECDSA | ✅ RSA + ECDSA | ✅ RSA only |
| `decryptPayload` | ✅ | ✅ | ✅ | ⚠️ undocumented Windows API, see [Windows](#windows) |
| `onIdentityChanged` | ✅ | ✅ | ✅ | ❌ |
| `stopAuthentication` | ✅ | ✅ | ✅ | ❌ |
| `getIdentityStatus` / `revokeIdentity` / `revokeAllIdentities` / `isDeviceSecure` | ✅ | ✅ | ✅ | ⚠️ stub |
| Secure hardware | StrongBox, else TEE | Secure Enclave | Secure Enclave | TPM via Windows Hello |

Platform notes:
- **Android and iOS** are the complete, maintained implementations. macOS runs the same Swift code as iOS.
- **Windows** is partial; see [Windows](#windows).
- **Build tooling:** tested with Flutter 3.50 (Dart 3.14), AGP 9.3, Gradle 9.5 and Kotlin 2.4. Android apps that enable AGP 9's built-in Kotlin are supported as well.

---

## Installation & setup

```yaml
dependencies:
  local_biometric: ^0.0.5
```

```bash
flutter pub get
```

### Android

**1. `MainActivity` must extend `FlutterFragmentActivity`.** This is required: Flutter's default
template uses `FlutterActivity`, so most apps need to change it.

```kotlin
// android/app/src/main/kotlin/<your/package>/MainActivity.kt
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity()
```

If you skip this, every prompt-issuing call returns the error
`Activity required: MainActivity must extend FlutterFragmentActivity`.

**2. minSdk 24 or higher.** Flutter's default `flutter.minSdkVersion` already is 24.

**3. Permissions: nothing to add.** The plugin needs two permissions, and `androidx.biometric`
declares both in its own manifest, which Gradle merges into your app automatically:

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

### iOS

Add a Face ID usage description to `ios/Runner/Info.plist`. Without it, Face ID prompts fail.

```xml
<key>NSFaceIDUsageDescription</key>
<string>This app uses Face ID to secure your identities and sign data.</string>
```

### macOS / Windows

No extra configuration beyond Flutter's standard plugin registration.

---

## Quick start

```dart
import 'package:local_biometric/local_biometric.dart';

final biometric = LocalBiometric();

Future<bool> unlock() async {
  final availability = await biometric.checkAvailability();
  if (availability.canAuthenticate != true) {
    print('Biometrics unavailable: ${availability.reason}');
    return false;
  }

  final result = await biometric.verifyPresence(promptMessage: "Confirm it's you");
  if (result.success == true) return true;

  print('Failed: ${result.code} – ${result.code?.userMessage}');
  return false;
}
```

That's the whole integration for presence-only use. The rest of this README covers hardware identities.

---

## Examples for every feature

All examples assume `final biometric = LocalBiometric();`.

### 1. Check availability

```dart
final a = await biometric.checkAvailability();

print('Can authenticate: ${a.canAuthenticate}');        // biometrics usable right now
print('Has enrolled biometrics: ${a.hasEnrolledBiometrics}');
print('Types: ${a.availableBiometrics}');               // [IdentityBiometricType.fingerprint, ...]
print('Reason if not: ${a.reason}');                    // e.g. NOT_ENROLLED, lockedOut, lockedOutPermanent
```

### 2. Check that the device has a lock screen

Keys can only be created when a device lock is set.

```dart
if (!await biometric.isDeviceSecure()) {
  // Ask the user to set a PIN / passcode in system settings first.
}
```

### 3. Presence verification (no keys)

```dart
final result = await biometric.verifyPresence(
  promptMessage: 'Confirm payment of \$25',
  config: PresencePromptConfig(
    subtitle: 'Payment confirmation',
    promptDescription: 'Touch the sensor to continue',
    cancelButtonText: 'Not now',
    allowDeviceCredentials: true, // allow PIN/passcode fallback
  ),
);

if (result.success == true) {
  print('Authenticated with ${result.authenticationType}'); // biometric or credential
}
```

**PIN fallback on older Android (7–10):** accept weak biometrics so the credential fallback is allowed.

```dart
await biometric.verifyPresence(
  promptMessage: 'Unlock',
  config: PresencePromptConfig(
    allowDeviceCredentials: true,
    biometricStrength: IdentityBiometricStrength.weak,
  ),
);
```

**Require an explicit tap after a passive face match** (Android only):

```dart
await biometric.verifyPresence(
  promptMessage: 'Approve transfer',
  config: PresencePromptConfig(sensitiveTransaction: true),
);
```

### 4. Enroll a hardware identity

**RSA (signing):**

```dart
final enrollment = await biometric.enrollIdentity(
  keyAlias: 'login_key',
  promptMessage: 'Set up biometric login',
  keyFormat: IdentityKeyFormat.pem, // public key as PEM (default: base64 DER)
  config: IdentityEnrollmentConfig(
    signatureType: IdentitySignatureType.rsa,
    enforceBiometric: true, // prompt during enrollment too
    failIfExists: true,     // don't silently replace an existing key
  ),
);

if (enrollment.code == IdentityError.success) {
  sendToServer(enrollment.publicKey!); // register this public key for the user
}
```

**ECDSA P-256 (smaller and faster signatures):**

```dart
await biometric.enrollIdentity(
  keyAlias: 'device_key',
  config: IdentityEnrollmentConfig(signatureType: IdentitySignatureType.ecdsa),
);
```

**With decryption enabled:**

```dart
final e = await biometric.enrollIdentity(
  keyAlias: 'vault_key',
  config: IdentityEnrollmentConfig(
    signatureType: IdentitySignatureType.ecdsa,
    enableDecryption: true,
  ),
);

// Android ECDSA identities decrypt with a separate key (hybrid mode). Encrypt to this one:
final encryptTo = e.isHybridMode == true ? e.decryptingPublicKey : e.publicKey;
```

**Allow PIN/passcode for this key's prompts** (Android 11+ and iOS):

```dart
await biometric.enrollIdentity(
  keyAlias: 'pin_ok_key',
  config: IdentityEnrollmentConfig(useDeviceCredentials: true),
);
```

**Keep the key valid when the user adds a new fingerprint or face:**

```dart
await biometric.enrollIdentity(
  keyAlias: 'long_lived_key',
  config: IdentityEnrollmentConfig(setInvalidatedByBiometricEnrollment: false),
);
```

**No user authentication at all (security-sensitive, background use only):**

```dart
// A "device has the key" binding only. Use for silent device-attestation pings,
// never for signing or decrypting anything sensitive.
await biometric.enrollIdentity(
  keyAlias: 'attestation_key',
  config: IdentityEnrollmentConfig(requireAuthentication: false),
);
```

### 5. Sign data

**Sign a string:**

```dart
final sig = await biometric.signPayload(
  payload: 'nonce-8f3a2c',
  keyAlias: 'login_key',
  promptMessage: 'Sign in',
  signatureFormat: IdentitySignatureFormat.base64, // or hex
  config: IdentitySignatureConfig(
    promptSubtitle: 'Biometric login',
    allowDeviceCredentials: false, // biometric only
  ),
);

if (sig.code == IdentityError.success) {
  print(sig.signature);      // encoded signature
  print(sig.signatureBytes); // raw bytes, always present
  print(sig.publicKey);      // public key that verifies it
}
```

**Sign raw bytes:**

```dart
import 'dart:convert';
import 'dart:typed_data';

final bytes = Uint8List.fromList(utf8.encode('{"amount":25,"to":"alice"}'));
final sig = await biometric.signPayloadBytes(payload: bytes, keyAlias: 'payment_key');
```

### 6. Decrypt data

Your server encrypts to the identity's public key (see
[Server-side integration](#server-side-integration-formats--algorithms)), and the app decrypts:

```dart
final d = await biometric.decryptPayload(
  payload: encryptedBase64FromServer,
  keyAlias: 'vault_key',
  payloadFormat: IdentityPayloadFormat.base64, // or hex
  promptMessage: 'Unlock your vault',
  config: IdentityDecryptConfig(cancelButtonText: 'Cancel'),
);

if (d.code == IdentityError.success) print(d.decryptedData); // UTF-8 text
```

### 7. Inspect an identity (no prompt)

```dart
final info = await biometric.getIdentityStatus(
  keyAlias: 'login_key',
  checkValidity: true, // iOS/macOS: also checks for biometric re-enrollment
  keyFormat: IdentityKeyFormat.pem,
);

if (info.exists == true) {
  print('${info.algorithm} ${info.keySize}-bit, valid: ${info.isValid}');
  print('Hybrid: ${info.isHybridMode}, decrypting key: ${info.decryptingPublicKey}');
}
```

### 8. Revoke identities

```dart
await biometric.revokeIdentity(keyAlias: 'login_key'); // one identity
await biometric.revokeAllIdentities();                 // every identity this plugin created
```

### 9. React to biometric changes

Keys enrolled with `setInvalidatedByBiometricEnrollment: true` (the default) stop working when the
user adds or removes a fingerprint or face. Listen for that instead of finding out on a failed signature:

```dart
final sub = biometric.onIdentityChanged.listen((status) async {
  if (status == IdentityStatus.changed) {
    await biometric.revokeIdentity(keyAlias: 'login_key');
    // ...ask the user to re-enroll, then:
    await biometric.acknowledgeIdentityChange();
  }
});
// later: sub.cancel();
```

### 10. Cancel a prompt in progress

```dart
// e.g. from a timeout or when the user navigates away
final wasCanceled = await biometric.stopAuthentication();
// The pending call completes with IdentityError.userCanceled on Android,
// and with IdentityError.systemCanceled on iOS/macOS.
```

On iOS/macOS, don't combine `stopAuthentication()` with `persistAcrossBackgrounding: true` on the
same call. The cancel arrives as `systemCanceled`, which that option treats as a reason to retry.

### 11. Survive the app being backgrounded mid-prompt

```dart
final sig = await biometric.signPayload(
  payload: challenge,
  keyAlias: 'login_key',
  config: IdentitySignatureConfig(persistAcrossBackgrounding: true),
);
// If the system dismissed the prompt because the app went to the background, the whole call
// re-runs from scratch when the app returns (the prompt shows again), up to 3 times.
```

### 12. Handle lockouts

```dart
final r = await biometric.verifyPresence(promptMessage: 'Unlock');

if (r.code == IdentityError.lockedOut || r.code == IdentityError.lockedOutPermanent) {
  // Entering the device passcode re-arms biometrics on every platform.
  await biometric.verifyPresence(
    promptMessage: 'Enter your passcode to re-enable biometrics',
    config: PresencePromptConfig(
      allowDeviceCredentials: true,
      biometricStrength: IdentityBiometricStrength.weak, // allows PIN on Android 7–10 too
    ),
  );
}
```

### 13. Use several identities side by side

```dart
await biometric.enrollIdentity(keyAlias: 'login_key');
await biometric.enrollIdentity(
  keyAlias: 'payment_key',
  config: IdentityEnrollmentConfig(signatureType: IdentitySignatureType.ecdsa),
);
// Omit keyAlias everywhere to use a single default identity.
```

---

## End-to-end example: passwordless login

```dart
class BiometricLogin {
  final _bio = LocalBiometric();
  static const _alias = 'login_key';

  /// One-time setup: create a key and register its public key with the server.
  Future<bool> register(Api api) async {
    if (!await _bio.isDeviceSecure()) return false;

    final e = await _bio.enrollIdentity(
      keyAlias: _alias,
      keyFormat: IdentityKeyFormat.pem,
      config: IdentityEnrollmentConfig(
        signatureType: IdentitySignatureType.ecdsa,
        enforceBiometric: true,
      ),
    );
    if (e.code != IdentityError.success) return false;

    await api.registerPublicKey(e.publicKey!);
    return true;
  }

  /// Each login: sign the server's one-time challenge.
  Future<String?> login(Api api) async {
    final challenge = await api.fetchChallenge();

    final sig = await _bio.signPayload(
      payload: challenge,
      keyAlias: _alias,
      promptMessage: 'Sign in',
      config: IdentitySignatureConfig(persistAcrossBackgrounding: true),
    );

    switch (sig.code) {
      case IdentityError.success:
        return api.verifySignature(challenge, sig.signature!); // returns a session token
      case IdentityError.keyInvalidated:
      case IdentityError.keyNotFound:
        await _bio.revokeIdentity(keyAlias: _alias);
        return null; // fall back to password and offer to re-register
      default:
        print(sig.code?.userMessage);
        return null;
    }
  }
}
```

---

## Server-side integration (formats & algorithms)

### Public keys

- Returned as **X.509 SubjectPublicKeyInfo (DER)**, identical on Android and iOS.
- `base64` is the default. `pem` wraps it in `-----BEGIN PUBLIC KEY-----`.
- `publicKeyBytes` holds the raw DER bytes.

### Signatures (same on every platform)

| Identity | Algorithm | Encoding | Verify with (Java / OpenSSL name) |
|---|---|---|---|
| RSA-2048 | RSASSA-PKCS1-v1_5 with SHA-256 | raw | `SHA256withRSA` |
| ECDSA P-256 | ECDSA with SHA-256 | ASN.1 DER (X9.62) | `SHA256withECDSA` |

The message is hashed for you; send the original payload to your server, not a digest.

### Encryption for `decryptPayload`

| Platform / identity | What to encrypt with | Payload layout |
|---|---|---|
| iOS/macOS, RSA | RSA-OAEP, SHA-256, **MGF1-SHA-256** | ciphertext |
| iOS/macOS, ECDSA | Apple ECIES `eciesEncryptionStandardX963SHA256AESGCM` against `publicKey` | Apple's format: ephemeral key ‖ ciphertext ‖ tag |
| Android, RSA (`enableDecryption: true`) | RSA-OAEP, SHA-256 (MGF1 digest: see note below) | ciphertext |
| Android, ECDSA (`enableDecryption: true`, hybrid) | ECDH P-256 against **`decryptingPublicKey`** → ANSI X9.63 KDF with SHA-256 (no shared info) → first 32 bytes = AES-256 key, next 12 bytes = GCM IV | 65-byte uncompressed ephemeral public key ‖ AES-GCM ciphertext ‖ 16-byte tag |
| Windows, RSA | RSA-OAEP-SHA256 | ciphertext |

> **Under verification: Android vs iOS compatibility.** iOS RSA uses MGF1-SHA-256. Android
> Keystore probably applies MGF1-**SHA-1** with the transformation the plugin uses. Android's
> hybrid-EC envelope is also not the same format as Apple's ECIES. Until this is confirmed on
> devices, record each user's platform at enrollment and test your server encryption against
> both. iOS behavior will not change.

---

## Configuration reference

All fields are optional. Omit a field to get its default.

### `IdentityEnrollmentConfig` (`enrollIdentity`)

| Field | Type | Default | Description |
|---|---|---|---|
| `signatureType` | `IdentitySignatureType` | `rsa` | `rsa` (RSA-2048) or `ecdsa` (P-256). |
| `enforceBiometric` | `bool` | `false` | Show a biometric prompt during enrollment. |
| `useDeviceCredentials` | `bool` | `false` | Let the key be unlocked with PIN/passcode too. Android: API 30+ only. |
| `enableDecryption` | `bool` | `false` | Make the identity able to decrypt. On Android ECDSA this creates a hybrid decrypting key. |
| `setInvalidatedByBiometricEnrollment` | `bool` | `true` | Invalidate the key when enrolled biometrics change. |
| `failIfExists` | `bool` | `false` | Return `keyAlreadyExists` instead of replacing an existing alias. |
| `requireAuthentication` | `bool` | `true` | ⚠️ `false` = no prompt at all is needed to use the key. Background use only. |
| `persistAcrossBackgrounding` | `bool` | `false` | Retry the whole enrollment if backgrounded mid-prompt. |
| `promptSubtitle` / `promptDescription` / `cancelButtonText` | `String` | platform default | Prompt text. |

### `IdentitySignatureConfig` (`signPayload`, `signPayloadBytes`) and `IdentityDecryptConfig` (`decryptPayload`)

| Field | Type | Default | Description |
|---|---|---|---|
| `allowDeviceCredentials` | `bool` | `false` | Allow PIN/passcode for this prompt. Android: API 30+ only. |
| `persistAcrossBackgrounding` | `bool` | `false` | Retry the whole call (re-prompting) if backgrounded mid-prompt. |
| `promptSubtitle` / `promptDescription` / `cancelButtonText` | `String` | platform default | Prompt text. |

### `PresencePromptConfig` (`verifyPresence`)

| Field | Type | Default | Description |
|---|---|---|---|
| `allowDeviceCredentials` | `bool` | `false` | Allow PIN/passcode fallback. |
| `biometricStrength` | `IdentityBiometricStrength` | `strong` | Android: `weak` also accepts class-2 biometrics and enables PIN fallback on Android 7–10. |
| `sensitiveTransaction` | `bool` | `false` | Android: require an explicit tap after a passive face match. |
| `persistAcrossBackgrounding` | `bool` | `false` | Re-show the prompt if the app was backgrounded mid-prompt. |
| `subtitle` / `promptDescription` / `cancelButtonText` | `String` | platform default | Prompt text. |

### Method parameters

| Method | Parameters |
|---|---|
| `enrollIdentity` | `keyAlias`, `config`, `keyFormat` (default `base64`), `promptMessage` |
| `signPayload` / `signPayloadBytes` | `payload` (required), `keyAlias`, `config`, `signatureFormat` (default `base64`), `keyFormat`, `promptMessage` |
| `decryptPayload` | `payload` (required), `keyAlias`, `payloadFormat` (default `base64`), `config`, `promptMessage` |
| `getIdentityStatus` | `keyAlias`, `checkValidity` (default `false`), `keyFormat` |
| `verifyPresence` | `promptMessage` (required), `config` |
| `revokeIdentity` | `keyAlias` |

### Formats

| Enum | Values | Notes |
|---|---|---|
| `IdentityKeyFormat` | `base64`, `pem`, `hex`, `raw` | `raw` returns base64 text. Use `publicKeyBytes` for bytes. |
| `IdentitySignatureFormat` | `base64`, `hex`, `raw` | `raw` returns base64 text. Use `signatureBytes` for bytes. |
| `IdentityPayloadFormat` | `base64`, `hex`, `raw` | `raw` is parsed as base64. |

---

## Result objects reference

Every call reports failures in the result's `code` and `error` fields. Calls don't throw for
normal failures such as a cancel, a lockout or a missing key.

| Result | Fields |
|---|---|
| `IdentityAvailability` | `canAuthenticate`, `hasEnrolledBiometrics`, `availableBiometrics`, `reason` |
| `PresencePromptResult` | `success`, `code`, `error`, `authenticationType` |
| `IdentityEnrollmentResult` | `code`, `error`, `publicKey`, `publicKeyBytes`, `algorithm`, `keySize`, `isHybridMode`, `decryptingPublicKey`, `decryptingAlgorithm`, `decryptingKeySize`, `authenticationType` |
| `IdentitySignatureResult` | `code`, `error`, `signature`, `signatureBytes`, `publicKey`, `algorithm`, `keySize`, `authenticationType` |
| `IdentityDecryptResult` | `code`, `error`, `decryptedData`, `authenticationType` |
| `IdentityInfo` | `exists`, `isValid`, `algorithm`, `keySize`, `isHybridMode`, `publicKey`, `decryptingPublicKey`, `decryptingAlgorithm`, `decryptingKeySize` |

`authenticationType` (`IdentityAuthType`) is one of:
- `biometric`
- `credential` (PIN/passcode)
- `unknown`

---

## Error handling

| `IdentityError` | Meaning | `isRecoverable` |
|---|---|---|
| `success` | Operation succeeded. | ✅ |
| `userCanceled` | User canceled, or `stopAuthentication()` was called (Android). | ✅ |
| `authenticationFailed` | One attempt didn't match. Safe to retry (mostly iOS/macOS). | ✅ |
| `systemCanceled` | The OS dismissed the prompt (e.g. the app was backgrounded), or `stopAuthentication()` was called (iOS/macOS). | ✅ |
| `notInteractive` | The prompt couldn't be shown right now (iOS/macOS). | ✅ |
| `promptError` | `verifyPresence` couldn't show a prompt, e.g. no `FlutterFragmentActivity` on Android. | ✅ |
| `lockedOut` | Too many attempts. Temporary. | ❌ |
| `lockedOutPermanent` | Biometrics locked until the device passcode is entered. | ❌ |
| `notAvailable` | Biometric hardware is unavailable right now. | ❌ |
| `notEnrolled` | No biometrics enrolled on the device. | ❌ |
| `notSupported` | No biometric hardware, or the operation isn't supported. | ❌ |
| `passcodeNotSet` | No device lock is set. | ❌ |
| `securityUpdateRequired` | The OS needs a security update before biometrics can be used. | ❌ |
| `keyNotFound` | No identity exists for this alias. | ❌ |
| `keyInvalidated` | The key was invalidated, e.g. by biometric re-enrollment. Re-enroll. | ❌ |
| `keyAlreadyExists` | `failIfExists` was set and the alias is taken. | ❌ |
| `invalidInput` | Malformed input, e.g. a bad base64 or hex payload. | ❌ |
| `unknown` | Anything else. Check the `error` string. | ❌ |

Helpers from the `IdentityErrorX` extension:

```dart
final code = result.code ?? IdentityError.unknown;

if (code != IdentityError.success) {
  if (code.isRecoverable) {
    // offer "Try again"
  } else {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(content: Text(code.userMessage)),
    );
  }
}
```

`userMessage` is a short English fallback. Apps with localization should use their own text.

---

## Android version differences

Every feature works from Android 7.0 (API 24), but some behave differently on older versions:

| Feature | Android 7–8.1 (API 24–27) | Android 9–10 (API 28–29) | Android 11+ (API 30+) |
|---|---|---|---|
| Presence, enroll, sign, decrypt, `onIdentityChanged` | ✅ | ✅ | ✅ |
| Biometric types | Fingerprint only | Fingerprint; face/iris only where the OEM ships a class-3 sensor | Same as API 28–29 |
| PIN/pattern fallback for key operations (`useDeviceCredentials` / `allowDeviceCredentials` on enroll, sign, decrypt) | ❌ Biometric-only | ❌ Biometric-only | ✅ |
| PIN/pattern fallback for `verifyPresence` | ✅ With `biometricStrength: weak` | ✅ With `biometricStrength: weak` | ✅ |
| StrongBox-backed keys | ❌ (TEE) | ✅ Where present | ✅ Where present |
| `sensitiveTransaction` | No effect | No effect on API 28; hint on API 29 | Hint |
| `lockedOutPermanent` | API 24–25 report only `lockedOut` | ✅ | ✅ |
| `securityUpdateRequired` | — | — | ✅ |

---

## Limitations & known issues

- **Emulators and simulators** can't fully exercise biometrics or secure hardware. Test on a real
  device with biometrics enrolled. (Android emulators can simulate a fingerprint with
  `adb -e emu finger touch 1`.)
- **A device lock is required.** If the user removes their passcode or lock screen, all identities
  are permanently invalidated.
- **Lockouts** can only be cleared by the user entering the device passcode. There is no
  programmatic reset.
- **Biometric changes** invalidate keys enrolled with `setInvalidatedByBiometricEnrollment: true`.
  Use [`onIdentityChanged`](#9-react-to-biometric-changes).
- **Android `getIdentityStatus(checkValidity: true)`** currently reports `isValid: true` whenever
  the key exists. Rely on `onIdentityChanged`, or on `keyInvalidated` from sign and decrypt.
- **Android missing-key error:** sign and decrypt on a missing identity currently report `unknown`
  with the message "Identity not found", rather than `keyNotFound`.
- **Android `useDeviceCredentials` / `allowDeviceCredentials` on key operations** need Android 11+.
  Below that they quietly become biometric-only.
- **RSA on iOS/macOS:** the Secure Enclave only supports EC keys. An RSA identity is a software RSA
  key encrypted by a Secure Enclave EC key, and it is decrypted in memory only after biometric
  approval.
- **Cross-platform decryption formats** are under verification; see
  [Server-side integration](#server-side-integration-formats--algorithms).
- **`persistAcrossBackgrounding`** retries the entire operation and shows the prompt again. It
  never resumes halfway.

### Windows

- Implemented with `KeyCredentialManager` (Windows Hello) for enroll and sign. RSA only.
- These methods are **stubs** that return a default or success value without doing real work:
  `verifyPresence`, `getIdentityStatus`, `revokeIdentity`, `revokeAllIdentities`,
  `isDeviceSecure` and `acknowledgeIdentityChange`. Don't use `verifyPresence` on Windows as a
  security gate.
- `decryptPayload` uses an **undocumented** NCrypt path against the Microsoft Passport KSP. It may
  stop working after a Windows update. Details are in [CLAUDE.md](https://github.com/devamitkumartiwari/local_biometric/blob/main/CLAUDE.md).
- `stopAuthentication`, `persistAcrossBackgrounding`, `sensitiveTransaction` and
  `requireAuthentication: false` have no effect.

---

## What's new

The full history is in [CHANGELOG.md](CHANGELOG.md).

### 0.0.5
- **Android now supports API 24+** (Android 7.0), down from API 28. See [Android version differences](#android-version-differences).
- **Flutter 3.50 ready:**
  - The example app is updated to AGP 9.3.1, Gradle 9.5.0 and Kotlin 2.4.20.
  - The plugin works with or without AGP 9's built-in Kotlin, so there's no more "plugins that apply KGP" warning.
- **Smoother UI on Android:** key generation and crypto work moved off the main thread. RSA key creation on StrongBox could previously freeze the UI.
- **Android fixes:**
  - `biometricStrength` is now honored.
  - `weak` + `allowDeviceCredentials` gives PIN fallback on Android 7–10.
  - Concurrent background retries no longer get stuck.
  - There's a clear error message when `MainActivity` isn't a `FlutterFragmentActivity`.
  - Decrypted text is explicitly UTF-8.
  - The change-detection scan is skipped when nothing listens to it.
- This README has been rewritten with examples for every feature.
- No changes to the Dart API, iOS, macOS or Windows code, or already-enrolled keys.

### 0.0.4
- Real `decryptPayload` on iOS/macOS.
- Richer `getIdentityStatus` on iOS/macOS and Android.
- `onIdentityChanged` now detects re-enrollment on iOS/macOS.
- New options:
  - `requireAuthentication`
  - `persistAcrossBackgrounding`
  - `sensitiveTransaction`
  - `stopAuthentication()`
- New error codes: `authenticationFailed` and `notInteractive`.
- `IdentityErrorX` helpers.
- Windows: sign and decrypt fixes.

### 0.0.3
- iOS 16 / macOS 13 minimum.
- Swift Package Manager support.
- macOS build fix.
- UIScene-safe.

### 0.0.2
- Temporary vs. permanent lockout handling.
- Passcode recovery flow.

### 0.0.1
- Initial release: presence verification, RSA/ECDSA identities, unified error codes.

---

## Example app

[`example/`](example/) is a runnable demo of every feature in this README:

| Page | Shows |
|---|---|
| `simple_auth_page.dart` | `checkAvailability`, `verifyPresence`, lockout recovery |
| `encrypted_auth_page.dart` | enroll (RSA/ECDSA, decryption), sign, sign bytes, decrypt, `persistAcrossBackgrounding`, `stopAuthentication` |
| `management_page.dart` | `getIdentityStatus`, revoke, `onIdentityChanged`, `acknowledgeIdentityChange` |

```bash
cd example && flutter run
```

---

## Documentation, contact & license

- **[CHANGELOG.md](CHANGELOG.md):** release history.
- **[CLAUDE.md](https://github.com/devamitkumartiwari/local_biometric/blob/main/CLAUDE.md):** architecture deep-dive for contributors. Covers the Pigeon codegen,
  per-platform crypto design, error mapping, Windows caveats and Android threading rules.
- **API docs:** every type is documented in [`pigeons/identity_messages.dart`](pigeons/identity_messages.dart),
  and your IDE shows the same text.
- **Contact:** for support, feature requests or business inquiries, see the
  [web portal](https://hireamit.web.app/).
- **License:** MIT. See [LICENSE](LICENSE).
