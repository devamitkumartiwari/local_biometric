package com.amit.local_biometric

import android.security.keystore.KeyPermanentlyInvalidatedException
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt

object LocalBiometricErrorMapper {

    fun mapToIdentityError(e: Throwable): IdentityError {
        return when (e) {
            is KeyPermanentlyInvalidatedException -> IdentityError.KEY_INVALIDATED
            is java.security.UnrecoverableKeyException -> IdentityError.KEY_INVALIDATED
            is java.security.KeyStoreException -> IdentityError.UNKNOWN
            is SecurityException -> {
                val message = e.message ?: ""
                when {
                    message.contains("userCanceled") || message.contains("User canceled") -> IdentityError.USER_CANCELED
                    message.contains("NOT_AVAILABLE") -> IdentityError.NOT_AVAILABLE
                    message.contains("NOT_ENROLLED") -> IdentityError.NOT_ENROLLED
                    message.contains("LOCKED_OUT_PERMANENT") -> IdentityError.LOCKED_OUT_PERMANENT
                    message.contains("LOCKED_OUT") -> IdentityError.LOCKED_OUT
                    message.contains("ERROR_NO_DEVICE_CREDENTIAL") -> IdentityError.PASSCODE_NOT_SET
                    else -> IdentityError.UNKNOWN
                }
            }
            is IllegalArgumentException -> IdentityError.INVALID_INPUT
            else -> IdentityError.UNKNOWN
        }
    }

    fun safeErrorMessage(e: Throwable): String {
        return e.message ?: e.javaClass.simpleName
    }

    fun biometricErrorName(code: Int): String {
        return when (code) {
            BiometricManager.BIOMETRIC_SUCCESS -> "SUCCESS"
            BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> "NOT_ENROLLED"
            BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE -> "NOT_SUPPORTED"
            BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE -> "NOT_AVAILABLE"
            BiometricManager.BIOMETRIC_ERROR_SECURITY_UPDATE_REQUIRED -> "SECURITY_UPDATE_REQUIRED"
            14 -> "ERROR_NO_DEVICE_CREDENTIAL" // BIOMETRIC_ERROR_NO_DEVICE_CREDENTIAL
            else -> "UNKNOWN ($code)"
        }
    }

    fun mapBiometricManagerError(code: Int, strength: IdentityBiometricStrength): Pair<IdentityError, String> {
        return when (code) {
            BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> IdentityError.NOT_ENROLLED to "No biometrics enrolled"
            BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE -> IdentityError.NOT_SUPPORTED to "Biometric hardware not found"
            BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE -> IdentityError.NOT_AVAILABLE to "Biometric hardware unavailable"
            BiometricManager.BIOMETRIC_ERROR_SECURITY_UPDATE_REQUIRED -> IdentityError.SECURITY_UPDATE_REQUIRED to "Security update required"
            14 -> IdentityError.PASSCODE_NOT_SET to "No device lock configured"
            else -> IdentityError.NOT_AVAILABLE to "Biometric authentication not possible (code $code)"
        }
    }

    fun isPrunedOperationError(e: Throwable): Boolean {
        val msg = e.message ?: ""
        return msg.contains("INVALID_OPERATION_HANDLE") || msg.contains("Pruned")
    }
}
