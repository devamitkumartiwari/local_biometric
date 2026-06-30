package com.amit.local_biometric

import android.content.Context
import androidx.biometric.BiometricPrompt
import java.io.File
import java.security.*
import java.security.spec.ECGenParameterSpec
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

class LocalCryptographyProvider(private val context: Context) {

    fun getMasterCipherForEncryption(keyAlias: String?): Cipher {
        val ks = KeyStore.getInstance(LocalBiometricConstants.KEYSTORE_PROVIDER).apply { load(null) }
        val masterKey = ks.getKey(LocalBiometricConstants.masterKeyAlias(keyAlias), null) as? SecretKey
            ?: throw IllegalStateException("Master key not found")
        return Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.ENCRYPT_MODE, masterKey)
        }
    }

    fun getMasterCipherForDecryption(keyAlias: String?): Cipher? {
        val wrapped = File(context.filesDir, LocalBiometricConstants.ecWrappedFilename(keyAlias)).let {
            if (it.exists()) it.readBytes() else return null
        }
        if (wrapped.size < LocalBiometricConstants.GCM_IV_SIZE + 1) return null

        val iv = wrapped.copyOfRange(0, LocalBiometricConstants.GCM_IV_SIZE)
        val ks = KeyStore.getInstance(LocalBiometricConstants.KEYSTORE_PROVIDER).apply { load(null) }
        val masterKey = ks.getKey(LocalBiometricConstants.masterKeyAlias(keyAlias), null) as? SecretKey ?: return null
        
        return Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.DECRYPT_MODE, masterKey, GCMParameterSpec(LocalBiometricConstants.GCM_TAG_BITS, iv))
        }
    }

    fun sealDecryptionKey(cipher: Cipher): Pair<ByteArray, ByteArray> {
        val kpg = KeyPairGenerator.getInstance("EC")
        kpg.initialize(ECGenParameterSpec("secp256r1"), SecureRandom())
        val kp = kpg.generateKeyPair()

        val privBytes = kp.private.encoded
        val pubBytes = kp.public.encoded

        return try {
            val encrypted = cipher.doFinal(privBytes)
            val iv = cipher.iv ?: throw IllegalStateException("Cipher IV missing")
            val wrapped = ByteArray(iv.size + encrypted.size)
            System.arraycopy(iv, 0, wrapped, 0, iv.size)
            System.arraycopy(encrypted, 0, wrapped, iv.size, encrypted.size)
            Pair(wrapped, pubBytes)
        } finally {
            privBytes.fill(0)
        }
    }

    fun prepareSignature(keyAlias: String?, mode: LocalKeyMode): BiometricPrompt.CryptoObject {
        val ks = KeyStore.getInstance(LocalBiometricConstants.KEYSTORE_PROVIDER).apply { load(null) }
        val alias = LocalBiometricConstants.identityKeyAlias(keyAlias)
        val entry = ks.getEntry(alias, null) as? KeyStore.PrivateKeyEntry
            ?: throw IllegalStateException("Key not found")

        val algorithm = if (mode == LocalKeyMode.RSA) "SHA256withRSA" else "SHA256withECDSA"
        val sig = Signature.getInstance(algorithm)
        sig.initSign(entry.privateKey)
        return BiometricPrompt.CryptoObject(sig)
    }

    fun getPublicKey(keyAlias: String?): PublicKey {
        val ks = KeyStore.getInstance(LocalBiometricConstants.KEYSTORE_PROVIDER).apply { load(null) }
        val entry = ks.getEntry(LocalBiometricConstants.identityKeyAlias(keyAlias), null) as? KeyStore.PrivateKeyEntry
            ?: throw IllegalStateException("Key not found")
        return entry.certificate.publicKey
    }

    fun performHybridDecryption(
        keyAlias: String?,
        unwrapCipher: Cipher,
        payload: String,
        format: IdentityPayloadFormat
    ): String {
        val wrapped = File(context.filesDir, LocalBiometricConstants.ecWrappedFilename(keyAlias)).readBytes()
        val encryptedKey = wrapped.copyOfRange(LocalBiometricConstants.GCM_IV_SIZE, wrapped.size)

        var privBytes: ByteArray? = null
        try {
            privBytes = unwrapCipher.doFinal(encryptedKey)
            val priv = KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(privBytes))

            val data = LocalBiometricFormatUtils.parsePayload(payload, format)
            val ephemeralPubBytes = data.copyOfRange(0, LocalBiometricConstants.EC_PUBKEY_SIZE)
            val cipherWithTag = data.copyOfRange(LocalBiometricConstants.EC_PUBKEY_SIZE, data.size)

            val ephemeralPub = KeyFactory.getInstance("EC").generatePublic(
                X509EncodedKeySpec(wrapRawEcPub(ephemeralPubBytes))
            )

            val sharedSecret = KeyAgreement.getInstance("ECDH").run {
                init(priv)
                doPhase(ephemeralPub, true)
                generateSecret()
            }

            val derived = kdfX963(sharedSecret, LocalBiometricConstants.AES_KEY_SIZE + LocalBiometricConstants.GCM_IV_SIZE)
            val aesKeyBytes = derived.copyOfRange(0, LocalBiometricConstants.AES_KEY_SIZE)
            val gcmIv = derived.copyOfRange(LocalBiometricConstants.AES_KEY_SIZE, derived.size)

            return try {
                val aesKey = SecretKeySpec(aesKeyBytes, "AES")
                val decrypted = Cipher.getInstance("AES/GCM/NoPadding").run {
                    init(Cipher.DECRYPT_MODE, aesKey, GCMParameterSpec(LocalBiometricConstants.GCM_TAG_BITS, gcmIv))
                    doFinal(cipherWithTag)
                }
                String(decrypted, Charsets.UTF_8)
            } finally {
                aesKeyBytes.fill(0)
                gcmIv.fill(0)
                derived.fill(0)
                sharedSecret.fill(0)
            }
        } finally {
            privBytes?.fill(0)
        }
    }

    private fun wrapRawEcPub(raw: ByteArray): ByteArray {
        val header = byteArrayOf(
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A.toByte(), 0x86.toByte(),
            0x48.toByte(), 0xCE.toByte(), 0x3D.toByte(), 0x02.toByte(), 0x01.toByte(),
            0x06.toByte(), 0x08.toByte(), 0x2A.toByte(), 0x86.toByte(), 0x48.toByte(),
            0xCE.toByte(), 0x3D.toByte(), 0x03.toByte(), 0x01.toByte(), 0x07.toByte(),
            0x03.toByte(), 0x42.toByte(), 0x00.toByte()
        )
        return ByteArray(header.size + raw.size).apply {
            System.arraycopy(header, 0, this, 0, header.size)
            System.arraycopy(raw, 0, this, header.size, raw.size)
        }
    }

    private fun kdfX963(secret: ByteArray, length: Int): ByteArray {
        val md = MessageDigest.getInstance("SHA-256")
        val res = ByteArray(length)
        var off = 0
        var counter = 1
        while (off < length) {
            md.reset()
            md.update(secret)
            md.update(byteArrayOf((counter shr 24).toByte(), (counter shr 16).toByte(), (counter shr 8).toByte(), counter.toByte()))
            val hash = md.digest()
            val toCopy = minOf(hash.size, length - off)
            System.arraycopy(hash, 0, res, off, toCopy)
            off += toCopy
            counter++
        }
        return res
    }
}
