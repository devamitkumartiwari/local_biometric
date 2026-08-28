import Foundation
import Security

class LocalIdentityCryptoEngine {

    func formatKey(_ key: SecKey, format: IdentityKeyFormat) -> String {
        guard let data = subjectPublicKeyInfoData(for: key) else { return "" }
        return formatKeyData(data, format: format)
    }

    // Formats already-DER-encoded SubjectPublicKeyInfo bytes, e.g. ones persisted earlier by
    // `subjectPublicKeyInfoData(for:)` -- used for keys (like the wrapped RSA public key) whose
    // SPKI bytes were computed once at enrollment time and saved, rather than a live SecKey ref.
    func formatKeyData(_ data: Data, format: IdentityKeyFormat) -> String {
        switch format {
        case .base64, .raw: return data.base64EncodedString()
        case .hex: return data.map { String(format: "%02x", $0) }.joined()
        case .pem:
            let base64 = data.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            return "-----BEGIN PUBLIC KEY-----\n\(base64)\n-----END PUBLIC KEY-----"
        }
    }

    func formatSignature(_ data: Data, format: IdentitySignatureFormat) -> String {
        switch format {
        case .base64, .raw: return data.base64EncodedString()
        case .hex: return data.map { String(format: "%02x", $0) }.joined()
        }
    }

    // Matches Android's LocalBiometricFormatUtils.parsePayload: base64 and raw both decode as
    // base64 (there is no distinct raw-bytes wire format for the String-typed `payload` input),
    // hex decodes as hex.
    func decodePayload(_ payload: String, format: IdentityPayloadFormat) -> Data? {
        switch format {
        case .base64, .raw:
            return Data(base64Encoded: payload)
        case .hex:
            return Self.hexDecode(payload)
        }
    }

    private static func hexDecode(_ hex: String) -> Data? {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            guard let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex),
                  let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        return data
    }

    func subjectPublicKeyInfoData(for key: SecKey) -> Data? {
        var error: Unmanaged<CFError>?
        guard let raw = SecKeyCopyExternalRepresentation(key, &error) as Data? else { return nil }
        guard let attrs = SecKeyCopyAttributes(key) as? [String: Any],
              let type = attrs[kSecAttrKeyType as String] as? String else { return raw }

        if type == (kSecAttrKeyTypeRSA as String) {
            let header: [UInt8] = [0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00]
            var bitString = Data([0x00]); bitString.append(raw)
            let bitStringEncoded = wrapASN1(tag: 0x03, content: bitString)
            var sequence = Data(header); sequence.append(bitStringEncoded)
            return wrapASN1(tag: 0x30, content: sequence)
        } else if type == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            let header: [UInt8] = [0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]
            var bitString = Data([0x00]); bitString.append(raw)
            let bitStringEncoded = wrapASN1(tag: 0x03, content: bitString)
            var sequence = Data(header); sequence.append(bitStringEncoded)
            return wrapASN1(tag: 0x30, content: sequence)
        }
        return raw
    }

    private func wrapASN1(tag: UInt8, content: Data) -> Data {
        var data = Data([tag])
        let len = content.count
        if len < 128 {
            data.append(UInt8(len))
        } else if len < 256 {
            data.append(0x81); data.append(UInt8(len))
        } else {
            data.append(0x82); data.append(UInt8(len >> 8)); data.append(UInt8(len & 0xFF))
        }
        data.append(content)
        return data
    }
}
