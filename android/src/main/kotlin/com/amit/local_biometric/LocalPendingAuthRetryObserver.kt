package com.amit.local_biometric

import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import kotlinx.coroutines.CompletableDeferred

// Backs `persistAcrossBackgrounding`: when a prompt-issuing call is interrupted by the app being
// backgrounded (reported as IdentityError.SYSTEM_CANCELED), the plugin parks here and retries the
// *entire* originating call from scratch once the app returns to the foreground. This never tries
// to resume in-flight Keystore/BiometricPrompt state -- a `Cipher`/`Signature` `CryptoObject`
// mid-operation is not guaranteed safely resumable after a backgrounding interruption, so a full
// retry is the only safe option. Kept separate from LocalIdentityChangeMonitor, which has its own,
// unrelated lifecycle-driven job (detecting biometric re-enrollment).
class LocalPendingAuthRetryObserver : DefaultLifecycleObserver {
    private var pending: CompletableDeferred<Unit>? = null

    suspend fun awaitResume() {
        val deferred = CompletableDeferred<Unit>()
        pending = deferred
        deferred.await()
    }

    override fun onResume(owner: LifecycleOwner) {
        pending?.let { if (!it.isCompleted) it.complete(Unit) }
        pending = null
    }
}
