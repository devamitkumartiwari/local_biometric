import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/local_biometric_api.pigeon.dart',
    dartOptions: DartOptions(),
    kotlinOut:
        'android/src/main/kotlin/com/amit/local_biometric/LocalBiometricApi.kt',
    kotlinOptions: KotlinOptions(package: 'com.amit.local_biometric'),
    swiftOut:
        'ios/local_biometric/Sources/local_biometric/LocalBiometricApi.swift',
    swiftOptions: SwiftOptions(),
    cppSourceOut: 'windows/local_biometric_api.g.cpp',
    cppHeaderOut: 'windows/local_biometric_api.g.h',
    cppOptions: CppOptions(namespace: 'local_biometric'),
  ),
)
/// Standardized error codes for the plugin.
enum IdentityError {
  success,
  userCanceled,
  notAvailable,
  notEnrolled,
  lockedOut,
  lockedOutPermanent,
  keyNotFound,
  keyInvalidated,
  unknown,
  invalidInput,
  securityUpdateRequired,
  notSupported,
  systemCanceled,
  promptError,
  keyAlreadyExists,
  passcodeNotSet,

  /// A single authentication attempt failed (e.g. wrong fingerprint/face) but the operation is
  /// safe to retry immediately -- distinct from [lockedOut]/[lockedOutPermanent], which mean
  /// retrying won't help until the lockout clears. On iOS/macOS this maps to `LAError
  /// .authenticationFailed`. On Android, AndroidX `BiometricPrompt` reports a single failed
  /// attempt via the non-terminal `onAuthenticationFailed()` callback (the prompt stays open and
  /// the user can retry without the call completing at all) rather than any terminal error code
  /// this plugin currently surfaces a result for, so this case is expected to be rare in
  /// practice there -- see LocalBiometricErrorMapper.kt.
  authenticationFailed,

  /// The system could not display the authentication UI at all (e.g. the app was backgrounded at
  /// the moment the prompt would have appeared) -- distinct from [systemCanceled], which means a
  /// prompt that *was* showing got interrupted. Maps to `LAError.notInteractive` on iOS/macOS.
  notInteractive,
}

/// The type of authentication that was used.
enum IdentityAuthType { credential, biometric, unknown }

/// Types of biometric authentication supported.
enum IdentityBiometricType { face, fingerprint, iris, multiple, unavailable }

/// Biometric authentication strength level.
enum IdentityBiometricStrength { strong, weak }

/// The cryptographic algorithm to use.
enum IdentitySignatureType { rsa, ecdsa }

/// Output format for public keys.
enum IdentityKeyFormat { base64, pem, hex, raw }

/// Output format for cryptographic signatures.
enum IdentitySignatureFormat { base64, hex, raw }

/// Input format for encrypted payloads.
enum IdentityPayloadFormat { base64, hex, raw }

/// Status of the biometric identity.
enum IdentityStatus { valid, changed, unavailable }

class IdentityAvailability {
  bool? canAuthenticate;
  bool? hasEnrolledBiometrics;
  List<IdentityBiometricType?>? availableBiometrics;
  String? reason;
}

class IdentityEnrollmentResult {
  String? publicKey;
  Uint8List? publicKeyBytes;
  String? error;
  IdentityError? code;
  String? algorithm;
  int? keySize;
  String? decryptingPublicKey;
  String? decryptingAlgorithm;
  int? decryptingKeySize;
  bool? isHybridMode;
  IdentityAuthType? authenticationType;
}

class IdentitySignatureResult {
  String? signature;
  Uint8List? signatureBytes;
  String? publicKey;
  String? error;
  IdentityError? code;
  String? algorithm;
  int? keySize;
  IdentityAuthType? authenticationType;
}

class IdentityDecryptResult {
  String? decryptedData;
  String? error;
  IdentityError? code;
  IdentityAuthType? authenticationType;
}

class IdentityInfo {
  bool? exists;
  bool? isValid;
  String? algorithm;
  int? keySize;
  bool? isHybridMode;
  String? publicKey;
  String? decryptingPublicKey;
  String? decryptingAlgorithm;
  int? decryptingKeySize;
}

class IdentityEnrollmentConfig {
  IdentitySignatureType? signatureType;
  bool? enforceBiometric;
  bool? setInvalidatedByBiometricEnrollment;
  bool? useDeviceCredentials;
  bool? enableDecryption;
  String? promptSubtitle;
  String? promptDescription;
  String? cancelButtonText;
  bool? failIfExists;

  /// WARNING -- security-model change: when `false`, the generated key requires NO biometric or
  /// device-credential gating to sign/decrypt with it ("device has the key" binding only, not
  /// "user is present"). Defaults to `true` (today's behavior: every operation is biometric/
  /// credential-gated) when unset. When `false`, [setInvalidatedByBiometricEnrollment] has no
  /// effect (a key with no auth requirement can't be "invalidated by re-enrollment" in the same
  /// sense). Intended for background/silent operations (e.g. periodic device-attestation pings)
  /// where prompting every time is undesirable -- do not use this as a default for anything that
  /// signs/decrypts user-facing or security-sensitive data.
  bool? requireAuthentication;

  /// If an app-backgrounding interruption cancels the prompt this call would have shown, retry
  /// the ENTIRE operation from scratch on foreground rather than failing with `systemCanceled`.
  /// "From scratch" is deliberate: a retried enrollIdentity call is not resuming a half-created
  /// key, it starts over. Defaults to `false` (today's behavior) when unset. No effect on Windows.
  bool? persistAcrossBackgrounding;
}

class IdentitySignatureConfig {
  String? promptSubtitle;
  String? promptDescription;
  String? cancelButtonText;
  bool? allowDeviceCredentials;

  /// See [IdentityEnrollmentConfig.persistAcrossBackgrounding]. For signing, "from scratch" means
  /// the whole signPayload/signPayloadBytes call -- including re-acquiring the platform crypto
  /// handle (e.g. Android's `Cipher`/`Signature` `CryptoObject`, which is not safely resumable
  /// after a backgrounding interruption) -- is retried, not silently resumed. Defaults to `false`.
  bool? persistAcrossBackgrounding;
}

class IdentityDecryptConfig {
  String? promptSubtitle;
  String? promptDescription;
  String? cancelButtonText;
  bool? allowDeviceCredentials;

  /// See [IdentitySignatureConfig.persistAcrossBackgrounding]; same "retry the whole decrypt call
  /// from scratch" semantic applies here. Defaults to `false`.
  bool? persistAcrossBackgrounding;
}

class PresencePromptConfig {
  String? subtitle;
  String? promptDescription;
  String? cancelButtonText;
  bool? allowDeviceCredentials;
  IdentityBiometricStrength? biometricStrength;

  /// See [IdentityEnrollmentConfig.persistAcrossBackgrounding]. For a presence check this simply
  /// means the prompt reappears and the original call resolves once the user completes it --
  /// there is no crypto operation to worry about resuming. Defaults to `false`.
  bool? persistAcrossBackgrounding;

  /// Android only: forces an explicit user confirmation step after a passive biometric match
  /// (e.g. passive Face Unlock), so presence can't be confirmed without an active user gesture.
  /// Maps to `BiometricPrompt.PromptInfo.Builder.setConfirmationRequired`. No effect on iOS/macOS
  /// (LocalAuthentication has no equivalent flag) or Windows. Defaults to `false`/unset, which
  /// preserves today's behavior.
  bool? sensitiveTransaction;
}

class PresencePromptResult {
  bool? success;
  String? error;
  IdentityError? code;
  IdentityAuthType? authenticationType;
}

@HostApi()
abstract class LocalBiometricApi {
  @async
  IdentityAvailability checkAvailability();

  @async
  IdentityEnrollmentResult enrollIdentity(
    String? keyAlias,
    IdentityEnrollmentConfig? config,
    IdentityKeyFormat keyFormat,
    String? promptMessage,
  );

  @async
  IdentitySignatureResult signPayload(
    String payload,
    String? keyAlias,
    IdentitySignatureConfig? config,
    IdentitySignatureFormat signatureFormat,
    IdentityKeyFormat keyFormat,
    String? promptMessage,
  );

  @async
  IdentitySignatureResult signPayloadBytes(
    Uint8List payload,
    String? keyAlias,
    IdentitySignatureConfig? config,
    IdentitySignatureFormat signatureFormat,
    IdentityKeyFormat keyFormat,
    String? promptMessage,
  );

  @async
  IdentityDecryptResult decryptPayload(
    String payload,
    String? keyAlias,
    IdentityPayloadFormat payloadFormat,
    IdentityDecryptConfig? config,
    String? promptMessage,
  );

  @async
  bool revokeIdentity(String? keyAlias);

  @async
  bool revokeAllIdentities();

  @async
  IdentityInfo getIdentityStatus(
    String? keyAlias,
    bool checkValidity,
    IdentityKeyFormat keyFormat,
  );

  @async
  PresencePromptResult verifyPresence(
    String promptMessage,
    PresencePromptConfig? config,
  );

  @async
  bool isDeviceSecure();

  @async
  void acknowledgeIdentityChange();

  /// Cancels whatever biometric/credential prompt is currently in flight (from any of the
  /// prompt-issuing methods above), if any. Returns `true` if a prompt was actually canceled,
  /// `false` if none was in flight or cancellation isn't supported on this platform (not
  /// supported on Windows).
  @async
  bool stopAuthentication();
}
