import '../local_biometric_api.pigeon.dart';

/// Ergonomic helpers over [IdentityError].
///
/// Both getters use an exhaustive `switch` expression with no `_` fallback arm, so adding a new
/// [IdentityError] value in `pigeons/identity_messages.dart` causes a compile error here until
/// this extension is updated too -- a deliberate guardrail against silently mis-classifying a new
/// error code as `unknown`.
extension IdentityErrorX on IdentityError {
  /// Whether retrying the same operation again immediately has a reasonable chance of succeeding.
  ///
  /// `false` for errors where an identical retry will just fail again the same way (the key is
  /// gone, the device isn't secure, lockouts need time/a different auth method to clear, etc).
  bool get isRecoverable {
    switch (this) {
      case IdentityError.success:
      case IdentityError.userCanceled:
      case IdentityError.authenticationFailed:
      case IdentityError.systemCanceled:
      case IdentityError.promptError:
      case IdentityError.notInteractive:
        return true;
      case IdentityError.notAvailable:
      case IdentityError.notEnrolled:
      case IdentityError.lockedOut:
      case IdentityError.lockedOutPermanent:
      case IdentityError.keyNotFound:
      case IdentityError.keyInvalidated:
      case IdentityError.unknown:
      case IdentityError.invalidInput:
      case IdentityError.securityUpdateRequired:
      case IdentityError.notSupported:
      case IdentityError.keyAlreadyExists:
      case IdentityError.passcodeNotSet:
        return false;
    }
  }

  /// A short, generic, English description suitable as a fallback UI message. Apps with
  /// localization should treat this as a last resort, not a primary source of user-facing copy.
  String get userMessage {
    switch (this) {
      case IdentityError.success:
        return 'Success.';
      case IdentityError.userCanceled:
        return 'Authentication was canceled.';
      case IdentityError.notAvailable:
        return 'Biometric authentication is not available right now.';
      case IdentityError.notEnrolled:
        return 'No biometrics are enrolled on this device.';
      case IdentityError.lockedOut:
        return 'Too many attempts. Try again later.';
      case IdentityError.lockedOutPermanent:
        return 'Biometric authentication is locked. Use your device passcode to unlock it.';
      case IdentityError.keyNotFound:
        return 'No identity was found for this request.';
      case IdentityError.keyInvalidated:
        return 'This identity is no longer valid and must be re-enrolled.';
      case IdentityError.unknown:
        return 'An unknown error occurred.';
      case IdentityError.invalidInput:
        return 'The request was invalid.';
      case IdentityError.securityUpdateRequired:
        return 'A security update is required before biometric authentication can be used.';
      case IdentityError.notSupported:
        return 'This operation is not supported on this device.';
      case IdentityError.systemCanceled:
        return 'Authentication was interrupted by the system.';
      case IdentityError.promptError:
        return 'The authentication prompt could not be shown.';
      case IdentityError.keyAlreadyExists:
        return 'An identity already exists for this alias.';
      case IdentityError.passcodeNotSet:
        return 'A device passcode must be set to use this feature.';
      case IdentityError.authenticationFailed:
        return "That didn't match. Try again.";
      case IdentityError.notInteractive:
        return 'Authentication could not be shown right now.';
    }
  }
}
