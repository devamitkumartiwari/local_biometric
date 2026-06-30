# local_biometric

A robust, efficient, and performant local biometric identity plugin for Flutter. This plugin provides secure biometric authentication with support for cryptographic signatures (RSA/ECDSA) using the Secure Enclave (iOS) and Keystore (Android).

## Features

- **Simple Authentication**: Quick biometric presence verification.
- **Encrypted Authentication**: Enroll secure identities and sign payloads without exposing private keys.
- **Smart Lockout Recovery**: Proactively detects biometric lockout states and provides a unified flow to re-enable biometrics using the device passcode.
- **Consistent Behavior**: Unified authentication experience across iOS and Android, specifically handling fallback and lockout behaviors consistently.
- **Platform Specifics**: Leverages native security hardware (Secure Enclave/StrongBox).

## Installation

Add `local_biometric` to your `pubspec.yaml`:

```yaml
dependencies:
  local_biometric: ^0.0.2
```

### iOS Configuration

Add `NSFaceIDUsageDescription` to your `Info.plist`:

```xml
<key>NSFaceIDUsageDescription</key>
<string>This app uses Face ID to secure your identities and sign data.</string>
```

### Android Configuration

Ensure your `AndroidManifest.xml` includes the biometric permission:

```xml
<uses-permission android:name="android.permission.USE_BIOMETRIC" />
```

## Usage

### 1. Initialize the Plugin

```dart
final _plugin = LocalBiometric();
```

### 2. Check Availability

Before performing biometric actions, check if the device supports it and if biometrics are enrolled.

```dart
final availability = await _plugin.checkAvailability();
if (availability.canAuthenticate) {
  print("Biometrics are ready!");
} else {
  print("Biometrics unavailable: ${availability.reason}");
}
```

### 3. Simple Authentication (Presence Verification)

Verify the user's presence without using cryptographic keys.

```dart
final result = await _plugin.verifyPresence(
  promptMessage: 'Please confirm your identity',
  config: PresencePromptConfig(
    allowDeviceCredentials: true, // Allow fallback to passcode
  ),
);

if (result.success) {
  print("Authenticated!");
}
```

### 4. Encrypted Authentication (Signing)

#### Enrollment
Create a secure key pair protected by biometrics.

```dart
final result = await _plugin.enrollIdentity(
  keyAlias: 'my_secure_key',
  config: IdentityEnrollmentConfig(
    signatureType: IdentitySignatureType.rsa,
    enforceBiometric: true,
  ),
);
```

#### Signing
Sign data using the enrolled key. This requires biometric authentication by default.

```dart
final result = await _plugin.signPayload(
  payload: 'Data to sign',
  keyAlias: 'my_secure_key',
  config: IdentitySignatureConfig(
    allowDeviceCredentials: false, // Force biometric-only for signing
  ),
);

if (result.code == IdentityError.success) {
  print("Signature: ${result.signature}");
}
```

### 5. Handling Lockouts

If a user fails biometric authentication too many times, the system will lock biometrics. `local_biometric` helps you identify this state.

```dart
if (result.code == IdentityError.lockedOut) {
  // Show a dialog to the user
  // On iOS, verifying the passcode via verifyPresence(allowDeviceCredentials: true)
  // will reset the biometric lockout state.
}
```

## Error Codes

The plugin uses standardized error codes across platforms:

- `success`: Operation completed successfully.
- `userCanceled`: The user dismissed the biometric prompt.
- `lockedOut`: Too many failed attempts. Passcode verification required.
- `notAvailable`: Biometrics are not supported on this device.
- `notEnrolled`: No biometrics are enrolled on the device.
- `keyNotFound`: The requested cryptographic key does not exist.

## Limitations & Important Notes

- **Simulator Limitations**: Biometric authentication and secure hardware (Secure Enclave/StrongBox) cannot be fully tested on simulators. A physical device with biometrics is required for testing.
- **Passcode Requirement**: Biometrics cannot be enabled or used unless a device passcode/lock is set. If the user removes their device passcode, all enrolled identities will be permanently invalidated.
- **Biometric Enrollment Changes**: On iOS, if new biometrics (FaceID/TouchID) are enrolled or existing ones are significantly changed, identities enrolled with `enforceBiometric: true` may be invalidated depending on system policy.
- **Lockout Reset**: A biometric lockout can ONLY be reset by the user successfully entering their device passcode. There is no way to reset this programmatically without user interaction.
- **Hardware Variation**: While the plugin attempts to use the most secure hardware available (StrongBox on Android, Secure Enclave on iOS), it will fall back to standard TEE/Keystore if specialized hardware is not available on the device.

## Developer Contact

For support, feature requests, or business inquiries, please visit our [Web Portal](https://hireamit.web.app/).

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
