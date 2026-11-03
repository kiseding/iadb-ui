import Foundation

/// Converts between the PEM file desktop `adb` writes and the DER blob that
/// Security.framework hands back for an RSA key.
///
/// `~/.android/adbkey` is a PKCS#8 PEM (`-----BEGIN PRIVATE KEY-----`), while
/// `SecKeyCopyExternalRepresentation` and `SecKeyCreateWithData` speak PKCS#1.
/// Verified imports and exports therefore need the outer wrapper added or
/// stripped, which is all this type does — no key material is interpreted.
enum ADBKeyPEM {
    static let pkcs8Label = "PRIVATE KEY"
    static let pkcs1Label = "RSA PRIVATE KEY"

    // MARK: - PEM

    /// Wraps raw DER into a PEM block, one 64-character line per row.
    static func encode(_ der: Data, label: String = pkcs8Label) -> String {
        let base64 = der
            .base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "-----BEGIN \(label)-----\n\(base64)\n-----END \(label)-----\n"
    }

    /// Returns the DER body and the label announced by the header, or `nil`
    /// when the text holds no PEM block at all.
    static func decode(_ text: String) -> (der: Data, label: String)? {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }

        guard let headerIndex = lines.firstIndex(where: { $0.hasPrefix("-----BEGIN ") }) else {
            return nil
        }
        let header = lines[headerIndex]
        let label = header
            .replacingOccurrences(of: "-----BEGIN ", with: "")
            .replacingOccurrences(of: "-----", with: "")
            .trimmingCharacters(in: .whitespaces)

        var body: [String] = []
        for line in lines[(headerIndex + 1)...] {
            if line.hasPrefix("-----END") { break }
            if line.isEmpty || line.hasPrefix("Proc-Type") || line.hasPrefix("DEK-Info") {
                continue
            }
            body.append(line)
        }

        guard let der = Data(base64Encoded: body.joined(), options: .ignoreUnknownCharacters) else {
            return nil
        }
        return (der, label)
    }

    // MARK: - PKCS#8

    /// Adds the `PrivateKeyInfo` wrapper around a PKCS#1 `RSAPrivateKey`.
    static func wrapPKCS8(_ pkcs1: Data) -> Data {
        // version INTEGER 0, rsaEncryption AlgorithmIdentifier, OCTET STRING key
        let version = Data([0x02, 0x01, 0x00])
        let algorithm = Data([
            0x30, 0x0D,
            0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01,
            0x05, 0x00,
        ])
        return tlv(0x30, version + algorithm + tlv(0x04, pkcs1))
    }

    /// Returns the PKCS#1 body of a PKCS#8 blob, or `nil` when the input is not
    /// a well-formed `PrivateKeyInfo`.
    static func unwrapPKCS8(_ der: Data) -> Data? {
        var outer = Cursor(bytes: [UInt8](der))
        guard let sequence = outer.next(), sequence.tag == 0x30 else { return nil }

        var inner = Cursor(bytes: Array(sequence.body))
        guard let version = inner.next(), version.tag == 0x02 else { return nil }
        guard let algorithm = inner.next(), algorithm.tag == 0x30 else { return nil }
        guard let key = inner.next(), key.tag == 0x04 else { return nil }

        // Only rsaEncryption is ever wrapped here; anything else would produce
        // a key SecKeyCreateWithData cannot read.
        guard containsRSAOID(Array(algorithm.body)) else { return nil }
        return Data(key.body)
    }

    /// Turns any accepted PEM body into PKCS#1, honouring the header label.
    static func pkcs1(fromPEMBody der: Data, label: String) -> Data? {
        if label.contains("RSA PRIVATE KEY") { return der }
        return unwrapPKCS8(der)
    }

    // MARK: - DER primitives

    private static let rsaOID: [UInt8] = [
        0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01,
    ]

    private static func containsRSAOID(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= rsaOID.count else { return false }
        for start in 0...(bytes.count - rsaOID.count) where Array(bytes[start..<(start + rsaOID.count)]) == rsaOID {
            return true
        }
        return false
    }

    private static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        out.append(contentsOf: lengthBytes(content.count))
        out.append(content)
        return out
    }

    private static func lengthBytes(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        var value = length
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    private struct Cursor {
        let bytes: [UInt8]
        var index = 0

        mutating func next() -> (tag: UInt8, body: ArraySlice<UInt8>)? {
            guard index + 2 <= bytes.count else { return nil }
            let tag = bytes[index]
            index += 1

            var length = Int(bytes[index])
            index += 1
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard count > 0, count <= 4, index + count <= bytes.count else { return nil }
                length = 0
                for _ in 0..<count {
                    length = (length << 8) | Int(bytes[index])
                    index += 1
                }
            }
            guard length >= 0, index + length <= bytes.count else { return nil }
            let body = bytes[index..<(index + length)]
            index += length
            return (tag, body)
        }
    }
}
