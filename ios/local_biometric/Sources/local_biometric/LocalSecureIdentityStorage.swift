import Foundation
import LocalAuthentication
import Security

struct LocalBiometricConstants {
    static let servicePrefix = "com.amit.local_biometric"
    static func biometricKeyTag(_ alias: String?) -> Data {
        let tag = alias != nil ? "\(servicePrefix).key.\(alias!)" : "\(servicePrefix).key.default"
        return tag.data(using: .utf8)!
    }
    static func wrappedKeyService(_ alias: String?) -> String {
        return alias != nil ? "\(servicePrefix).wrapped.\(alias!)" : "\(servicePrefix).wrapped.default"
    }
    static func domainStateService(_ alias: String?) -> String {
        return alias != nil ? "\(servicePrefix).domain.\(alias!)" : "\(servicePrefix).domain.default"
    }
    static func metaService(_ alias: String?) -> String {
        return alias != nil ? "\(servicePrefix).meta.\(alias!)" : "\(servicePrefix).meta.default"
    }
    static func rsaPublicKeyService(_ alias: String?) -> String {
        return alias != nil ? "\(servicePrefix).rsapub.\(alias!)" : "\(servicePrefix).rsapub.default"
    }
}

class LocalSecureIdentityStorage {

    // `requireAuthentication: false` -- security-model change, see the pigeon doc comment on
    // IdentityEnrollmentConfig.requireAuthentication -- drops `.userPresence`/`.biometryAny`/
    // `.biometryCurrentSet` from the access control entirely (only `.privateKeyUsage` remains,
    // meaning any use of the key is unrestricted by biometric/passcode gating) and switches from
    // `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` (requires a passcode to even be set) to
    // `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (device-bound, no passcode requirement).
    func createEcKey(alias: String?, useCreds: Bool, biometryCurrent: Bool, requireAuthentication: Bool = true) -> SecKey? {
        let flags: SecAccessControlCreateFlags
        let accessible: CFString
        if requireAuthentication {
            flags = [.privateKeyUsage, useCreds ? .userPresence : (biometryCurrent ? .biometryCurrentSet : .biometryAny)]
            accessible = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        } else {
            flags = [.privateKeyUsage]
            accessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        guard let access = SecAccessControlCreateWithFlags(kCFAllocatorDefault, accessible, flags, nil) else { return nil }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecAttrAccessControl as String: access,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: LocalBiometricConstants.biometricKeyTag(alias)
            ]
        ]

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else { return nil }

        if requireAuthentication {
            // Always baseline the domain state, not just for `.biometryCurrentSet` keys: even a
            // `.biometryAny` key is invalidated by *removing all* enrolled biometrics (though not
            // by adding/changing one), so change detection needs a baseline for both invalidation
            // styles to tell "no change" from "haven't checked yet" in LocalIdentityChangeMonitor.
            // Skipped entirely when `requireAuthentication` is false: there is no biometric gating
            // to track domain-state changes for.
            saveDomainState(alias: alias)
        }
        saveMetadata(alias: alias, useCreds: useCreds)

        return key
    }

    // Baseline domain-state snapshot for `alias`, as captured by the most recent
    // saveDomainState call (at key creation, or re-baselined by acknowledgeIdentityChange).
    // Returns nil if no snapshot has ever been saved (e.g. the key predates this feature, or
    // biometrics were unavailable at enrollment time).
    func getDomainState(alias: String?) -> Data? {
        let service = LocalBiometricConstants.domainStateService(alias)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: service,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess {
            return result as? Data
        }
        return nil
    }

    func saveWrappedRsa(alias: String?, wrapped: Data) {
        let service = LocalBiometricConstants.wrappedKeyService(alias)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: service,
            kSecValueData as String: wrapped,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    func getWrappedRsa(alias: String?) -> Data? {
        let service = LocalBiometricConstants.wrappedKeyService(alias)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: service,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess {
            return result as? Data
        }
        return nil
    }

    // The wrapped RSA private key blob (saveWrappedRsa/getWrappedRsa above) can only be read back
    // by decrypting it with the Secure Enclave EC key, which requires a biometric prompt --
    // that's unsuitable for a cheap `getIdentityStatus` lookup. The RSA *public* key isn't
    // secret, so it's persisted separately here (in DER SubjectPublicKeyInfo form) at enrollment
    // time so status queries can read it back without ever touching the EC key.
    func saveRsaPublicKeySpki(alias: String?, spki: Data) {
        let service = LocalBiometricConstants.rsaPublicKeyService(alias)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: service,
            kSecValueData as String: spki,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    func getRsaPublicKeySpki(alias: String?) -> Data? {
        let service = LocalBiometricConstants.rsaPublicKeyService(alias)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: service,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess {
            return result as? Data
        }
        return nil
    }

    func getEcKey(alias: String?, context: LAContext?) -> (SecKey?, OSStatus) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: LocalBiometricConstants.biometricKeyTag(alias),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true
        ]
        if let context = context {
            query[kSecUseAuthenticationContext as String] = context
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            let key = result as! SecKey
            return (key, status)
        }
        return (nil, status)
    }

    func deleteIdentity(alias: String?) {
        let tag = LocalBiometricConstants.biometricKeyTag(alias)
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag
        ]
        SecItemDelete(keyQuery as CFDictionary)

        let wrappedQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: LocalBiometricConstants.wrappedKeyService(alias)
        ]
        SecItemDelete(wrappedQuery as CFDictionary)

        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: LocalBiometricConstants.domainStateService(alias)] as CFDictionary)
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: LocalBiometricConstants.metaService(alias)] as CFDictionary)
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: LocalBiometricConstants.rsaPublicKeyService(alias)] as CFDictionary)
    }

    func deleteAllIdentities() {
        SecItemDelete([kSecClass as String: kSecClassKey] as CFDictionary)
        SecItemDelete([kSecClass as String: kSecClassGenericPassword] as CFDictionary)
    }

    func saveDomainState(alias: String?) {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        guard let state = ctx.evaluatedPolicyDomainState else { return }

        let service = LocalBiometricConstants.domainStateService(alias)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: service
        ]
        let attrs: [String: Any] = [kSecValueData as String: state]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = state
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private func saveMetadata(alias: String?, useCreds: Bool) {
        let service = LocalBiometricConstants.metaService(alias)
        let data = Data([useCreds ? 1 : 0])
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: service
        ]
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func getMetadata(alias: String?) -> Bool? {
        let service = LocalBiometricConstants.metaService(alias)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: service,
            kSecReturnData as String: true
        ]
        var res: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &res) == errSecSuccess, let d = res as? Data {
            return d.first == 1
        }
        return nil
    }
}
