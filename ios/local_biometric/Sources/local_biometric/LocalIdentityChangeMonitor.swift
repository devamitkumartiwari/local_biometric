import Foundation
import LocalAuthentication
import Flutter

class LocalIdentityChangeMonitor: NSObject, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?
    private var lastStatus: IdentityStatus = .valid

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        checkAndEmit()
        NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
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
