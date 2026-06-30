import Foundation
import Security

class LocalIdentityCryptoEngine {

    func formatKey(_ key: SecKey, format: IdentityKeyFormat) -> String {
        guard let data = getSubjectPublicKeyInfo(for: key) else { return "" }
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

    private func getSubjectPublicKeyInfo(for key: SecKey) -> Data? {
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
