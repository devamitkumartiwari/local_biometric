package com.amit.local_biometric

import android.content.Context
import androidx.fragment.app.FragmentActivity
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import kotlinx.coroutines.*
import java.security.*
import javax.crypto.Cipher
import kotlin.coroutines.cancellation.CancellationException

class LocalBiometricPlugin : FlutterPlugin, LocalBiometricApi, ActivityAware {

    private lateinit var appContext: Context
    private var activity: FragmentActivity? = null
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    private lateinit var identityManager: LocalBiometricManager
    private lateinit var cryptoProvider: LocalCryptographyProvider
    private lateinit var authenticator: LocalBiometricAuthenticator
    private lateinit var changeMonitor: LocalIdentityChangeMonitor

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        identityManager = LocalBiometricManager(appContext)
        cryptoProvider = LocalCryptographyProvider(appContext)
        authenticator = LocalBiometricAuthenticator(appContext)
        changeMonitor = LocalIdentityChangeMonitor(appContext, identityManager)

        LocalBiometricApi.setUp(binding.binaryMessenger, this)
        EventChannel(binding.binaryMessenger, "com.amit.local_biometric/changes")
            .setStreamHandler(changeMonitor)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        LocalBiometricApi.setUp(binding.binaryMessenger, null)
        scope.cancel()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity as? FragmentActivity
        activity?.lifecycle?.addObserver(changeMonitor)
    }

    override fun onDetachedFromActivity() {
        activity?.lifecycle?.removeObserver(changeMonitor)
        activity = null
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    // --- API Implementation ---

    override fun checkAvailability(callback: (Result<IdentityAvailability>) -> Unit) {
        val bm = androidx.biometric.BiometricManager.from(appContext)
        val canAuth = bm.canAuthenticate(androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG)
        
        val available = canAuth == androidx.biometric.BiometricManager.BIOMETRIC_SUCCESS
        val enrolled = canAuth != androidx.biometric.BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED &&
                      canAuth != androidx.biometric.BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE
        
        callback(Result.success(IdentityAvailability(
            canAuthenticate = available,
            hasEnrolledBiometrics = enrolled,
            availableBiometrics = authenticator.detectBiometricTypes(),
            reason = if (!available) LocalBiometricErrorMapper.biometricErrorName(canAuth) else null
        )))
    }

    override fun enrollIdentity(
        keyAlias: String?,
        config: IdentityEnrollmentConfig?,
        keyFormat: IdentityKeyFormat,
        promptMessage: String?,
        callback: (Result<IdentityEnrollmentResult>) -> Unit
    ) {
        val act = activity ?: return callback(Result.success(IdentityEnrollmentResult(code = IdentityError.UNKNOWN, error = "Activity required")))
        
        scope.launch {
            try {
                if (config?.failIfExists == true && identityManager.keyExists(keyAlias)) {
                    return@launch callback(Result.success(IdentityEnrollmentResult(code = IdentityError.KEY_ALREADY_EXISTS, error = "Identity already exists")))
                }

                val useCreds = config?.useDeviceCredentials ?: false
                val invalidate = config?.setInvalidatedByBiometricEnrollment ?: true
                val sigType = config?.signatureType ?: IdentitySignatureType.RSA
                val enforceBio = config?.enforceBiometric ?: false
                
                var authType: IdentityAuthType? = null
                if (enforceBio) {
                    val outcome = authenticator.authenticate(act, promptMessage ?: "Enroll Identity", config?.promptSubtitle, config?.promptDescription, config?.cancelButtonText ?: "Cancel", useCreds, null)
                    authType = outcome.authType
                }

                val kp = if (sigType == IdentitySignatureType.RSA) {
                    identityManager.generateRsaKey(keyAlias, useCreds, invalidate, config?.enableDecryption ?: false)
                } else {
                    identityManager.generateEcKey(keyAlias, useCreds, invalidate)
                }

                if (config?.enableDecryption == true && sigType == IdentitySignatureType.ECDSA) {
                    identityManager.generateMasterKey(keyAlias, useCreds, invalidate)
                    val cipher = cryptoProvider.getMasterCipherForEncryption(keyAlias)
                    val outcome = authenticator.authenticate(act, promptMessage ?: "Secure Identity", config?.promptSubtitle, config?.promptDescription, config?.cancelButtonText ?: "Cancel", useCreds, androidx.biometric.BiometricPrompt.CryptoObject(cipher))
                    val (wrapped, pub) = cryptoProvider.sealDecryptionKey(outcome.cryptoObject!!.cipher!!)
                    
                    java.io.File(appContext.filesDir, LocalBiometricConstants.ecWrappedFilename(keyAlias)).writeBytes(wrapped)
                    java.io.File(appContext.filesDir, LocalBiometricConstants.ecPubFilename(keyAlias)).writeBytes(pub)
                    
                    val decryptPub = KeyFactory.getInstance("EC").generatePublic(java.security.spec.X509EncodedKeySpec(pub))
                    callback(Result.success(buildEnrollmentResponse(kp.public, keyFormat, decryptPub, outcome.authType)))
                } else {
                    callback(Result.success(buildEnrollmentResponse(kp.public, keyFormat, null, authType)))
                }
            } catch (e: Exception) {
                callback(Result.success(IdentityEnrollmentResult(code = LocalBiometricErrorMapper.mapToIdentityError(e), error = LocalBiometricErrorMapper.safeErrorMessage(e))))
            }
        }
    }

    override fun signPayload(
        payload: String,
        keyAlias: String?,
        config: IdentitySignatureConfig?,
        signatureFormat: IdentitySignatureFormat,
        keyFormat: IdentityKeyFormat,
        promptMessage: String?,
        callback: (Result<IdentitySignatureResult>) -> Unit
    ) {
        signPayloadInternal(payload.toByteArray(), keyAlias, config, signatureFormat, keyFormat, promptMessage, callback)
    }

    override fun signPayloadBytes(
        payload: ByteArray,
        keyAlias: String?,
        config: IdentitySignatureConfig?,
        signatureFormat: IdentitySignatureFormat,
        keyFormat: IdentityKeyFormat,
        promptMessage: String?,
        callback: (Result<IdentitySignatureResult>) -> Unit
    ) {
        signPayloadInternal(payload, keyAlias, config, signatureFormat, keyFormat, promptMessage, callback)
    }

    private fun signPayloadInternal(
        data: ByteArray,
        alias: String?,
        config: IdentitySignatureConfig?,
        sigFormat: IdentitySignatureFormat,
        keyFormat: IdentityKeyFormat,
        prompt: String?,
        callback: (Result<IdentitySignatureResult>) -> Unit
    ) {
        val act = activity ?: return callback(Result.success(IdentitySignatureResult(code = IdentityError.UNKNOWN, error = "Activity required")))
        scope.launch {
            try {
                val mode = identityManager.inferKeyMode(alias) ?: throw SecurityException("Identity not found")
                val allowCreds = config?.allowDeviceCredentials ?: false
                
                var attempt = 0
                while (true) {
                    try {
                        val crypto = cryptoProvider.prepareSignature(alias, mode)
                        val outcome = authenticator.authenticate(act, prompt ?: "Sign", config?.promptSubtitle, config?.promptDescription, config?.cancelButtonText ?: "Cancel", allowCreds, crypto)
                        
                        val sig = outcome.cryptoObject!!.signature!!
                        sig.update(data)
                        val sigBytes = sig.sign()
                        
                        val pub = cryptoProvider.getPublicKey(alias)
                        callback(Result.success(buildSignatureResponse(sigBytes, pub, sigFormat, keyFormat, outcome.authType)))
                        break
                    } catch (e: Exception) {
                        if (attempt < 1 && LocalBiometricErrorMapper.isPrunedOperationError(e)) {
                            attempt++
                            continue
                        }
                        throw e
                    }
                }
            } catch (e: Exception) {
                callback(Result.success(IdentitySignatureResult(code = LocalBiometricErrorMapper.mapToIdentityError(e), error = LocalBiometricErrorMapper.safeErrorMessage(e))))
            }
        }
    }

    override fun decryptPayload(
        payload: String,
        keyAlias: String?,
        payloadFormat: IdentityPayloadFormat,
        config: IdentityDecryptConfig?,
        promptMessage: String?,
        callback: (Result<IdentityDecryptResult>) -> Unit
    ) {
        val act = activity ?: return callback(Result.success(IdentityDecryptResult(code = IdentityError.UNKNOWN, error = "Activity required")))
        scope.launch {
            try {
                val mode = identityManager.inferKeyMode(keyAlias) ?: throw SecurityException("Identity not found")
                val allowCreds = config?.allowDeviceCredentials ?: false
                val prompt = promptMessage ?: "Decrypt"

                val result = when (mode) {
                    LocalKeyMode.RSA -> {
                        val ks = KeyStore.getInstance(LocalBiometricConstants.KEYSTORE_PROVIDER).apply { load(null) }
                        val entry = ks.getEntry(LocalBiometricConstants.identityKeyAlias(keyAlias), null) as KeyStore.PrivateKeyEntry
                        val cipher = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding").apply { init(Cipher.DECRYPT_MODE, entry.privateKey) }
                        val outcome = authenticator.authenticate(act, prompt, config?.promptSubtitle, config?.promptDescription, config?.cancelButtonText ?: "Cancel", allowCreds, androidx.biometric.BiometricPrompt.CryptoObject(cipher))
                        val decrypted = outcome.cryptoObject!!.cipher!!.doFinal(LocalBiometricFormatUtils.parsePayload(payload, payloadFormat))
                        IdentityDecryptResult(decryptedData = String(decrypted), code = IdentityError.SUCCESS, authenticationType = outcome.authType)
                    }
                    LocalKeyMode.HYBRID_EC -> {
                        val cipher = cryptoProvider.getMasterCipherForDecryption(keyAlias) ?: throw SecurityException("Master key missing")
                        val outcome = authenticator.authenticate(act, prompt, config?.promptSubtitle, config?.promptDescription, config?.cancelButtonText ?: "Cancel", allowCreds, androidx.biometric.BiometricPrompt.CryptoObject(cipher))
                        val decrypted = cryptoProvider.performHybridDecryption(keyAlias, outcome.cryptoObject!!.cipher!!, payload, payloadFormat)
                        IdentityDecryptResult(decryptedData = decrypted, code = IdentityError.SUCCESS, authenticationType = outcome.authType)
                    }
                    else -> throw SecurityException("Identity does not support decryption")
                }
                callback(Result.success(result))
            } catch (e: Exception) {
                callback(Result.success(IdentityDecryptResult(code = LocalBiometricErrorMapper.mapToIdentityError(e), error = LocalBiometricErrorMapper.safeErrorMessage(e))))
            }
        }
    }

    override fun revokeIdentity(keyAlias: String?, callback: (Result<Boolean>) -> Unit) {
        identityManager.deleteIdentity(keyAlias)
        callback(Result.success(true))
    }

    override fun revokeAllIdentities(callback: (Result<Boolean>) -> Unit) {
        identityManager.deleteAllIdentities()
        callback(Result.success(true))
    }

    override fun getIdentityStatus(keyAlias: String?, checkValidity: Boolean, keyFormat: IdentityKeyFormat, callback: (Result<IdentityInfo>) -> Unit) {
        scope.launch {
            try {
                val exists = identityManager.keyExists(keyAlias)
                if (!exists) return@launch callback(Result.success(IdentityInfo(exists = false)))
                
                val pub = cryptoProvider.getPublicKey(keyAlias)
                val mode = identityManager.inferKeyMode(keyAlias)
                
                callback(Result.success(IdentityInfo(
                    exists = true,
                    isValid = true,
                    algorithm = pub.algorithm,
                    keySize = if (pub is java.security.interfaces.RSAKey) pub.modulus.bitLength().toLong() else 256L,
                    isHybridMode = mode == LocalKeyMode.HYBRID_EC,
                    publicKey = LocalBiometricFormatUtils.formatOutput(pub.encoded, keyFormat).value
                )))
            } catch (e: Exception) {
                callback(Result.success(IdentityInfo(exists = false)))
            }
        }
    }

    override fun verifyPresence(promptMessage: String, config: PresencePromptConfig?, callback: (Result<PresencePromptResult>) -> Unit) {
        val act = activity ?: return callback(Result.success(PresencePromptResult(success = false, error = "Activity required", code = IdentityError.PROMPT_ERROR)))
        scope.launch {
            try {
                val allowCreds = config?.allowDeviceCredentials ?: false
                val outcome = authenticator.authenticate(act, promptMessage, config?.subtitle, config?.promptDescription, config?.cancelButtonText ?: "Cancel", allowCreds, null)
                callback(Result.success(PresencePromptResult(success = true, code = IdentityError.SUCCESS, authenticationType = outcome.authType)))
            } catch (e: Exception) {
                callback(Result.success(PresencePromptResult(success = false, error = LocalBiometricErrorMapper.safeErrorMessage(e), code = LocalBiometricErrorMapper.mapToIdentityError(e))))
            }
        }
    }

    override fun isDeviceSecure(callback: (Result<Boolean>) -> Unit) {
        val km = appContext.getSystemService(Context.KEYGUARD_SERVICE) as android.app.KeyguardManager
        callback(Result.success(km.isDeviceSecure))
    }

    override fun acknowledgeIdentityChange(callback: (Result<Unit>) -> Unit) {
        changeMonitor.acknowledgeChange()
        callback(Result.success(Unit))
    }

    private fun buildEnrollmentResponse(pub: PublicKey, format: IdentityKeyFormat, decryptPub: PublicKey?, authType: IdentityAuthType?): IdentityEnrollmentResult {
        val formatted = LocalBiometricFormatUtils.formatOutput(pub.encoded, format)
        return IdentityEnrollmentResult(
            publicKey = formatted.value,
            publicKeyBytes = pub.encoded,
            code = IdentityError.SUCCESS,
            algorithm = pub.algorithm,
            keySize = if (pub is java.security.interfaces.RSAKey) pub.modulus.bitLength().toLong() else 256L,
            decryptingPublicKey = decryptPub?.let { LocalBiometricFormatUtils.formatOutput(it.encoded, format).value },
            isHybridMode = decryptPub != null,
            authenticationType = authType
        )
    }

    private fun buildSignatureResponse(sig: ByteArray, pub: PublicKey, format: IdentitySignatureFormat, keyFormat: IdentityKeyFormat, authType: IdentityAuthType): IdentitySignatureResult {
        val sigStr = if (format == IdentitySignatureFormat.HEX) LocalBiometricFormatUtils.bytesToHex(sig) else android.util.Base64.encodeToString(sig, android.util.Base64.NO_WRAP)
        return IdentitySignatureResult(
            signature = sigStr,
            signatureBytes = sig,
            publicKey = LocalBiometricFormatUtils.formatOutput(pub.encoded, keyFormat).value,
            code = IdentityError.SUCCESS,
            algorithm = pub.algorithm,
            keySize = if (pub is java.security.interfaces.RSAKey) pub.modulus.bitLength().toLong() else 256L,
            authenticationType = authType
        )
    }
}
