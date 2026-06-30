import Flutter
import UIKit
import LocalAuthentication

public class LocalBiometricPlugin: NSObject, FlutterPlugin, LocalBiometricApi {

    private let storage = LocalSecureIdentityStorage()
    private let crypto = LocalIdentityCryptoEngine()
    private let changeMonitor = LocalIdentityChangeMonitor()

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = LocalBiometricPlugin()
        LocalBiometricApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)

        let eventChannel = FlutterEventChannel(name: "com.amit.local_biometric/changes", binaryMessenger: registrar.messenger())
        eventChannel.setStreamHandler(instance.changeMonitor)
    }

    func checkAvailability(completion: @escaping (Result<IdentityAvailability, Error>) -> Void) {
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

        completion(.success(IdentityAvailability(
            canAuthenticate: available,
            hasEnrolledBiometrics: error?.code != LAError.biometryNotEnrolled.rawValue,
            availableBiometrics: types,
            reason: isLockedOut ? "lockedOutPermanent" : error?.localizedDescription
        )))
    }

    func enrollIdentity(keyAlias: String?, config: IdentityEnrollmentConfig?, keyFormat: IdentityKeyFormat, promptMessage: String?, completion: @escaping (Result<IdentityEnrollmentResult, Error>) -> Void) {
        let sigType = config?.signatureType ?? .rsa
        let biometryCurrent = config?.setInvalidatedByBiometricEnrollment ?? false
        let useCreds = config?.useDeviceCredentials ?? false

        if config?.failIfExists == true {
             let (existing, _) = storage.getEcKey(alias: keyAlias, context: nil)
             if existing != nil {
                 completion(.success(IdentityEnrollmentResult(publicKey: nil, error: "Identity exists", code: .keyAlreadyExists)))
                 return
             }
        }

        storage.deleteIdentity(alias: keyAlias)

        let generate = {
            guard let ecKey = self.storage.createEcKey(alias: keyAlias, useCreds: useCreds, biometryCurrent: biometryCurrent) else {
                completion(.success(IdentityEnrollmentResult(publicKey: nil, error: "EC Gen Failed", code: .unknown)))
                return
            }

            if sigType == .ecdsa {
                completion(.success(IdentityEnrollmentResult(
                    publicKey: self.crypto.formatKey(SecKeyCopyPublicKey(ecKey)!, format: keyFormat),
                    code: .success, algorithm: "EC", keySize: 256, isHybridMode: false
                )))
            } else {
                let rsaAttrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048, kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: false]]
                var error: Unmanaged<CFError>?
                guard let rsaPriv = SecKeyCreateRandomKey(rsaAttrs as CFDictionary, &error),
                      let rsaData = SecKeyCopyExternalRepresentation(rsaPriv, &error) as Data?,
                      let pub = SecKeyCopyPublicKey(ecKey),
                      let wrapped = SecKeyCreateEncryptedData(pub, .eciesEncryptionStandardX963SHA256AESGCM, rsaData as CFData, &error) as Data? else {
                    completion(.success(IdentityEnrollmentResult(publicKey: nil, error: "RSA Gen Failed", code: .unknown)))
                    return
                }
                self.storage.saveWrappedRsa(alias: keyAlias, wrapped: wrapped)
                completion(.success(IdentityEnrollmentResult(
                    publicKey: self.crypto.formatKey(SecKeyCopyPublicKey(rsaPriv)!, format: keyFormat),
                    code: .success, algorithm: "RSA", keySize: 2048, isHybridMode: true
                )))
            }
        }

        if config?.enforceBiometric == true {
            let ctx = LAContext()
            if !useCreds {
                ctx.localizedFallbackTitle = ""
            }
            ctx.evaluatePolicy(useCreds ? .deviceOwnerAuthentication : .deviceOwnerAuthenticationWithBiometrics, localizedReason: promptMessage ?? "Enroll") { success, error in
                if success {
                    generate()
                } else {
                    let laError = error as NSError?
                    let laCode = laError?.code ?? 0
                    var errorCode: IdentityError = .userCanceled
                    if laCode == -7 || laCode == -8 || laCode == LAError.biometryLockout.rawValue {
                        errorCode = .lockedOut
                    }
                    print("[LocalBiometric] enroll FAIL: laCode=\(laCode), mapped=\(errorCode)")
                    completion(.success(IdentityEnrollmentResult(code: errorCode)))
                }
            }
        } else {
            generate()
        }
    }

    func signPayload(payload: String, keyAlias: String?, config: IdentitySignatureConfig?, signatureFormat: IdentitySignatureFormat, keyFormat: IdentityKeyFormat, promptMessage: String?, completion: @escaping (Result<IdentitySignatureResult, Error>) -> Void) {
        signInternal(data: payload.data(using: .utf8)!, alias: keyAlias, config: config, sigFormat: signatureFormat, keyFormat: keyFormat, prompt: promptMessage, completion: completion)
    }

    func signPayloadBytes(payload: FlutterStandardTypedData, keyAlias: String?, config: IdentitySignatureConfig?, signatureFormat: IdentitySignatureFormat, keyFormat: IdentityKeyFormat, promptMessage: String?, completion: @escaping (Result<IdentitySignatureResult, Error>) -> Void) {
        signInternal(data: payload.data, alias: keyAlias, config: config, sigFormat: signatureFormat, keyFormat: keyFormat, prompt: promptMessage, completion: completion)
    }

    private func signInternal(data: Data, alias: String?, config: IdentitySignatureConfig?, sigFormat: IdentitySignatureFormat, keyFormat: IdentityKeyFormat, prompt: String?, completion: @escaping (Result<IdentitySignatureResult, Error>) -> Void) {
        let ctx = LAContext(); ctx.localizedReason = prompt ?? "Sign"

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
                    completion(.success(IdentitySignatureResult(code: errorCode)))
                    return
                }
                guard let rsaPriv = SecKeyCreateWithData(rsaData as CFData, [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits as String: 2048] as CFDictionary, nil),
                      let sig = SecKeyCreateSignature(rsaPriv, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, &error) as Data? else {
                    let errorCode = mapCFError(error?.takeRetainedValue())
                    print("[LocalBiometric] RSA Sign FAIL: \(errorCode)")
                    completion(.success(IdentitySignatureResult(code: errorCode)))
                    return
                }
                completion(.success(IdentitySignatureResult(signature: crypto.formatSignature(sig, format: sigFormat), code: .success, algorithm: "RSA", keySize: 2048)))
            } else {
                guard let sig = SecKeyCreateSignature(ecKey, .ecdsaSignatureMessageX962SHA256, data as CFData, &error) as Data? else {
                    let errorCode = mapCFError(error?.takeRetainedValue())
                    print("[LocalBiometric] EC Sign FAIL: \(errorCode)")
                    completion(.success(IdentitySignatureResult(code: errorCode)))
                    return
                }
                completion(.success(IdentitySignatureResult(signature: crypto.formatSignature(sig, format: sigFormat), code: .success, algorithm: "EC", keySize: 256)))
            }
        } else {
            var errorCode: IdentityError = .unknown

            // LAError codes:
            // -7 is biometryLockout
            // -6 is biometryNotAvailable
            // -8 is biometryNotEnrolled

            var laError: NSError?
            let canAuth = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &laError)
            let laCode = laError?.code ?? 0

            if status == errSecItemNotFound {
                errorCode = .keyNotFound
            } else if laCode == -7 || laCode == -8 || laCode == LAError.biometryLockout.rawValue {
                errorCode = .lockedOutPermanent
            } else if status == errSecUserCanceled || laCode == LAError.userCancel.rawValue {
                errorCode = .userCanceled
            } else if status == errSecAuthFailed {
                // Sometimes Secure Enclave returns authFailed instead of specific lockout error
                // so we re-check policy to confirm lockout
                if !canAuth && (laCode == -7 || laCode == -8 || laCode == LAError.biometryLockout.rawValue) {
                    errorCode = .lockedOutPermanent
                }
            }

            print("[LocalBiometric] sign FAIL: status=\(status), laCode=\(laCode), mapped=\(errorCode)")
            completion(.success(IdentitySignatureResult(code: errorCode)))
        }
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

    func decryptPayload(payload: String, keyAlias: String?, payloadFormat: IdentityPayloadFormat, config: IdentityDecryptConfig?, promptMessage: String?, completion: @escaping (Result<IdentityDecryptResult, Error>) -> Void) {
        completion(.success(IdentityDecryptResult(error: "Not implemented", code: .unknown)))
    }

    func revokeIdentity(keyAlias: String?, completion: @escaping (Result<Bool, Error>) -> Void) {
        storage.deleteIdentity(alias: keyAlias)
        completion(.success(true))
    }

    func revokeAllIdentities(completion: @escaping (Result<Bool, Error>) -> Void) {
        storage.deleteAllIdentities()
        completion(.success(true))
    }

    func getIdentityStatus(keyAlias: String?, checkValidity: Bool, keyFormat: IdentityKeyFormat, completion: @escaping (Result<IdentityInfo, Error>) -> Void) {
        let (key, _) = storage.getEcKey(alias: keyAlias, context: nil)
        let exists = key != nil
        completion(.success(IdentityInfo(exists: exists)))
    }

    func verifyPresence(promptMessage: String, config: PresencePromptConfig?, completion: @escaping (Result<PresencePromptResult, Error>) -> Void) {
        let ctx = LAContext()
        let allowCredentials = config?.allowDeviceCredentials ?? false

        // If device credentials (passcode) are NOT allowed, we hide the fallback button.
        if !allowCredentials {
            ctx.localizedFallbackTitle = ""
        }

        let policy: LAPolicy = allowCredentials ? .deviceOwnerAuthentication : .deviceOwnerAuthenticationWithBiometrics

        ctx.evaluatePolicy(policy, localizedReason: promptMessage) { success, error in
            if success {
                completion(.success(PresencePromptResult(success: true, code: .success)))
            } else {
                let errorCode: IdentityError
                if let laError = error as? LAError {
                    switch laError.code {
                    case .userCancel: errorCode = .userCanceled
                    case .biometryLockout: errorCode = .lockedOutPermanent
                    case .biometryNotAvailable: errorCode = .notAvailable
                    case .biometryNotEnrolled: errorCode = .notEnrolled
                    case .passcodeNotSet: errorCode = .passcodeNotSet
                    default: errorCode = .unknown
                    }
                } else {
                    errorCode = .unknown
                }
                completion(.success(PresencePromptResult(success: false, code: errorCode)))
            }
        }
    }

    func isDeviceSecure(completion: @escaping (Result<Bool, Error>) -> Void) {
        let ctx = LAContext()
        completion(.success(ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)))
    }

    func acknowledgeIdentityChange(completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }
}
