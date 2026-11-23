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

    companion object {
        private const val MAX_BACKGROUND_RETRIES = 3
    }

    private lateinit var appContext: Context
    private var activity: FragmentActivity? = null
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    private lateinit var identityManager: LocalBiometricManager
    private lateinit var cryptoProvider: LocalCryptographyProvider
    private lateinit var authenticator: LocalBiometricAuthenticator
    private lateinit var changeMonitor: LocalIdentityChangeMonitor
    private var changesChannel: EventChannel? = null
    private val retryObserver = LocalPendingAuthRetryObserver()

    // True when an Activity is attached but it isn't a FragmentActivity (e.g. the app's
    // MainActivity extends FlutterActivity instead of FlutterFragmentActivity). BiometricPrompt
    // needs a FragmentActivity, so prompt-issuing calls fail; this lets them say why.
    private var hostActivityIsNotFragment = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        identityManager = LocalBiometricManager(appContext)
        cryptoProvider = LocalCryptographyProvider(appContext)
        authenticator = LocalBiometricAuthenticator(appContext)
        changeMonitor = LocalIdentityChangeMonitor(appContext, identityManager)

        LocalBiometricApi.setUp(binding.binaryMessenger, this)
        changesChannel = EventChannel(binding.binaryMessenger, "com.amit.local_biometric/changes").apply {
            setStreamHandler(changeMonitor)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        LocalBiometricApi.setUp(binding.binaryMessenger, null)
        changesChannel?.setStreamHandler(null)
        changesChannel = null
        scope.cancel()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity as? FragmentActivity
        hostActivityIsNotFragment = activity == null
        activity?.lifecycle?.addObserver(changeMonitor)
        activity?.lifecycle?.addObserver(retryObserver)
    }

    override fun onDetachedFromActivity() {
        activity?.lifecycle?.removeObserver(changeMonitor)
        activity?.lifecycle?.removeObserver(retryObserver)
        activity = null
        hostActivityIsNotFragment = false
    }

    private fun activityMissingMessage(): String =
        if (hostActivityIsNotFragment) "Activity required: MainActivity must extend FlutterFragmentActivity"
        else "Activity required"

    // Keystore key generation (seconds for RSA on StrongBox), Keystore lookups, file I/O and the
    // post-auth sign/doFinal are blocking binder/disk calls. Pigeon dispatches every method on
    // Dispatchers.Main, so run that work here instead of on the UI thread. Only
    // authenticator.authenticate() (BiometricPrompt) must stay on Main. JCA Signature/Cipher
    // objects aren't thread-bound, so preparing them here and using them after the prompt is safe.
    private suspend fun <T> io(block: () -> T): T = withContext(Dispatchers.IO) { block() }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    // --- API Implementation ---
    //
    // Every method here is `suspend` and returns its result directly (or throws), matching
    // Pigeon 28's default async-throws Kotlin codegen (see LocalBiometricApi.kt's generated
    // `interface LocalBiometricApi`). Note this plugin's own convention: recoverable failures
    // (wrong biometric, lockout, missing key, etc.) are reported *in-band* via the `code`/`error`
    // fields on the returned result object, not by throwing -- Pigeon-level thrown exceptions are
    // reserved for truly exceptional plugin-internal failures. This mirrors the previous
    // callback-based code's behavior (`callback(Result.success(ErrorResult(...)))`, never
    // `Result.failure(...)`), so this migration is a calling-convention change only, not a
    // behavior change.

    // Backs `persistAcrossBackgrounding`. `block` is the entire operation (prompt + crypto), run
    // fresh on every attempt -- never resumed mid-flight, since a backgrounded Cipher/Signature
    // CryptoObject is not guaranteed safely reusable. Bounded at MAX_BACKGROUND_RETRIES so a
    // device stuck rapidly backgrounding/foregrounding can't spin forever.
    private suspend fun <T> withBackgroundRetry(persist: Boolean?, isSystemCanceled: (T) -> Boolean, block: suspend () -> T): T {
        var result = block()
        if (persist != true) return result
        var attempts = 0
        while (isSystemCanceled(result) && attempts < MAX_BACKGROUND_RETRIES) {
            attempts++
            retryObserver.awaitResume()
            result = block()
        }
        return result
    }

    override suspend fun checkAvailability(): IdentityAvailability {
        val bm = androidx.biometric.BiometricManager.from(appContext)
        val canAuth = bm.canAuthenticate(androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG)

        val available = canAuth == androidx.biometric.BiometricManager.BIOMETRIC_SUCCESS
        val enrolled = canAuth != androidx.biometric.BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED &&
                      canAuth != androidx.biometric.BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE

        var reason = if (!available) LocalBiometricErrorMapper.biometricErrorName(canAuth) else null

        // Use raw integer codes for reliability across support library versions
        // 7: BIOMETRIC_ERROR_LOCKOUT, 9: BIOMETRIC_ERROR_LOCKOUT_PERMANENT
        if (canAuth == 7) reason = "lockedOut"
        if (canAuth == 9) reason = "lockedOutPermanent"

        return IdentityAvailability(
            canAuthenticate = available,
            hasEnrolledBiometrics = enrolled,
            availableBiometrics = authenticator.detectBiometricTypes(),
            reason = reason
        )
    }

    override suspend fun enrollIdentity(
        keyAlias: String?,
        config: IdentityEnrollmentConfig?,
        keyFormat: IdentityKeyFormat,
        promptMessage: String?
    ): IdentityEnrollmentResult {
        val act = activity ?: return IdentityEnrollmentResult(code = IdentityError.UNKNOWN, error = activityMissingMessage())

        return withBackgroundRetry(config?.persistAcrossBackgrounding, { it.code == IdentityError.SYSTEM_CANCELED }) {
            try {
                if (config?.failIfExists == true && io { identityManager.keyExists(keyAlias) }) {
                    return@withBackgroundRetry IdentityEnrollmentResult(code = IdentityError.KEY_ALREADY_EXISTS, error = "Identity already exists")
                }

                val useCreds = config?.useDeviceCredentials ?: false
                val invalidate = config?.setInvalidatedByBiometricEnrollment ?: true
                val sigType = config?.signatureType ?: IdentitySignatureType.RSA
                val enforceBio = config?.enforceBiometric ?: false
                val requireAuth = config?.requireAuthentication ?: true

                var authType: IdentityAuthType? = null
                if (enforceBio) {
                    val outcome = authenticator.authenticate(act, promptMessage ?: "Enroll Identity", config?.promptSubtitle, config?.promptDescription, config?.cancelButtonText ?: "Cancel", useCreds, null)
                    authType = outcome.authType
                }

                val kp = io {
                    if (sigType == IdentitySignatureType.RSA) {
                        identityManager.generateRsaKey(keyAlias, useCreds, invalidate, config?.enableDecryption ?: false, requireAuth)
                    } else {
                        identityManager.generateEcKey(keyAlias, useCreds, invalidate, requireAuth)
                    }
                }

                if (config?.enableDecryption == true && sigType == IdentitySignatureType.ECDSA) {
                    val cipher = io {
                        identityManager.generateMasterKey(keyAlias, useCreds, invalidate)
                        cryptoProvider.getMasterCipherForEncryption(keyAlias)
                    }
                    val outcome = authenticator.authenticate(act, promptMessage ?: "Secure Identity", config?.promptSubtitle, config?.promptDescription, config?.cancelButtonText ?: "Cancel", useCreds, androidx.biometric.BiometricPrompt.CryptoObject(cipher))
                    val pub = io {
                        val (wrapped, pub) = cryptoProvider.sealDecryptionKey(outcome.cryptoObject!!.cipher!!)
                        java.io.File(appContext.filesDir, LocalBiometricConstants.ecWrappedFilename(keyAlias)).writeBytes(wrapped)
                        java.io.File(appContext.filesDir, LocalBiometricConstants.ecPubFilename(keyAlias)).writeBytes(pub)
                        pub
                    }

                    val decryptPub = KeyFactory.getInstance("EC").generatePublic(java.security.spec.X509EncodedKeySpec(pub))
                    buildEnrollmentResponse(kp.public, keyFormat, decryptPub, outcome.authType)
                } else {
                    buildEnrollmentResponse(kp.public, keyFormat, null, authType)
                }
            } catch (e: Exception) {
                IdentityEnrollmentResult(code = LocalBiometricErrorMapper.mapToIdentityError(e), error = LocalBiometricErrorMapper.safeErrorMessage(e))
            }
        }
    }

    override suspend fun signPayload(
        payload: String,
        keyAlias: String?,
        config: IdentitySignatureConfig?,
        signatureFormat: IdentitySignatureFormat,
        keyFormat: IdentityKeyFormat,
        promptMessage: String?
    ): IdentitySignatureResult {
        return signPayloadInternal(payload.toByteArray(), keyAlias, config, signatureFormat, keyFormat, promptMessage)
    }

    override suspend fun signPayloadBytes(
        payload: ByteArray,
        keyAlias: String?,
        config: IdentitySignatureConfig?,
        signatureFormat: IdentitySignatureFormat,
        keyFormat: IdentityKeyFormat,
        promptMessage: String?
    ): IdentitySignatureResult {
        return signPayloadInternal(payload, keyAlias, config, signatureFormat, keyFormat, promptMessage)
    }

    private suspend fun signPayloadInternal(
        data: ByteArray,
        alias: String?,
        config: IdentitySignatureConfig?,
        sigFormat: IdentitySignatureFormat,
        keyFormat: IdentityKeyFormat,
        prompt: String?
    ): IdentitySignatureResult {
        val act = activity ?: return IdentitySignatureResult(code = IdentityError.UNKNOWN, error = activityMissingMessage())
        return withBackgroundRetry(config?.persistAcrossBackgrounding, { it.code == IdentityError.SYSTEM_CANCELED }) {
            try {
                val mode = io { identityManager.inferKeyMode(alias) } ?: throw SecurityException("Identity not found")
                val allowCreds = config?.allowDeviceCredentials ?: false

                var attempt = 0
                var response: IdentitySignatureResult
                while (true) {
                    try {
                        val crypto = io { cryptoProvider.prepareSignature(alias, mode) }
                        val outcome = authenticator.authenticate(act, prompt ?: "Sign", config?.promptSubtitle, config?.promptDescription, config?.cancelButtonText ?: "Cancel", allowCreds, crypto)

                        val (sigBytes, pub) = io {
                            val sig = outcome.cryptoObject!!.signature!!
                            sig.update(data)
                            sig.sign() to cryptoProvider.getPublicKey(alias)
                        }
                        response = buildSignatureResponse(sigBytes, pub, sigFormat, keyFormat, outcome.authType)
                        break
                    } catch (e: Exception) {
                        if (attempt < 1 && LocalBiometricErrorMapper.isPrunedOperationError(e)) {
                            attempt++
                            continue
                        }
                        throw e
                    }
                }
                response
            } catch (e: Exception) {
                IdentitySignatureResult(code = LocalBiometricErrorMapper.mapToIdentityError(e), error = LocalBiometricErrorMapper.safeErrorMessage(e))
            }
        }
    }

    override suspend fun decryptPayload(
        payload: String,
        keyAlias: String?,
        payloadFormat: IdentityPayloadFormat,
        config: IdentityDecryptConfig?,
        promptMessage: String?
    ): IdentityDecryptResult {
        val act = activity ?: return IdentityDecryptResult(code = IdentityError.UNKNOWN, error = activityMissingMessage())
        return withBackgroundRetry(config?.persistAcrossBackgrounding, { it.code == IdentityError.SYSTEM_CANCELED }) {
            try {
                val mode = io { identityManager.inferKeyMode(keyAlias) } ?: throw SecurityException("Identity not found")
                val allowCreds = config?.allowDeviceCredentials ?: false
                val prompt = promptMessage ?: "Decrypt"

                when (mode) {
                    LocalKeyMode.RSA -> {
                        val cipher = io {
                            val ks = KeyStore.getInstance(LocalBiometricConstants.KEYSTORE_PROVIDER).apply { load(null) }
                            val entry = ks.getEntry(LocalBiometricConstants.identityKeyAlias(keyAlias), null) as KeyStore.PrivateKeyEntry
                            Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding").apply { init(Cipher.DECRYPT_MODE, entry.privateKey) }
                        }
                        val outcome = authenticator.authenticate(act, prompt, config?.promptSubtitle, config?.promptDescription, config?.cancelButtonText ?: "Cancel", allowCreds, androidx.biometric.BiometricPrompt.CryptoObject(cipher))
                        val decrypted = io { outcome.cryptoObject!!.cipher!!.doFinal(LocalBiometricFormatUtils.parsePayload(payload, payloadFormat)) }
                        IdentityDecryptResult(decryptedData = String(decrypted, Charsets.UTF_8), code = IdentityError.SUCCESS, authenticationType = outcome.authType)
                    }
                    LocalKeyMode.HYBRID_EC -> {
                        val cipher = io { cryptoProvider.getMasterCipherForDecryption(keyAlias) } ?: throw SecurityException("Master key missing")
                        val outcome = authenticator.authenticate(act, prompt, config?.promptSubtitle, config?.promptDescription, config?.cancelButtonText ?: "Cancel", allowCreds, androidx.biometric.BiometricPrompt.CryptoObject(cipher))
                        val decrypted = io { cryptoProvider.performHybridDecryption(keyAlias, outcome.cryptoObject!!.cipher!!, payload, payloadFormat) }
                        IdentityDecryptResult(decryptedData = decrypted, code = IdentityError.SUCCESS, authenticationType = outcome.authType)
                    }
                    else -> throw SecurityException("Identity does not support decryption")
                }
            } catch (e: Exception) {
                IdentityDecryptResult(code = LocalBiometricErrorMapper.mapToIdentityError(e), error = LocalBiometricErrorMapper.safeErrorMessage(e))
            }
        }
    }

    override suspend fun revokeIdentity(keyAlias: String?): Boolean {
        io { identityManager.deleteIdentity(keyAlias) }
        return true
    }

    override suspend fun revokeAllIdentities(): Boolean {
        io { identityManager.deleteAllIdentities() }
        return true
    }

    override suspend fun getIdentityStatus(keyAlias: String?, checkValidity: Boolean, keyFormat: IdentityKeyFormat): IdentityInfo = io {
        getIdentityStatusBlocking(keyAlias, keyFormat)
    }

    private fun getIdentityStatusBlocking(keyAlias: String?, keyFormat: IdentityKeyFormat): IdentityInfo {
        return try {
            val exists = identityManager.keyExists(keyAlias)
            if (!exists) return IdentityInfo(exists = false)

            val pub = cryptoProvider.getPublicKey(keyAlias)
            val mode = identityManager.inferKeyMode(keyAlias)
            val decryptPub = if (mode == LocalKeyMode.HYBRID_EC) cryptoProvider.getDecryptingPublicKey(keyAlias) else null

            IdentityInfo(
                exists = true,
                isValid = true,
                algorithm = pub.algorithm,
                keySize = if (pub is java.security.interfaces.RSAKey) pub.modulus.bitLength().toLong() else 256L,
                isHybridMode = mode == LocalKeyMode.HYBRID_EC,
                publicKey = LocalBiometricFormatUtils.formatOutput(pub.encoded, keyFormat).value,
                decryptingPublicKey = decryptPub?.let { LocalBiometricFormatUtils.formatOutput(it.encoded, keyFormat).value },
                decryptingAlgorithm = decryptPub?.algorithm,
                decryptingKeySize = decryptPub?.let { if (it is java.security.interfaces.RSAKey) it.modulus.bitLength().toLong() else 256L }
            )
        } catch (e: Exception) {
            IdentityInfo(exists = false)
        }
    }

    override suspend fun verifyPresence(promptMessage: String, config: PresencePromptConfig?): PresencePromptResult {
        val act = activity ?: return PresencePromptResult(success = false, error = activityMissingMessage(), code = IdentityError.PROMPT_ERROR)
        return withBackgroundRetry(config?.persistAcrossBackgrounding, { it.code == IdentityError.SYSTEM_CANCELED }) {
            try {
                val allowCreds = config?.allowDeviceCredentials ?: false
                val sensitive = config?.sensitiveTransaction ?: false
                val strength = config?.biometricStrength ?: IdentityBiometricStrength.STRONG
                val outcome = authenticator.authenticate(act, promptMessage, config?.subtitle, config?.promptDescription, config?.cancelButtonText ?: "Cancel", allowCreds, null, sensitive, strength)
                PresencePromptResult(success = true, code = IdentityError.SUCCESS, authenticationType = outcome.authType)
            } catch (e: Exception) {
                PresencePromptResult(success = false, error = LocalBiometricErrorMapper.safeErrorMessage(e), code = LocalBiometricErrorMapper.mapToIdentityError(e))
            }
        }
    }

    override suspend fun isDeviceSecure(): Boolean {
        val km = appContext.getSystemService(Context.KEYGUARD_SERVICE) as android.app.KeyguardManager
        return km.isDeviceSecure
    }

    override suspend fun acknowledgeIdentityChange() {
        changeMonitor.acknowledgeChange()
    }

    override suspend fun stopAuthentication(): Boolean {
        return authenticator.stopAuthentication()
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
