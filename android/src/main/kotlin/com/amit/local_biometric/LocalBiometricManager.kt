package com.amit.local_biometric

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.interfaces.ECPublicKey
import java.security.interfaces.RSAPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.RSAKeyGenParameterSpec
import javax.crypto.KeyGenerator

enum class LocalKeyMode { RSA, EC_SIGN_ONLY, HYBRID_EC }

class LocalBiometricManager(private val context: Context) {

    fun generateRsaKey(
        keyAlias: String?,
        useDeviceCredentials: Boolean,
        invalidateOnEnrollment: Boolean,
        enableDecryption: Boolean,
        requireAuthentication: Boolean = true
    ): KeyPair {
        val alias = LocalBiometricConstants.identityKeyAlias(keyAlias)
        val purposes = if (enableDecryption) {
            KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_DECRYPT
        } else {
            KeyProperties.PURPOSE_SIGN
        }

        val builder = KeyGenParameterSpec.Builder(alias, purposes)
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setSignaturePaddings(KeyProperties.SIGNATURE_PADDING_RSA_PKCS1)
            .setAlgorithmParameterSpec(RSAKeyGenParameterSpec(2048, RSAKeyGenParameterSpec.F4))
            .setUserAuthenticationRequired(requireAuthentication)

        if (enableDecryption) {
            builder.setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_RSA_OAEP)
        }

        // setInvalidatedByBiometricEnrollment/setUserAuthenticationParameters are meaningless (and
        // some throw) on a key that doesn't require authentication at all.
        if (requireAuthentication) {
            configureAuth(builder, useDeviceCredentials, invalidateOnEnrollment)
        }
        tryEnableStrongBox(builder)

        val kpg = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, LocalBiometricConstants.KEYSTORE_PROVIDER)
        kpg.initialize(builder.build())
        return kpg.generateKeyPair()
    }

    fun generateEcKey(
        keyAlias: String?,
        useDeviceCredentials: Boolean,
        invalidateOnEnrollment: Boolean,
        requireAuthentication: Boolean = true
    ): KeyPair {
        val alias = LocalBiometricConstants.identityKeyAlias(keyAlias)
        val builder = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setUserAuthenticationRequired(requireAuthentication)

        if (requireAuthentication) {
            configureAuth(builder, useDeviceCredentials, invalidateOnEnrollment)
        }
        tryEnableStrongBox(builder)

        val kpg = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, LocalBiometricConstants.KEYSTORE_PROVIDER)
        kpg.initialize(builder.build())
        return kpg.generateKeyPair()
    }

    fun generateMasterKey(
        keyAlias: String?,
        useDeviceCredentials: Boolean,
        invalidateOnEnrollment: Boolean
    ) {
        val alias = LocalBiometricConstants.masterKeyAlias(keyAlias)
        val builder = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(true)

        configureAuth(builder, useDeviceCredentials, invalidateOnEnrollment)

        val keyGen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, LocalBiometricConstants.KEYSTORE_PROVIDER)
        keyGen.init(builder.build())
        keyGen.generateKey()
    }

    fun deleteIdentity(keyAlias: String?) {
        val ks = KeyStore.getInstance(LocalBiometricConstants.KEYSTORE_PROVIDER).apply { load(null) }
        ks.deleteEntry(LocalBiometricConstants.identityKeyAlias(keyAlias))
        ks.deleteEntry(LocalBiometricConstants.masterKeyAlias(keyAlias))

        listOf(
            LocalBiometricConstants.ecWrappedFilename(keyAlias),
            LocalBiometricConstants.ecPubFilename(keyAlias)
        ).forEach { filename ->
            val file = File(context.filesDir, filename)
            if (file.exists()) {
                file.writeBytes(ByteArray(file.length().toInt())) // Secure wipe
                file.delete()
            }
        }
    }

    fun deleteAllIdentities() {
        val ks = KeyStore.getInstance(LocalBiometricConstants.KEYSTORE_PROVIDER).apply { load(null) }
        val aliases = ks.aliases().toList()
        for (alias in aliases) {
            if (alias.startsWith(LocalBiometricConstants.KEY_ALIAS_PREFIX) || 
                alias.startsWith(LocalBiometricConstants.MASTER_KEY_ALIAS_PREFIX)) {
                ks.deleteEntry(alias)
            }
        }

        context.filesDir.listFiles()?.forEach { file ->
            if (file.name.startsWith("local_ec_wrapped") || file.name.startsWith("local_ec_pub")) {
                file.writeBytes(ByteArray(file.length().toInt()))
                file.delete()
            }
        }
    }

    fun keyExists(keyAlias: String?): Boolean {
        val ks = KeyStore.getInstance(LocalBiometricConstants.KEYSTORE_PROVIDER).apply { load(null) }
        return ks.containsAlias(LocalBiometricConstants.identityKeyAlias(keyAlias))
    }

    fun inferKeyMode(keyAlias: String?): LocalKeyMode? {
        val ks = KeyStore.getInstance(LocalBiometricConstants.KEYSTORE_PROVIDER).apply { load(null) }
        val alias = LocalBiometricConstants.identityKeyAlias(keyAlias)
        if (!ks.containsAlias(alias)) return null
        val entry = ks.getEntry(alias, null) as? KeyStore.PrivateKeyEntry ?: return null
        val pub = entry.certificate.publicKey
        return when (pub) {
            is RSAPublicKey -> LocalKeyMode.RSA
            is ECPublicKey -> {
                if (File(context.filesDir, LocalBiometricConstants.ecWrappedFilename(keyAlias)).exists()) {
                    LocalKeyMode.HYBRID_EC
                } else {
                    LocalKeyMode.EC_SIGN_ONLY
                }
            }
            else -> null
        }
    }

    private fun configureAuth(builder: KeyGenParameterSpec.Builder, useDeviceCredentials: Boolean, invalidateOnEnrollment: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val authType = if (useDeviceCredentials) {
                KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL
            } else {
                KeyProperties.AUTH_BIOMETRIC_STRONG
            }
            builder.setUserAuthenticationParameters(0, authType)
        } else {
            builder.setUserAuthenticationValidityDurationSeconds(-1)
        }
        
        // minSdk is 24 (N), so setInvalidatedByBiometricEnrollment is always available.
        if (invalidateOnEnrollment) {
            builder.setInvalidatedByBiometricEnrollment(true)
        }
    }

    private fun tryEnableStrongBox(builder: KeyGenParameterSpec.Builder) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            context.packageManager.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE)) {
            try {
                builder.setIsStrongBoxBacked(true)
            } catch (_: Throwable) {}
        }
    }
}
