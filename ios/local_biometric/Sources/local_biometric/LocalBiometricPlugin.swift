#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif
import LocalAuthentication

public class LocalBiometricPlugin: NSObject, FlutterPlugin, LocalBiometricApi {

    private let storage = LocalSecureIdentityStorage()
    private let crypto = LocalIdentityCryptoEngine()
    private let changeMonitor = LocalIdentityChangeMonitor()
    private let retryWaiter = LocalPendingAuthRetryWaiter()
    private static let maxBackgroundRetries = 3

    // Tracks whichever LAContext is currently presenting a prompt, so stopAuthentication() can
    // cancel it. Cleared once the operation that created it completes, so a later
    // stopAuthentication() call can't invalidate an unrelated, already-finished context.
    private var currentContext: LAContext?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = LocalBiometricPlugin()
        #if os(iOS)
        let messenger = registrar.messenger()
        #elseif os(macOS)
        let messenger = registrar.messenger
        #endif
        LocalBiometricApiSetup.setUp(binaryMessenger: messenger, api: instance)

        let eventChannel = FlutterEventChannel(name: "com.amit.local_biometric/changes", binaryMessenger: messenger)
        eventChannel.setStreamHandler(instance.changeMonitor)
    }

    // Bridges LAContext's completion-handler-based evaluatePolicy into Swift's
    // async/await world (LocalAuthentication itself is not async-throws on the
    // iOS 16/macOS 13 SDKs this plugin targets, so every prompt-issuing method
    // below funnels through this).
    private func evaluatePolicy(_ ctx: LAContext, policy: LAPolicy, reason: String) async -> (success: Bool, error: Error?) {
        await withCheckedContinuation { continuation in
            ctx.evaluatePolicy(policy, localizedReason: reason) { success, error in
                continuation.resume(returning: (success, error))
            }
        }
    }

    private func trackContext<T>(_ ctx: LAContext, _ body: () async -> T) async -> T {
        currentContext = ctx
        defer { if currentContext === ctx { currentContext = nil } }
        return await body()
    }

    // Backs `persistAcrossBackgrounding`. `block` is the entire operation (prompt + crypto), run
    // fresh on every attempt -- never resumed mid-flight. Bounded so a device stuck rapidly
    // backgrounding/foregrounding can't spin forever.
    private func withBackgroundRetry<T>(persist: Bool?, isSystemCanceled: (T) -> Bool, block: () async -> T) async -> T {
        var result = await block()
        guard persist == true else { return result }
        var attempts = 0
        while isSystemCanceled(result) && attempts < Self.maxBackgroundRetries {
            attempts += 1
            await retryWaiter.awaitResume()
            result = await block()
        }
        return result
    }

    // --- API Implementation ---
    //
    // Every method here is `async throws`, matching Pigeon 28's default async-throws Swift
    // codegen (see LocalBiometricApi.swift's generated `protocol LocalBiometricApi`). As with
    // the previous callback-based code, recoverable failures (wrong biometric, lockout, missing
    // key, etc.) are reported *in-band* via the `code`/`error` fields on the returned result
    // object -- none of these methods actually throw a Swift error, matching the old code's
    // exclusive use of `completion(.success(...))` (never `.failure`). This migration is a
    // calling-convention change only, not a behavior change.

    func checkAvailability() async throws -> IdentityAvailability {
        let ctx = LAContext()
        var error: NSError?
        let available = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)

        var types: [IdentityBiometricType?] = []
        // -7 or -8 can indicate lockout depending on iOS version/context
        let isLockedOut = error?.code == LAError.biometryLockout.rawValue || error?.code == -7 || error?.code == -8

        if available || isLockedOut {
            if #available(iOS 11.0, *) {
                switch ctx.biometryType {
                case .faceID: types.append(.face)
                case .touchID: types.append(.fingerprint)
                default: break
                }
            }
        }

        print("[LocalBiometric] checkAvailability: available=\(available), error=\(String(describing: error)), isLockedOut=\(isLockedOut)")

        return IdentityAvailability(
            canAuthenticate: available,
            hasEnrolledBiometrics: error?.code != LAError.biometryNotEnrolled.rawValue,
            availableBiometrics: types,
            reason: isLockedOut ? "lockedOutPermanent" : error?.localizedDescription
        )
    }

    func enrollIdentity(keyAlias: String?, config: IdentityEnrollmentConfig?, keyFormat: IdentityKeyFormat, promptMessage: String?) async throws -> IdentityEnrollmentResult {
        let sigType = config?.signatureType ?? .rsa
        let biometryCurrent = config?.setInvalidatedByBiometricEnrollment ?? false
        let useCreds = config?.useDeviceCredentials ?? false
        let requireAuth = config?.requireAuthentication ?? true

        return await withBackgroundRetry(persist: config?.persistAcrossBackgrounding, isSystemCanceled: { $0.code == .systemCanceled }) {
            await self.enrollIdentityAttempt(keyAlias: keyAlias, config: config, keyFormat: keyFormat, promptMessage: promptMessage, sigType: sigType, biometryCurrent: biometryCurrent, useCreds: useCreds, requireAuth: requireAuth)
        }
    }

    private func enrollIdentityAttempt(keyAlias: String?, config: IdentityEnrollmentConfig?, keyFormat: IdentityKeyFormat, promptMessage: String?, sigType: IdentitySignatureType, biometryCurrent: Bool, useCreds: Bool, requireAuth: Bool) async -> IdentityEnrollmentResult {
        if config?.failIfExists == true {
            let (existing, _) = storage.getEcKey(alias: keyAlias, context: nil)
            if existing != nil {
                return IdentityEnrollmentResult(publicKey: nil, error: "Identity exists", code: .keyAlreadyExists)
            }
        }

        storage.deleteIdentity(alias: keyAlias)

        func generate() -> IdentityEnrollmentResult {
            guard let ecKey = self.storage.createEcKey(alias: keyAlias, useCreds: useCreds, biometryCurrent: biometryCurrent, requireAuthentication: requireAuth) else {
                return IdentityEnrollmentResult(publicKey: nil, error: "EC Gen Failed", code: .unknown)
            }

            if sigType == .ecdsa {
                return IdentityEnrollmentResult(
                    publicKey: self.crypto.formatKey(SecKeyCopyPublicKey(ecKey)!, format: keyFormat),
                    code: .success, algorithm: "EC", keySize: 256, isHybridMode: false
                )
            } else {
                let rsaAttrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048, kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: false]]
                var error: Unmanaged<CFError>?
                guard let rsaPriv = SecKeyCreateRandomKey(rsaAttrs as CFDictionary, &error),
                      let rsaData = SecKeyCopyExternalRepresentation(rsaPriv, &error) as Data?,
                      let pub = SecKeyCopyPublicKey(ecKey),
                      let wrapped = SecKeyCreateEncryptedData(pub, .eciesEncryptionStandardX963SHA256AESGCM, rsaData as CFData, &error) as Data?,
                      let rsaPub = SecKeyCopyPublicKey(rsaPriv) else {
                    return IdentityEnrollmentResult(publicKey: nil, error: "RSA Gen Failed", code: .unknown)
                }
                self.storage.saveWrappedRsa(alias: keyAlias, wrapped: wrapped)
                // Persist the RSA public key's SPKI bytes so getIdentityStatus can report it
                // later without unwrapping the wrapped private key (which would require a
                // biometric prompt just to answer a status query -- see LocalSecureIdentityStorage's
                // saveRsaPublicKeySpki doc comment).
                if let spki = self.crypto.subjectPublicKeyInfoData(for: rsaPub) {
                    self.storage.saveRsaPublicKeySpki(alias: keyAlias, spki: spki)
                }
                return IdentityEnrollmentResult(
                    publicKey: self.crypto.formatKey(rsaPub, format: keyFormat),
                    code: .success, algorithm: "RSA", keySize: 2048, isHybridMode: true
                )
            }
        }

        if config?.enforceBiometric == true {
            let ctx = LAContext()
            if !useCreds {
                ctx.localizedFallbackTitle = ""
            }
            return await trackContext(ctx) {
                let (success, error) = await self.evaluatePolicy(ctx, policy: useCreds ? .deviceOwnerAuthentication : .deviceOwnerAuthenticationWithBiometrics, reason: promptMessage ?? "Enroll")
                if success {
                    return generate()
                } else {
                    let laError = error as NSError?
                    let laCode = laError?.code ?? 0
                    var errorCode: IdentityError = .userCanceled
                    if laCode == -7 || laCode == -8 || laCode == LAError.biometryLockout.rawValue {
                        errorCode = .lockedOut
                    } else if laCode == LAError.authenticationFailed.rawValue {
                        errorCode = .authenticationFailed
                    } else if laCode == LAError.notInteractive.rawValue {
                        errorCode = .notInteractive
                    } else if laCode == LAError.systemCancel.rawValue || laCode == LAError.appCancel.rawValue {
                        errorCode = .systemCanceled
                    }
                    print("[LocalBiometric] enroll FAIL: laCode=\(laCode), mapped=\(errorCode)")
                    return IdentityEnrollmentResult(code: errorCode)
                }
            }
        } else {
            return generate()
        }
    }

    func signPayload(payload: String, keyAlias: String?, config: IdentitySignatureConfig?, signatureFormat: IdentitySignatureFormat, keyFormat: IdentityKeyFormat, promptMessage: String?) async throws -> IdentitySignatureResult {
        await withBackgroundRetry(persist: config?.persistAcrossBackgrounding, isSystemCanceled: { $0.code == .systemCanceled }) {
            self.signInternal(data: payload.data(using: .utf8)!, alias: keyAlias, config: config, sigFormat: signatureFormat, keyFormat: keyFormat, prompt: promptMessage)
        }
    }

    func signPayloadBytes(payload: FlutterStandardTypedData, keyAlias: String?, config: IdentitySignatureConfig?, signatureFormat: IdentitySignatureFormat, keyFormat: IdentityKeyFormat, promptMessage: String?) async throws -> IdentitySignatureResult {
        await withBackgroundRetry(persist: config?.persistAcrossBackgrounding, isSystemCanceled: { $0.code == .systemCanceled }) {
            self.signInternal(data: payload.data, alias: keyAlias, config: config, sigFormat: signatureFormat, keyFormat: keyFormat, prompt: promptMessage)
        }
    }

    // Synchronous: Security framework's biometric-gated Keychain lookups
    // (storage.getEcKey/SecKeyCreateSignature) block internally while
    // presenting the system biometric UI, so no continuation bridging is
    // needed here (matches the previous callback-based code, which also
    // called these APIs directly rather than wrapping them).
    private func signInternal(data: Data, alias: String?, config: IdentitySignatureConfig?, sigFormat: IdentitySignatureFormat, keyFormat: IdentityKeyFormat, prompt: String?) -> IdentitySignatureResult {
        let ctx = LAContext(); ctx.localizedReason = prompt ?? "Sign"
        currentContext = ctx
        defer { if currentContext === ctx { currentContext = nil } }

        // If device credentials (passcode) are NOT allowed, we hide the fallback button.
        if config?.allowDeviceCredentials == false {
            ctx.localizedFallbackTitle = ""
        }

        let (ecKeyResult, status) = storage.getEcKey(alias: alias, context: ctx)

        if let ecKey = ecKeyResult {
            var error: Unmanaged<CFError>?
            if let wrapped = storage.getWrappedRsa(alias: alias) {
                guard let rsaData = SecKeyCreateDecryptedData(ecKey, .eciesEncryptionStandardX963SHA256AESGCM, wrapped as CFData, &error) as Data? else {
                    let errorCode = mapCFError(error?.takeRetainedValue())
                    print("[LocalBiometric] Decrypt FAIL: \(errorCode)")
                    return IdentitySignatureResult(code: errorCode)
                }
                guard let rsaPriv = SecKeyCreateWithData(rsaData as CFData, [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits as String: 2048] as CFDictionary, nil),
                      let sig = SecKeyCreateSignature(rsaPriv, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, &error) as Data? else {
                    let errorCode = mapCFError(error?.takeRetainedValue())
                    print("[LocalBiometric] RSA Sign FAIL: \(errorCode)")
                    return IdentitySignatureResult(code: errorCode)
                }
                return IdentitySignatureResult(signature: crypto.formatSignature(sig, format: sigFormat), code: .success, algorithm: "RSA", keySize: 2048)
            } else {
                guard let sig = SecKeyCreateSignature(ecKey, .ecdsaSignatureMessageX962SHA256, data as CFData, &error) as Data? else {
                    let errorCode = mapCFError(error?.takeRetainedValue())
                    print("[LocalBiometric] EC Sign FAIL: \(errorCode)")
                    return IdentitySignatureResult(code: errorCode)
                }
                return IdentitySignatureResult(signature: crypto.formatSignature(sig, format: sigFormat), code: .success, algorithm: "EC", keySize: 256)
            }
        } else {
            let errorCode = mapKeyLookupFailure(status: status, ctx: ctx)
            print("[LocalBiometric] sign FAIL: status=\(status), mapped=\(errorCode)")
            return IdentitySignatureResult(code: errorCode)
        }
    }

    // Shared by signInternal and decryptPayload: both look up the identity's EC key via
    // storage.getEcKey(alias:context:) first, and need the same error classification when that
    // lookup fails (key never enrolled vs. locked out vs. user canceled the prompt LAContext
    // presented while attempting the lookup).
    private func mapKeyLookupFailure(status: OSStatus, ctx: LAContext) -> IdentityError {
        // LAError codes:
        // -7 is biometryLockout
        // -6 is biometryNotAvailable
        // -8 is biometryNotEnrolled

        var laError: NSError?
        let canAuth = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &laError)
        let laCode = laError?.code ?? 0

        if status == errSecItemNotFound {
            return .keyNotFound
        } else if laCode == -7 || laCode == -8 || laCode == LAError.biometryLockout.rawValue {
            return .lockedOutPermanent
        } else if status == errSecUserCanceled || laCode == LAError.userCancel.rawValue {
            return .userCanceled
        } else if laCode == LAError.authenticationFailed.rawValue {
            return .authenticationFailed
        } else if laCode == LAError.notInteractive.rawValue {
            return .notInteractive
        } else if status == errSecInteractionNotAllowed || laCode == LAError.systemCancel.rawValue || laCode == LAError.appCancel.rawValue {
            // errSecInteractionNotAllowed is the best available signal that the app couldn't
            // present the Keychain's biometric UI at all (e.g. backgrounded) -- unverified against
            // real-device behavior for this specific SecItemCopyMatching path, unlike the -7/-8
            // lockout codes above which were empirically confirmed (see file-level comments).
            return .systemCanceled
        } else if status == errSecAuthFailed {
            // Sometimes Secure Enclave returns authFailed instead of specific lockout error
            // so we re-check policy to confirm lockout
            if !canAuth && (laCode == -7 || laCode == -8 || laCode == LAError.biometryLockout.rawValue) {
                return .lockedOutPermanent
            }
        }
        return .unknown
    }

    private func mapCFError(_ error: CFError?) -> IdentityError {
        guard let error = error else { return .unknown }
        let code = CFErrorGetCode(error)
        let domain = CFErrorGetDomain(error) as String

        print("[LocalBiometric] CFError: domain=\(domain), code=\(code)")

        if code == -7 || code == -8 || code == LAError.biometryLockout.rawValue {
            return .lockedOut
        }
        if code == LAError.userCancel.rawValue || code == -2 {
            return .userCanceled
        }
        return .unknown
    }

    // RSA path: unwraps the ECIES-wrapped software RSA private key exactly like signInternal's
    // RSA path does, then decrypts with RSA-OAEP-SHA256 (matching Android's
    // "RSA/ECB/OAEPWithSHA-256AndMGF1Padding" Cipher transformation -- both platforms use SHA-256
    // for both the main OAEP digest and the MGF1 digest).
    // EC path: decrypts directly against the Secure Enclave EC key via ECIES
    // (eciesEncryptionStandardX963SHA256AESGCM), the same algorithm already used to wrap/unwrap
    // the RSA blob -- this is iOS's native equivalent of Android's manual ECDH+AES-GCM hybrid
    // decrypt (LocalCryptographyProvider.kt's performHybridDecryption).
    func decryptPayload(payload: String, keyAlias: String?, payloadFormat: IdentityPayloadFormat, config: IdentityDecryptConfig?, promptMessage: String?) async throws -> IdentityDecryptResult {
        await withBackgroundRetry(persist: config?.persistAcrossBackgrounding, isSystemCanceled: { $0.code == .systemCanceled }) {
            self.decryptPayloadAttempt(payload: payload, keyAlias: keyAlias, payloadFormat: payloadFormat, config: config, promptMessage: promptMessage)
        }
    }

    private func decryptPayloadAttempt(payload: String, keyAlias: String?, payloadFormat: IdentityPayloadFormat, config: IdentityDecryptConfig?, promptMessage: String?) -> IdentityDecryptResult {
        guard let ciphertext = crypto.decodePayload(payload, format: payloadFormat) else {
            return IdentityDecryptResult(error: "Invalid payload", code: .invalidInput)
        }

        let ctx = LAContext()
        ctx.localizedReason = promptMessage ?? "Decrypt"
        if config?.allowDeviceCredentials == false {
            ctx.localizedFallbackTitle = ""
        }
        currentContext = ctx
        defer { if currentContext === ctx { currentContext = nil } }

        let (ecKeyResult, status) = storage.getEcKey(alias: keyAlias, context: ctx)
        guard let ecKey = ecKeyResult else {
            let errorCode = mapKeyLookupFailure(status: status, ctx: ctx)
            print("[LocalBiometric] decrypt FAIL (key lookup): status=\(status), mapped=\(errorCode)")
            return IdentityDecryptResult(code: errorCode)
        }

        var error: Unmanaged<CFError>?
        let plaintext: Data
        if let wrapped = storage.getWrappedRsa(alias: keyAlias) {
            guard let rsaData = SecKeyCreateDecryptedData(ecKey, .eciesEncryptionStandardX963SHA256AESGCM, wrapped as CFData, &error) as Data? else {
                let errorCode = mapCFError(error?.takeRetainedValue())
                print("[LocalBiometric] decrypt FAIL (RSA unwrap): \(errorCode)")
                return IdentityDecryptResult(code: errorCode)
            }
            guard let rsaPriv = SecKeyCreateWithData(rsaData as CFData, [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits as String: 2048] as CFDictionary, nil) else {
                print("[LocalBiometric] decrypt FAIL: could not reconstruct unwrapped RSA key")
                return IdentityDecryptResult(error: "RSA key unwrap failed", code: .unknown)
            }
            guard let decrypted = SecKeyCreateDecryptedData(rsaPriv, .rsaEncryptionOAEPSHA256, ciphertext as CFData, &error) as Data? else {
                let errorCode = mapCFError(error?.takeRetainedValue())
                print("[LocalBiometric] decrypt FAIL (RSA-OAEP): \(errorCode)")
                return IdentityDecryptResult(code: errorCode)
            }
            plaintext = decrypted
        } else {
            guard let decrypted = SecKeyCreateDecryptedData(ecKey, .eciesEncryptionStandardX963SHA256AESGCM, ciphertext as CFData, &error) as Data? else {
                let errorCode = mapCFError(error?.takeRetainedValue())
                print("[LocalBiometric] decrypt FAIL (ECIES): \(errorCode)")
                return IdentityDecryptResult(code: errorCode)
            }
            plaintext = decrypted
        }

        // Matches Android's convention (`String(decrypted)`): the plaintext bytes are
        // interpreted directly as a UTF-8 string, not base64-encoded.
        guard let plaintextString = String(data: plaintext, encoding: .utf8) else {
            return IdentityDecryptResult(error: "Decrypted data is not valid UTF-8", code: .unknown)
        }
        return IdentityDecryptResult(decryptedData: plaintextString, code: .success)
    }

    func revokeIdentity(keyAlias: String?) async throws -> Bool {
        storage.deleteIdentity(alias: keyAlias)
        return true
    }

    func revokeAllIdentities() async throws -> Bool {
        storage.deleteAllIdentities()
        return true
    }

    // Deliberately promptless: getEcKey(context: nil) only obtains a SecKey *reference* (a local
    // operation), and reading a public key from a reference or from previously-persisted SPKI
    // bytes never touches the Secure Enclave's access control -- only an actual sign/decrypt
    // operation does. checkValidity's domain-state comparison is similarly promptless (it only
    // needs `canEvaluatePolicy`, not `evaluatePolicy`). This intentionally mirrors Android's
    // getIdentityStatus, which also never shows a biometric prompt.
    func getIdentityStatus(keyAlias: String?, checkValidity: Bool, keyFormat: IdentityKeyFormat) async throws -> IdentityInfo {
        let (key, _) = storage.getEcKey(alias: keyAlias, context: nil)
        guard let ecKey = key else {
            return IdentityInfo(exists: false)
        }

        // isHybridMode/publicKey follow iOS's convention (opposite of Android's, see CLAUDE.md):
        // a wrapped RSA blob present means this identity's primary key is RSA (isHybridMode
        // true), not that the EC key has a *separate* decrypt capability the way Android's
        // HYBRID_EC mode does -- so decryptingPublicKey/decryptingAlgorithm/decryptingKeySize
        // have no iOS equivalent and stay nil.
        let hasWrappedRsa = storage.getWrappedRsa(alias: keyAlias) != nil
        let algorithm = hasWrappedRsa ? "RSA" : "EC"
        let keySize: Int64 = hasWrappedRsa ? 2048 : 256
        let publicKeyStr: String?
        if hasWrappedRsa {
            publicKeyStr = storage.getRsaPublicKeySpki(alias: keyAlias).map { crypto.formatKeyData($0, format: keyFormat) }
        } else {
            publicKeyStr = SecKeyCopyPublicKey(ecKey).map { crypto.formatKey($0, format: keyFormat) }
        }

        var isValid = true
        if checkValidity {
            let ctx = LAContext()
            var error: NSError?
            let canAuth = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
            if canAuth, let baseline = storage.getDomainState(alias: keyAlias), let current = ctx.evaluatedPolicyDomainState {
                isValid = baseline == current
            }
            // If biometrics are currently unavailable, or no domain-state baseline was ever
            // recorded for this alias, validity can't be determined without a real crypto probe
            // (which would prompt the user just to answer a status query) -- default to `true`
            // rather than reporting a false negative, matching Android's own unconditional
            // `isValid = true` when the key exists.
        }

        return IdentityInfo(
            exists: true,
            isValid: isValid,
            algorithm: algorithm,
            keySize: keySize,
            isHybridMode: hasWrappedRsa,
            publicKey: publicKeyStr
        )
    }

    // Note: `config?.sensitiveTransaction` is intentionally unused here -- it's an Android-only
    // flag (maps to BiometricPrompt.setConfirmationRequired, which has no LAContext/LAPolicy
    // equivalent), documented as ignored on iOS/macOS in the pigeon schema.
    func verifyPresence(promptMessage: String, config: PresencePromptConfig?) async throws -> PresencePromptResult {
        await withBackgroundRetry(persist: config?.persistAcrossBackgrounding, isSystemCanceled: { $0.code == .systemCanceled }) {
            await self.verifyPresenceAttempt(promptMessage: promptMessage, config: config)
        }
    }

    private func verifyPresenceAttempt(promptMessage: String, config: PresencePromptConfig?) async -> PresencePromptResult {
        let ctx = LAContext()
        let allowCredentials = config?.allowDeviceCredentials ?? false

        // If device credentials (passcode) are NOT allowed, we hide the fallback button.
        if !allowCredentials {
            ctx.localizedFallbackTitle = ""
        }

        let policy: LAPolicy = allowCredentials ? .deviceOwnerAuthentication : .deviceOwnerAuthenticationWithBiometrics

        let (success, error) = await trackContext(ctx) { await self.evaluatePolicy(ctx, policy: policy, reason: promptMessage) }
        if success {
            return PresencePromptResult(success: true, code: .success)
        } else {
            let errorCode: IdentityError
            if let laError = error as? LAError {
                switch laError.code {
                case .userCancel: errorCode = .userCanceled
                case .biometryLockout: errorCode = .lockedOutPermanent
                case .biometryNotAvailable: errorCode = .notAvailable
                case .biometryNotEnrolled: errorCode = .notEnrolled
                case .passcodeNotSet: errorCode = .passcodeNotSet
                case .authenticationFailed: errorCode = .authenticationFailed
                case .notInteractive: errorCode = .notInteractive
                // Previously both fell through to `.unknown` -- these are the prompt being
                // interrupted by the system (e.g. the app was backgrounded mid-prompt), which is
                // exactly what `persistAcrossBackgrounding` needs to detect to know when to retry.
                case .systemCancel, .appCancel: errorCode = .systemCanceled
                default: errorCode = .unknown
                }
            } else {
                errorCode = .unknown
            }
            return PresencePromptResult(success: false, code: errorCode)
        }
    }

    func isDeviceSecure() async throws -> Bool {
        let ctx = LAContext()
        return ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func acknowledgeIdentityChange() async throws {
        changeMonitor.acknowledgeChange()
    }

    func stopAuthentication() async throws -> Bool {
        guard let ctx = currentContext else { return false }
        currentContext = nil
        ctx.invalidate()
        return true
    }
}
