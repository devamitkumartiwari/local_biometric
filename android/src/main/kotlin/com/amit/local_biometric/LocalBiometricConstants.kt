package com.amit.local_biometric

object LocalBiometricConstants {
    const val KEYSTORE_PROVIDER = "AndroidKeyStore"
    const val KEY_ALIAS_PREFIX = "local_biometric_key_"
    const val MASTER_KEY_ALIAS_PREFIX = "local_biometric_master_"
    
    const val GCM_IV_SIZE = 12
    const val GCM_TAG_BITS = 128
    const val GCM_TAG_BYTES = 16
    const val AES_KEY_SIZE = 32 // 256 bits
    const val EC_PUBKEY_SIZE = 65 // Uncompressed P-256

    fun identityKeyAlias(userAlias: String?): String {
        return if (userAlias != null) "$KEY_ALIAS_PREFIX$userAlias" else "${KEY_ALIAS_PREFIX}default"
    }

    fun masterKeyAlias(userAlias: String?): String {
        return if (userAlias != null) "$MASTER_KEY_ALIAS_PREFIX$userAlias" else "${MASTER_KEY_ALIAS_PREFIX}default"
    }

    fun ecWrappedFilename(userAlias: String?): String {
        return if (userAlias != null) "local_ec_wrapped_$userAlias" else "local_ec_wrapped_default"
    }

    fun ecPubFilename(userAlias: String?): String {
        return if (userAlias != null) "local_ec_pub_$userAlias" else "local_ec_pub_default"
    }
    
    fun identityStatusFilename(): String {
        return "local_biometric_status"
    }
}
