import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/local_biometric_api.pigeon.dart',
    dartOptions: DartOptions(),
    kotlinOut: 'android/src/main/kotlin/com/amit/local_biometric/LocalBiometricApi.kt',
    kotlinOptions: KotlinOptions(
      package: 'com.amit.local_biometric',
    ),
    swiftOut: 'ios/local_biometric/Sources/local_biometric/LocalBiometricApi.swift',
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
}

/// The type of authentication that was used.
enum IdentityAuthType {
  credential,
  biometric,
  unknown,
}

/// Types of biometric authentication supported.
enum IdentityBiometricType {
  face,
  fingerprint,
  iris,
  multiple,
  unavailable,
}

/// Biometric authentication strength level.
enum IdentityBiometricStrength {
  strong,
  weak,
}

/// The cryptographic algorithm to use.
enum IdentitySignatureType {
  rsa,
  ecdsa,
}

/// Output format for public keys.
enum IdentityKeyFormat {
  base64,
  pem,
  hex,
  raw,
}

/// Output format for cryptographic signatures.
enum IdentitySignatureFormat {
  base64,
  hex,
  raw,
}

/// Input format for encrypted payloads.
enum IdentityPayloadFormat {
  base64,
  hex,
  raw,
}

/// Status of the biometric identity.
enum IdentityStatus {
  valid,
  changed,
  unavailable,
}

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
}

class IdentitySignatureConfig {
  String? promptSubtitle;
  String? promptDescription;
  String? cancelButtonText;
  bool? allowDeviceCredentials;
}

class IdentityDecryptConfig {
  String? promptSubtitle;
  String? promptDescription;
  String? cancelButtonText;
  bool? allowDeviceCredentials;
}

class PresencePromptConfig {
  String? subtitle;
  String? promptDescription;
  String? cancelButtonText;
  bool? allowDeviceCredentials;
  IdentityBiometricStrength? biometricStrength;
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
  IdentityInfo getIdentityStatus(String? keyAlias, bool checkValidity, IdentityKeyFormat keyFormat);

  @async
  PresencePromptResult verifyPresence(
    String promptMessage,
    PresencePromptConfig? config,
  );

  @async
  bool isDeviceSecure();

  @async
  void acknowledgeIdentityChange();
}
