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
        cryptoObject: BiometricPrompt.CryptoObject?
    ): LocalAuthOutcome.Success = suspendCancellableCoroutine { cont ->
        val auths = getAuthenticators(allowDeviceCredentials)
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                if (cont.isActive) cont.resume(LocalAuthOutcome.Success(result.cryptoObject, mapAuthType(result.authenticationType)))
            }
            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                if (cont.isActive) cont.resumeWithException(SecurityException("$errString", Throwable(errorCode.toString())))
            }
        }

        val promptInfo = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setAllowedAuthenticators(auths)
            .apply {
                if (!subtitle.isNullOrBlank()) setSubtitle(subtitle)
                if (!description.isNullOrBlank()) setDescription(description)
                if (!(allowDeviceCredentials && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)) {
                    setNegativeButtonText(cancelText)
                }
            }
            .build()

        activity.runOnUiThread {
            try {
                activity.setTheme(androidx.appcompat.R.style.Theme_AppCompat_Light_DarkActionBar)
                val prompt = BiometricPrompt(activity, ContextCompat.getMainExecutor(activity), callback)
                if (cryptoObject != null) prompt.authenticate(promptInfo, cryptoObject)
                else prompt.authenticate(promptInfo)
            } catch (e: Exception) {
                if (cont.isActive) cont.resumeWithException(e)
            }
        }
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
