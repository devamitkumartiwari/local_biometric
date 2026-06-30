package com.amit.local_biometric

import android.content.Context
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import io.flutter.plugin.common.EventChannel
import kotlinx.coroutines.*
import java.security.KeyStore
import java.security.Signature

class LocalIdentityChangeMonitor(private val context: Context, private val identityManager: LocalBiometricManager) : EventChannel.StreamHandler, DefaultLifecycleObserver {

    private var eventSink: EventChannel.EventSink? = null
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private var lastStatus: IdentityStatus = IdentityStatus.VALID

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        checkAndEmit()
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onResume(owner: LifecycleOwner) {
        checkAndEmit()
    }

    fun acknowledgeChange() {
        context.getSharedPreferences(LocalBiometricConstants.identityStatusFilename(), Context.MODE_PRIVATE)
            .edit()
            .putBoolean("has_changed", false)
            .apply()
        checkAndEmit()
    }

    private fun checkAndEmit() {
        scope.launch {
            val status = withContext(Dispatchers.IO) {
                val prefs = context.getSharedPreferences(LocalBiometricConstants.identityStatusFilename(), Context.MODE_PRIVATE)
                if (prefs.getBoolean("has_changed", false)) return@withContext IdentityStatus.CHANGED

                val ks = KeyStore.getInstance(LocalBiometricConstants.KEYSTORE_PROVIDER).apply { load(null) }
                val aliases = ks.aliases().toList().filter { it.startsWith(LocalBiometricConstants.KEY_ALIAS_PREFIX) }
                
                for (alias in aliases) {
                    val entry = ks.getEntry(alias, null) as? KeyStore.PrivateKeyEntry ?: continue
                    val pub = entry.certificate.publicKey
                    val alg = if (pub.algorithm == "RSA") "SHA256withRSA" else "SHA256withECDSA"
                    val sig = Signature.getInstance(alg)
                    try {
                        sig.initSign(entry.privateKey)
                    } catch (e: Exception) {
                        if (e is android.security.keystore.KeyPermanentlyInvalidatedException) {
                            prefs.edit().putBoolean("has_changed", true).apply()
                            return@withContext IdentityStatus.CHANGED
                        }
                    }
                }
                
                IdentityStatus.VALID
            }
            
            if (status != lastStatus) {
                lastStatus = status
                eventSink?.success(status.ordinal)
            }
        }
    }
}
