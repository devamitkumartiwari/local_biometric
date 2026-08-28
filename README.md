# local_biometric

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platforms](https://img.shields.io/badge/platforms-Android%20%7C%20iOS%20%7C%20macOS%20%7C%20Windows-informational)
![Flutter](https://img.shields.io/badge/Flutter-%3E%3D3.24.0-02569B?logo=flutter&logoColor=white)

A hardware-backed biometric authentication and cryptographic identity plugin for Flutter — quick
presence checks, or full RSA/ECDSA key pairs generated and used entirely inside the Secure Enclave
(iOS/macOS) and Android Keystore/StrongBox, with the private key never leaving secure hardware.

Jump to: [Installation](#installation) · [Quick Start](#quick-start) ·
[Usage Guide](#usage-guide) · [Features](#features) · [Configuration & Customization](#configuration--customization) ·
[Error Handling](#error-handling) · [Platform Support](#platform-support) ·
[Limitations](#limitations--important-notes)

## Installation

```yaml
dependencies:
  local_biometric: ^0.0.4
```

Then:

```bash
flutter pub get
```

### iOS configuration

Add a Face ID usage description to `ios/Runner/Info.plist`:

```xml
<key>NSFaceIDUsageDescription</key>
<string>This app uses Face ID to secure your identities and sign data.</string>
```

### Android configuration

Add the biometric permission to `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.USE_BIOMETRIC" />
```

Your `MainActivity` must be (or extend) a `FlutterFragmentActivity` — this is Flutter's default
template, so most apps need no change here.

### macOS / Windows

No extra configuration needed beyond the standard plugin registration Flutter generates for you.

## Quick Start

```dart
import 'package:local_biometric/local_biometric.dart';

final plugin = LocalBiometric();

Future<void> unlockScreen() async {
  final availability = await plugin.checkAvailability();
  if (!availability.canAuthenticate) {
    print('Biometrics unavailable: ${availability.reason}');
    return;
  }

  final result = await plugin.verifyPresence(
    promptMessage: 'Confirm it\'s you',
  );

  if (result.success == true) {
    print('Authenticated via ${result.authenticationType}');
  } else {
    print('Failed: ${result.code}');
  }
}
```

That's the entire integration for presence-only use cases. Read on for hardware-backed identities.

## Usage Guide

### 1. Check availability

Always check before performing biometric actions — this also tells you *which* biometric types
are available and, if unavailable, why.

```dart
final availability = await plugin.checkAvailability();
if (availability.canAuthenticate) {
  print('Ready. Types: ${availability.availableBiometrics}');
} else {
  print('Unavailable: ${availability.reason}');
}
```

### 2. Simple presence verification

No keys, just "is the user present."

```dart
final result = await plugin.verifyPresence(
  promptMessage: 'Please confirm your identity',
  config: PresencePromptConfig(
    allowDeviceCredentials: true, // allow falling back to the device passcode
  ),
);

if (result.success == true) {
  print('Authenticated!');
}
```

### 3. Enroll a hardware-backed identity

```dart
final enrollment = await plugin.enrollIdentity(
  keyAlias: 'my_secure_key',
  config: IdentityEnrollmentConfig(
    signatureType: IdentitySignatureType.rsa,
    enforceBiometric: true,
  ),
);

if (enrollment.code == IdentityError.success) {
  print('Public key: ${enrollment.publicKey}');
}
```

### 4. Sign data

```dart
final signature = await plugin.signPayload(
  payload: 'Data to sign',
  keyAlias: 'my_secure_key',
  config: IdentitySignatureConfig(
    allowDeviceCredentials: false, // force biometric-only for signing
  ),
);

if (signature.code == IdentityError.success) {
  print('Signature: ${signature.signature}');
}
```

`signPayloadBytes()` is the same call shape for raw `Uint8List` payloads instead of a `String`.

### 5. Decrypt data

Decrypt a payload that was encrypted **externally** (e.g. by your backend) against the public key
returned by `enrollIdentity`: RSA-OAEP-SHA256 for RSA identities, ECIES-X963-SHA256-AESGCM for
EC-only identities on iOS/macOS. See [Platform Support](#platform-support) for the Windows caveat.

```dart
final decrypted = await plugin.decryptPayload(
  payload: encryptedPayloadBase64,
  keyAlias: 'my_secure_key',
  payloadFormat: IdentityPayloadFormat.base64,
);

if (decrypted.code == IdentityError.success) {
  print('Decrypted: ${decrypted.decryptedData}');
}
```

### 6. Check identity status

```dart
final info = await plugin.getIdentityStatus(
  keyAlias: 'my_secure_key',
  checkValidity: true, // verify hardware validity, not just existence
);

print('Exists: ${info.exists}, valid: ${info.isValid}, algorithm: ${info.algorithm}');
```

### 7. Revoke identities

```dart
await plugin.revokeIdentity(keyAlias: 'my_secure_key'); // one identity
await plugin.revokeAllIdentities();                     // everything the plugin created
```

### 8. React to biometric enrollment changes

If the user adds or removes a fingerprint/face after enrolling an identity, keys enrolled with
`setInvalidatedByBiometricEnrollment: true` become unusable. Listen for it instead of discovering
it on the next failed sign call:

```dart
plugin.onIdentityChanged.listen((status) {
  if (status == IdentityStatus.changed) {
    // Prompt the user to re-enroll, then:
    plugin.acknowledgeIdentityChange();
  }
});
```

### 9. Cancel an in-flight prompt

```dart
final canceled = await plugin.stopAuthentication();
```

### 10. Handle lockouts

```dart
if (result.code == IdentityError.lockedOut ||
    result.code == IdentityError.lockedOutPermanent) {
  // Verifying the device passcode re-arms biometrics on both platforms:
  await plugin.verifyPresence(
    promptMessage: 'Verify passcode to unlock biometrics',
    config: PresencePromptConfig(allowDeviceCredentials: true),
  );
}
```

## Features

### Presence verification (no keys)
- `verifyPresence()` — confirm the user is present via biometrics or device credentials, no
  cryptographic keys involved. Ideal for "unlock this screen" / "confirm before proceeding" gates.

### Hardware-backed cryptographic identity
- `enrollIdentity()` — generate an RSA-2048 or ECDSA (P-256) key pair inside the Secure Enclave
  (iOS/macOS) or Android Keystore/StrongBox. The private key is generated in hardware and never
  exposed to Dart or app code.
- `signPayload()` / `signPayloadBytes()` — sign a string or raw bytes with the enrolled key,
  gated by a biometric prompt.
- `decryptPayload()` — decrypt data that was encrypted against the identity's public key
  (RSA-OAEP-SHA256 for RSA identities, ECIES for EC-only identities).
- `getIdentityStatus()` — inspect an identity without a prompt: does it exist, is it still valid,
  what algorithm/key size, its public key in your choice of format.
- `revokeIdentity()` / `revokeAllIdentities()` — delete one identity, or wipe everything the
  plugin has created.
- Multiple named identities per app via `keyAlias` on every method — separate keys for separate
  purposes (e.g. a login key and a payment-signing key) with no cross-talk.

### Biometric-change detection
- `onIdentityChanged` — a live `Stream<IdentityStatus>` that emits `changed` when the device's
  enrolled biometrics change (e.g. a new fingerprint is added), so you can prompt for
  re-enrollment instead of silently failing on the next sign/decrypt call.
- `acknowledgeIdentityChange()` — clear a reported change once you've handled it.

### Control and cancellation
- `stopAuthentication()` — cancel whatever prompt is currently on screen.
- `persistAcrossBackgrounding` — optionally auto-retry an operation interrupted by the app being
  backgrounded, instead of it just failing.

### Built-in lockout & security handling
- Distinguishes temporary vs. permanent biometric lockout across platforms, with a consistent
  recovery path (verify the device passcode to re-arm biometrics).
- Every result carries a standardized `IdentityError` code and an `authenticationType`
  (`biometric` vs. `credential`) telling you exactly how the user authenticated.
- Opt-in `requireAuthentication: false` for narrow non-interactive use cases, and
  `sensitiveTransaction` to require an explicit gesture after a passive face match — see
  [Configuration & Customization](#configuration--customization).

### Platform depth
- Prefers StrongBox (Android) / Secure Enclave (iOS/macOS) automatically, falling back to the
  standard TEE/Keystore when specialized hardware isn't available — no code changes needed.
- Both CocoaPods and Swift Package Manager supported on iOS/macOS.

## Configuration & Customization

Every enroll/sign/decrypt/presence call takes an optional config object. All fields are optional —
omit anything you don't need to customize.

### `IdentityEnrollmentConfig` (`enrollIdentity`)

| Field | Type | Default | What it does |
|---|---|---|---|
| `signatureType` | `IdentitySignatureType` | `rsa` | `rsa` or `ecdsa`. |
| `enforceBiometric` | `bool` | `false` | Require a biometric prompt at enrollment time itself. |
| `useDeviceCredentials` | `bool` | `false` | Allow passcode/PIN as a fallback for this identity's prompts. |
| `enableDecryption` | `bool` | `false` | Enable native decryption capability alongside signing. |
| `setInvalidatedByBiometricEnrollment` | `bool` | `true` | Invalidate this key if the device's enrolled biometrics change. |
| `failIfExists` | `bool` | `false` | Fail with `keyAlreadyExists` instead of silently replacing an existing alias. |
| `promptSubtitle` / `promptDescription` / `cancelButtonText` | `String` | platform default | Customize the system prompt's copy. |
| `requireAuthentication` | `bool` | `true` | **Security-sensitive.** `false` creates a key usable with **no** biometric/passcode gating at all — "device has the key," not "user is present." Only use for narrow background/silent cases (e.g. periodic attestation pings), never as a default for signing/decrypting sensitive data. |
| `persistAcrossBackgrounding` | `bool` | `false` | Auto-retry the *entire* enrollment from scratch if the app is backgrounded mid-prompt, instead of failing with `systemCanceled`. |

### `IdentitySignatureConfig` (`signPayload` / `signPayloadBytes`)

| Field | Type | Default | What it does |
|---|---|---|---|
| `allowDeviceCredentials` | `bool` | `false` | Allow passcode/PIN fallback for this signing prompt. |
| `promptSubtitle` / `promptDescription` / `cancelButtonText` | `String` | platform default | Customize the system prompt's copy. |
| `persistAcrossBackgrounding` | `bool` | `false` | Auto-retry the whole sign call (including re-acquiring the platform crypto handle) if backgrounded mid-prompt. |

### `IdentityDecryptConfig` (`decryptPayload`)

Same shape as `IdentitySignatureConfig`: `allowDeviceCredentials`, `promptSubtitle`,
`promptDescription`, `cancelButtonText`, `persistAcrossBackgrounding` — identical semantics, applied
to the decrypt call.

### `PresencePromptConfig` (`verifyPresence`)

| Field | Type | Default | What it does |
|---|---|---|---|
| `allowDeviceCredentials` | `bool` | `false` | Allow passcode/PIN as a fallback. |
| `biometricStrength` | `IdentityBiometricStrength` | `strong` | Require `strong` or accept `weak` biometric classes (Android). |
| `subtitle` / `promptDescription` / `cancelButtonText` | `String` | platform default | Customize the system prompt's copy. |
| `sensitiveTransaction` | `bool` | `false` | **Android only.** Require an explicit confirmation gesture after a passive biometric match (e.g. passive Face Unlock), so presence can't be confirmed without active user intent. No effect on iOS/macOS/Windows. |
| `persistAcrossBackgrounding` | `bool` | `false` | Auto-retry the presence check if backgrounded mid-prompt. |

### Output formats

Every method that returns key material or a signature lets you pick the encoding:

- `IdentityKeyFormat` — `base64` (default), `pem`, `hex`, `raw`
- `IdentitySignatureFormat` — `base64` (default), `hex`, `raw`
- `IdentityPayloadFormat` (decrypt input) — `base64` (default), `hex`, `raw`

Raw bytes are always available too, independent of the chosen string format, via the `*Bytes`
fields on the result objects (`publicKeyBytes`, `signatureBytes`).

### Named identities

Every stateful method accepts an optional `keyAlias`. Omit it to use a single default identity, or
pass distinct aliases to maintain multiple independent identities in one app:

```dart
await plugin.enrollIdentity(keyAlias: 'login_key');
await plugin.enrollIdentity(keyAlias: 'payment_key');
```

## Error Handling

Every result carries a standardized `IdentityError` code — see its doc comments in
[`pigeons/identity_messages.dart`](pigeons/identity_messages.dart) (or your IDE's autocomplete on
`IdentityError`) for the full, current list and exactly what triggers each one; it's kept there
rather than duplicated here so this list can't drift out of sync as codes are added.

For convenience, an `IdentityErrorX` extension ships with the package:

```dart
if (!result.code!.isRecoverable) {
  showDialog(context: context, child: Text(result.code!.userMessage));
}
```

- `isRecoverable` — whether retrying the same call again immediately has a reasonable chance of
  succeeding.
- `userMessage` — a short, generic English fallback message (apps with localization should treat
  this as a last resort, not a primary copy source).

## Platform Support

| Feature | Android | iOS | macOS | Windows |
|---|---|---|---|---|
| `verifyPresence` | ✅ | ✅ | ✅ | ⚠️ stub |
| `enrollIdentity` / `signPayload` | ✅ | ✅ | ✅ | ✅ (RSA only) |
| `decryptPayload` | ✅ | ✅ | ✅ | ⚠️ relies on an **unsupported, undocumented** Windows API — see [CLAUDE.md](CLAUDE.md) before depending on it |
| `onIdentityChanged` (re-enrollment detection) | ✅ | ✅ | ✅ | ❌ no event channel |
| `stopAuthentication` | ✅ | ✅ | ✅ | ❌ not supported |
| `getIdentityStatus` / `revokeIdentity` / `isDeviceSecure` | ✅ | ✅ | ✅ | ⚠️ stub |

Android and iOS are the complete, actively maintained implementations. macOS shares the iOS
implementation and has the same feature set. Windows is a partial implementation — see
[CLAUDE.md](CLAUDE.md) for the exact stub list and the Windows decrypt caveat before relying on it
in production.

## Limitations & Important Notes

- **Simulator limitations**: biometric authentication and secure hardware (Secure
  Enclave/StrongBox) cannot be fully exercised on simulators/emulators — a physical device with
  biometrics enrolled is required for meaningful testing.
- **Passcode requirement**: biometrics cannot be enabled or used unless a device passcode/lock is
  set. If the user removes their device passcode, all enrolled identities are permanently
  invalidated.
- **Biometric enrollment changes**: identities enrolled with `setInvalidatedByBiometricEnrollment:
  true` (the default) are invalidated when the device's enrolled biometrics change — listen on
  [`onIdentityChanged`](#8-react-to-biometric-enrollment-changes) rather than discovering this on
  a failed sign/decrypt call.
- **Lockout reset**: a biometric lockout can only be cleared by the user successfully entering
  their device passcode — there is no way to reset it programmatically without user interaction.
- **Hardware variation**: the plugin prefers StrongBox (Android) / Secure Enclave (iOS/macOS)
  automatically, falling back to the standard TEE/Keystore when specialized hardware isn't
  available on the device — no code changes needed either way.

## Documentation

- **This README** — installation, usage, and the full configuration reference.
- **[CLAUDE.md](CLAUDE.md)** — architecture deep-dive: how the Pigeon codegen pipeline works, how
  each platform implements hybrid RSA/EC crypto, the exact Windows stub list, and error-code
  mapping details. Start here if you're contributing or need to understand *why* something behaves
  the way it does on a specific platform.
- **[CHANGELOG.md](CHANGELOG.md)** — what changed in each release.
- **[`example/`](example/)** — a full demo app exercising every feature above (presence, enrollment,
  signing, decryption, key management, identity-change detection, prompt cancellation) across three
  pages — the fastest way to see real code for any feature in this README.
- **API reference** — every type and method is documented inline in
  [`pigeons/identity_messages.dart`](pigeons/identity_messages.dart), the single source of truth
  for the plugin's public contract; your IDE's autocomplete/quick-docs will surface the same text.

## Developer Contact

For support, feature requests, or business inquiries, please visit our
[Web Portal](https://hireamit.web.app/).

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
