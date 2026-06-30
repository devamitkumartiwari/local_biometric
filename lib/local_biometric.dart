import 'dart:async';
import 'package:flutter/services.dart';
import 'local_biometric_api.pigeon.dart';

export 'local_biometric_api.pigeon.dart';

/// A robust, efficient, and performant local biometric identity plugin for Flutter.
///
/// This plugin provides secure biometric authentication with support for
/// cryptographic signatures (RSA/ECDSA) using the Secure Enclave (iOS) and Keystore (Android).
class LocalBiometric {
  final LocalBiometricApi _api = LocalBiometricApi();
  static const EventChannel _eventChannel = EventChannel('com.amit.local_biometric/changes');

  /// Stream of identity status changes.
  ///
  /// Emits a new [IdentityStatus] when the system biometrics state changes
  /// (e.g. new biometrics enrolled).
  Stream<IdentityStatus> get onIdentityChanged {
    return _eventChannel.receiveBroadcastStream().map((event) {
      return IdentityStatus.values[event as int];
    });
  }

  /// Checks if the device supports biometric authentication and if biometrics are enrolled.
  Future<IdentityAvailability> checkAvailability() => _api.checkAvailability();

  /// Enrolls a new secure identity protected by biometrics.
  ///
  /// Creates a persistent key pair in secure hardware (Secure Enclave/StrongBox).
  /// [keyAlias] is a unique identifier for the identity.
  /// [config] allows customizing the enrollment behavior (algorithm, biometric enforcement, etc).
  Future<IdentityEnrollmentResult> enrollIdentity({
    String? keyAlias,
    IdentityEnrollmentConfig? config,
    IdentityKeyFormat keyFormat = IdentityKeyFormat.base64,
    String? promptMessage,
  }) => _api.enrollIdentity(keyAlias, config, keyFormat, promptMessage);

  /// Signs a string payload using an enrolled identity.
  ///
  /// This operation typically triggers a biometric prompt.
  /// [payload] is the data to be signed.
  /// [keyAlias] must match the alias used during enrollment.
  Future<IdentitySignatureResult> signPayload({
    required String payload,
    String? keyAlias,
    IdentitySignatureConfig? config,
    IdentitySignatureFormat signatureFormat = IdentitySignatureFormat.base64,
    IdentityKeyFormat keyFormat = IdentityKeyFormat.base64,
    String? promptMessage,
  }) => _api.signPayload(payload, keyAlias, config, signatureFormat, keyFormat, promptMessage);

  /// Signs raw bytes using an enrolled identity.
  ///
  /// This operation typically triggers a biometric prompt.
  /// [payload] are the bytes to be signed.
  /// [keyAlias] must match the alias used during enrollment.
  Future<IdentitySignatureResult> signPayloadBytes({
    required Uint8List payload,
    String? keyAlias,
    IdentitySignatureConfig? config,
    IdentitySignatureFormat signatureFormat = IdentitySignatureFormat.base64,
    IdentityKeyFormat keyFormat = IdentityKeyFormat.base64,
    String? promptMessage,
  }) => _api.signPayloadBytes(payload, keyAlias, config, signatureFormat, keyFormat, promptMessage);

  /// Decrypts a payload that was encrypted using the public key of an enrolled identity.
  ///
  /// Note: Support for decryption depends on the chosen algorithm and platform.
  Future<IdentityDecryptResult> decryptPayload({
    required String payload,
    String? keyAlias,
    IdentityPayloadFormat payloadFormat = IdentityPayloadFormat.base64,
    IdentityDecryptConfig? config,
    String? promptMessage,
  }) => _api.decryptPayload(payload, keyAlias, payloadFormat, config, promptMessage);

  /// Revokes (deletes) a specific enrolled identity.
  Future<bool> revokeIdentity({String? keyAlias}) => _api.revokeIdentity(keyAlias);

  /// Revokes (deletes) all enrolled identities created by this plugin.
  Future<bool> revokeAllIdentities() => _api.revokeAllIdentities();

  /// Returns the current status and metadata of an enrolled identity.
  ///
  /// If [checkValidity] is true, it performs a hardware check to ensure the key is still valid.
  Future<IdentityInfo> getIdentityStatus({
    String? keyAlias,
    bool checkValidity = false,
    IdentityKeyFormat keyFormat = IdentityKeyFormat.base64,
  }) => _api.getIdentityStatus(keyAlias, checkValidity, keyFormat);

  /// Performs a simple biometric presence check without using cryptographic keys.
  ///
  /// [promptMessage] is the message shown in the biometric dialog.
  /// [config] allows enabling passcode fallback and setting biometric strength.
  Future<PresencePromptResult> verifyPresence({
    required String promptMessage,
    PresencePromptConfig? config,
  }) => _api.verifyPresence(promptMessage, config);

  /// Returns true if the device has a secure lock (passcode, pattern, or biometrics) enabled.
  Future<bool> isDeviceSecure() => _api.isDeviceSecure();

  /// Acknowledges an identity status change reported by [onIdentityChanged].
  Future<void> acknowledgeIdentityChange() => _api.acknowledgeIdentityChange();
}
