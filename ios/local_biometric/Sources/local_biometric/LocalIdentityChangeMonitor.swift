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

    func checkAndEmit() {
        let ctx = LAContext()
        var error: NSError?
        let canAuth = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)

        var status: IdentityStatus = .valid
        if !canAuth {
            status = .unavailable
        } else {
            status = .valid
        }

        if status != lastStatus {
            lastStatus = status
            eventSink?(status.rawValue)
        }
    }
}
