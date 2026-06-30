package com.amit.local_biometric

import android.util.Base64

object LocalBiometricFormatUtils {

    data class FormattedOutput(val value: String)

    fun formatOutput(data: ByteArray, format: IdentityKeyFormat): FormattedOutput {
        return when (format) {
            IdentityKeyFormat.BASE64, IdentityKeyFormat.RAW -> FormattedOutput(Base64.encodeToString(data, Base64.NO_WRAP))
            IdentityKeyFormat.PEM -> {
                val base64 = Base64.encodeToString(data, Base64.NO_WRAP)
                val pem = "-----BEGIN PUBLIC KEY-----\n" +
                        base64.chunked(64).joinToString("\n") +
                        "\n-----END PUBLIC KEY-----"
                FormattedOutput(pem)
            }
            IdentityKeyFormat.HEX -> FormattedOutput(bytesToHex(data))
        }
    }

    fun parsePayload(payload: String, format: IdentityPayloadFormat): ByteArray {
        return when (format) {
            IdentityPayloadFormat.BASE64 -> Base64.decode(payload, Base64.DEFAULT)
            IdentityPayloadFormat.HEX -> hexToBytes(payload)
            IdentityPayloadFormat.RAW -> Base64.decode(payload, Base64.DEFAULT)
        }
    }

    fun bytesToHex(bytes: ByteArray): String {
        val hexChars = CharArray(bytes.size * 2)
        val hexArray = "0123456789abcdef".toCharArray()
        for (i in bytes.indices) {
            val v = bytes[i].toInt() and 0xFF
            hexChars[i * 2] = hexArray[v ushr 4]
            hexChars[i * 2 + 1] = hexArray[v and 0x0F]
        }
        return String(hexChars)
    }

    private fun hexToBytes(hex: String): ByteArray {
        val len = hex.length
        val data = ByteArray(len / 2)
        var i = 0
        while (i < len) {
            data[i / 2] = ((Character.digit(hex[i], 16) shl 4) + Character.digit(hex[i + 1], 16)).toByte()
            i += 2
        }
        return data
    }
}
