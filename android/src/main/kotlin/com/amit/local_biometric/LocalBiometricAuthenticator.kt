package com.amit.local_biometric

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

sealed interface LocalAuthOutcome {
    data class Success(val cryptoObject: BiometricPrompt.CryptoObject?, val authType: IdentityAuthType) : LocalAuthOutcome
}

class LocalBiometricAuthenticator(private val context: Context) {

    private var currentPrompt: BiometricPrompt? = null
    private var currentContinuation: kotlinx.coroutines.CancellableContinuation<LocalAuthOutcome.Success>? = null

    fun detectBiometricTypes(): List<IdentityBiometricType> {
        val pm = context.packageManager
        val bm = BiometricManager.from(context)
        if (bm.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) != BiometricManager.BIOMETRIC_SUCCESS) return emptyList()

        val types = mutableListOf<IdentityBiometricType>()
        if (pm.hasSystemFeature(PackageManager.FEATURE_FACE)) types.add(IdentityBiometricType.FACE)
        if (pm.hasSystemFeature(PackageManager.FEATURE_FINGERPRINT)) types.add(IdentityBiometricType.FINGERPRINT)
        if (pm.hasSystemFeature(PackageManager.FEATURE_IRIS)) types.add(IdentityBiometricType.IRIS)

        return types
    }

    suspend fun authenticate(
        activity: FragmentActivity,
        title: String,
        subtitle: String?,
        description: String?,
        cancelText: String,
        allowDeviceCredentials: Boolean,
        cryptoObject: BiometricPrompt.CryptoObject?,
        sensitiveTransaction: Boolean = false
    ): LocalAuthOutcome.Success = suspendCancellableCoroutine { cont ->
        currentContinuation = cont
        val auths = getAuthenticators(allowDeviceCredentials)
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                if (cont.isActive) cont.resume(LocalAuthOutcome.Success(result.cryptoObject, mapAuthType(result.authenticationType)))
                clearIfCurrent(cont)
            }
            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                if (cont.isActive) cont.resumeWithException(SecurityException("$errString", Throwable(errorCode.toString())))
                clearIfCurrent(cont)
            }
        }

        val promptInfo = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setAllowedAuthenticators(auths)
            .apply {
                if (!subtitle.isNullOrBlank()) setSubtitle(subtitle)
                if (!description.isNullOrBlank()) setDescription(description)
                if (sensitiveTransaction) setConfirmationRequired(true)
                if (!(allowDeviceCredentials && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)) {
                    setNegativeButtonText(cancelText)
                }
            }
            .build()

        activity.runOnUiThread {
            try {
                activity.setTheme(androidx.appcompat.R.style.Theme_AppCompat_Light_DarkActionBar)
                val prompt = BiometricPrompt(activity, ContextCompat.getMainExecutor(activity), callback)
                currentPrompt = prompt
                if (cryptoObject != null) prompt.authenticate(promptInfo, cryptoObject)
                else prompt.authenticate(promptInfo)
            } catch (e: Exception) {
                if (cont.isActive) cont.resumeWithException(e)
                clearIfCurrent(cont)
            }
        }

        cont.invokeOnCancellation { clearIfCurrent(cont) }
    }

    private fun clearIfCurrent(cont: kotlinx.coroutines.CancellableContinuation<*>) {
        if (currentContinuation === cont) {
            currentContinuation = null
            currentPrompt = null
        }
    }

    // Resumes the in-flight authenticate() call, if any, with a `userCanceled`-coded failure
    // (raw code "10", the same one BiometricPrompt itself uses for a user-pressed cancel button)
    // *before* telling BiometricPrompt to dismiss. This disambiguates an explicit
    // stopAuthentication() call from BiometricPrompt's own `ERROR_CANCELED` (5), which *also*
    // fires when the system dismisses the prompt because the app was backgrounded (mapped
    // separately, to `systemCanceled`, in LocalBiometricErrorMapper) -- both would otherwise
    // arrive as the exact same raw error code with no way to tell them apart.
    fun stopAuthentication(): Boolean {
        val cont = currentContinuation ?: return false
        val prompt = currentPrompt
        currentContinuation = null
        currentPrompt = null
        if (cont.isActive) {
            cont.resumeWithException(SecurityException("Stopped by caller", Throwable("10")))
        }
        prompt?.cancelAuthentication()
        return true
    }

    fun getAuthenticators(allowDeviceCredentials: Boolean, strength: IdentityBiometricStrength = IdentityBiometricStrength.STRONG): Int {
        val bio = if (strength == IdentityBiometricStrength.STRONG) BiometricManager.Authenticators.BIOMETRIC_STRONG else BiometricManager.Authenticators.BIOMETRIC_WEAK
        return if (allowDeviceCredentials && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) bio or BiometricManager.Authenticators.DEVICE_CREDENTIAL else bio
    }

    private fun mapAuthType(type: Int): IdentityAuthType {
        return when (type) {
            BiometricPrompt.AUTHENTICATION_RESULT_TYPE_BIOMETRIC -> IdentityAuthType.BIOMETRIC
            BiometricPrompt.AUTHENTICATION_RESULT_TYPE_DEVICE_CREDENTIAL -> IdentityAuthType.CREDENTIAL
            else -> IdentityAuthType.UNKNOWN
        }
    }
}
