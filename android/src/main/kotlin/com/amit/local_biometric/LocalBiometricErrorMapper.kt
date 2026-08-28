package com.amit.local_biometric

import android.security.keystore.KeyPermanentlyInvalidatedException
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt

object LocalBiometricErrorMapper {

    fun mapToIdentityError(e: Throwable): IdentityError {
        if (e is SecurityException) {
            val codeStr = e.cause?.message ?: ""
            when (codeStr) {
                "7" -> return IdentityError.LOCKED_OUT // BiometricPrompt.ERROR_LOCKOUT (Temporary 30s)
                "9" -> return IdentityError.LOCKED_OUT_PERMANENT // BiometricPrompt.ERROR_LOCKOUT_PERMANENT
                "10" -> return IdentityError.USER_CANCELED // BiometricPrompt.ERROR_USER_CANCELED
                "13" -> return IdentityError.USER_CANCELED // BiometricPrompt.ERROR_NEGATIVE_BUTTON
                "11" -> return IdentityError.NOT_ENROLLED // BiometricPrompt.ERROR_NO_BIOMETRICS
                "12" -> return IdentityError.NOT_SUPPORTED // BiometricPrompt.ERROR_HW_NOT_PRESENT
                "1" -> return IdentityError.NOT_AVAILABLE // BiometricPrompt.ERROR_HW_UNAVAILABLE
                "14" -> return IdentityError.PASSCODE_NOT_SET // BiometricPrompt.ERROR_NO_DEVICE_CREDENTIAL
                // BiometricPrompt.ERROR_CANCELED: fires when the system dismisses the prompt out
                // from under the app (e.g. the app was backgrounded mid-prompt). An explicit
                // stopAuthentication() call is resumed directly with code "10" *before* this
                // code can fire (see LocalBiometricAuthenticator.stopAuthentication), so any "5"
                // that actually reaches here was system-initiated, not caller-initiated.
                "5" -> return IdentityError.SYSTEM_CANCELED
            }
        }
        
        return when (e) {
            is KeyPermanentlyInvalidatedException -> IdentityError.KEY_INVALIDATED
            is java.security.UnrecoverableKeyException -> IdentityError.KEY_INVALIDATED
            is java.security.KeyStoreException -> IdentityError.UNKNOWN
            is SecurityException -> {
                val message = e.message ?: ""
                when {
                    message.contains("userCanceled", ignoreCase = true) || message.contains("User canceled", ignoreCase = true) -> IdentityError.USER_CANCELED
                    message.contains("LOCKED_OUT_PERMANENT", ignoreCase = true) -> IdentityError.LOCKED_OUT_PERMANENT
                    message.contains("LOCKED_OUT", ignoreCase = true) -> IdentityError.LOCKED_OUT
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
            7 -> "lockedOut" // BIOMETRIC_ERROR_LOCKOUT
            9 -> "lockedOutPermanent" // BIOMETRIC_ERROR_LOCKOUT_PERMANENT
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
