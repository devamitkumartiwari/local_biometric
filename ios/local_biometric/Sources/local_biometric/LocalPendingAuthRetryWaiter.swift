import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// Backs `persistAcrossBackgrounding` (mirrors LocalPendingAuthRetryObserver.kt on Android). When
// a prompt-issuing call is interrupted by the app being backgrounded (reported as
// IdentityError.systemCanceled), the plugin awaits here and retries the *entire* originating call
// from scratch once the app returns to the foreground -- never resumes in-flight Security
// framework state.
final class LocalPendingAuthRetryWaiter: NSObject {
    private var continuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        #if os(iOS)
        let name = UIApplication.didBecomeActiveNotification
        #elseif os(macOS)
        let name = NSApplication.didBecomeActiveNotification
        #endif
        NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive), name: name, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func awaitResume() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    @objc private func appBecameActive() {
        continuation?.resume()
        continuation = nil
    }
}
