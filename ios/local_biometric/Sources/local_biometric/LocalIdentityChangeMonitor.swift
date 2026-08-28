import Foundation
import LocalAuthentication
#if os(iOS)
import Flutter
#elseif os(macOS)
import AppKit
import FlutterMacOS
#endif

class LocalIdentityChangeMonitor: NSObject, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?
    private var lastStatus: IdentityStatus = .valid
    private let storage = LocalSecureIdentityStorage()

    // Sticky "changed" flag, mirroring Android's SharedPreferences `has_changed` boolean
    // (LocalIdentityChangeMonitor.kt): once a domain-state mismatch is observed, `.changed`
    // keeps being reported on every subsequent check until acknowledgeIdentityChange() clears it,
    // even if the domain state happens to match again later.
    private static let hasChangedKey = "com.amit.local_biometric.status.has_changed"
    private var hasChangedFlag: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hasChangedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hasChangedKey) }
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        checkAndEmit()
        #if os(iOS)
        let activeNotification = UIApplication.didBecomeActiveNotification
        #elseif os(macOS)
        let activeNotification = NSApplication.didBecomeActiveNotification
        #endif
        NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive), name: activeNotification, object: nil)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        NotificationCenter.default.removeObserver(self)
        return nil
    }

    @objc private func appBecameActive() {
        checkAndEmit()
    }

    // Clears the sticky changed flag and re-baselines the tracked domain state to the device's
    // current one, then re-checks (pushing a fresh `.valid` event if nothing else is wrong).
    // Mirrors Android's `LocalIdentityChangeMonitor.acknowledgeChange()`.
    func acknowledgeChange() {
        hasChangedFlag = false
        storage.saveDomainState(alias: nil)
        checkAndEmit()
    }

    func checkAndEmit() {
        let status = computeStatus()
        if status != lastStatus {
            lastStatus = status
            eventSink?(status.rawValue)
        }
    }

    private func computeStatus() -> IdentityStatus {
        if hasChangedFlag {
            return .changed
        }

        let ctx = LAContext()
        var error: NSError?
        let canAuth = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        if !canAuth {
            return .unavailable
        }

        // Domain-state comparison detects a biometric re-enrollment even though the device can
        // still authenticate (unlike Android, which detects invalidation by actually attempting
        // `Signature.initSign` on the Keystore entry and catching
        // `KeyPermanentlyInvalidatedException` -- iOS has no equivalent throwing probe short of
        // performing a real signature, which would require a biometric prompt just to check
        // status, so this compares LAContext's domain-state snapshot instead).
        //
        // NOTE (known limitation, matching Android's own): this only tracks the *default* alias's
        // domain state, not every identity the app may have enrolled under a distinct `keyAlias`
        // -- Android's equivalent check iterates every Keystore alias it created, but iOS has no
        // cheap way to enumerate all Keychain items this plugin created without a broader,
        // slower scan, so multi-alias tracking is left as a known gap rather than expanded here.
        if let baseline = storage.getDomainState(alias: nil), let current = ctx.evaluatedPolicyDomainState, baseline != current {
            hasChangedFlag = true
            return .changed
        }

        return .valid
    }
}
