import Foundation
import XCTest
@testable import iADB

final class ADBKeyPEMTests: XCTestCase {
    /// A short PKCS#1-shaped blob is enough: the wrapper code never looks at
    /// the key material, only at the length prefixes it writes.
    private let pkcs1 = Data([0x30, 0x0B, 0x02, 0x01, 0x00, 0x02, 0x01, 0x01, 0x04, 0x03, 0x01, 0x02, 0x03])

    func testPKCS8RoundTripPreservesTheKeyBody() {
        let wrapped = ADBKeyPEM.wrapPKCS8(pkcs1)

        XCTAssertEqual(wrapped.first, 0x30)
        XCTAssertEqual(ADBKeyPEM.unwrapPKCS8(wrapped), pkcs1)
    }

    func testWrappedFormAnnouncesPKCS8NotPKCS1() {
        let wrapped = ADBKeyPEM.wrapPKCS8(pkcs1)

        // version INTEGER 0 followed by the rsaEncryption AlgorithmIdentifier.
        XCTAssertEqual(
            Array(wrapped.prefix(4)),
            [0x30, UInt8(wrapped.count - 2), 0x02, 0x01]
        )
        XCTAssertNotNil(wrapped.range(of: Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01])))
    }

    func testUnwrapRejectsBlobsWithoutAnRSAOID() {
        // SEQUENCE { INTEGER 0, SEQUENCE { OID ecPublicKey, OID prime256v1 }, OCTET STRING }
        let notRSA = Data([
            0x30, 0x1B,
            0x02, 0x01, 0x00,
            0x30, 0x13,
            0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
            0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07,
            0x04, 0x01, 0x00,
        ])

        XCTAssertNil(ADBKeyPEM.unwrapPKCS8(notRSA))
    }

    func testUnwrapRejectsTruncatedAndEmptyInput() {
        XCTAssertNil(ADBKeyPEM.unwrapPKCS8(Data()))
        XCTAssertNil(ADBKeyPEM.unwrapPKCS8(Data([0x30])))
        XCTAssertNil(ADBKeyPEM.unwrapPKCS8(Data([0x30, 0x20, 0x02, 0x01, 0x00])))
    }

    func testPEMRoundTrip() {
        let pem = ADBKeyPEM.encode(pkcs1)

        XCTAssertTrue(pem.hasPrefix("-----BEGIN PRIVATE KEY-----\n"))
        XCTAssertTrue(pem.hasSuffix("-----END PRIVATE KEY-----\n"))

        let decoded = ADBKeyPEM.decode(pem)
        XCTAssertEqual(decoded?.der, pkcs1)
        XCTAssertEqual(decoded?.label, "PRIVATE KEY")
    }

    func testPEMBodyWrapsAtSixtyFourColumns() {
        let long = Data(repeating: 0x41, count: 300)
        let pem = ADBKeyPEM.encode(long)
        let body = pem
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }

        XCTAssertGreaterThan(body.count, 1)
        for line in body {
            XCTAssertLessThanOrEqual(line.count, 64)
        }
        XCTAssertEqual(ADBKeyPEM.decode(pem)?.der, long)
    }

    func testDecodeAcceptsWindowsLineEndingsAndPKCS1Label() {
        let pem = ADBKeyPEM.encode(pkcs1, label: ADBKeyPEM.pkcs1Label)
            .replacingOccurrences(of: "\n", with: "\r\n")

        let decoded = ADBKeyPEM.decode(pem)
        XCTAssertEqual(decoded?.der, pkcs1)
        XCTAssertEqual(decoded?.label, ADBKeyPEM.pkcs1Label)
        XCTAssertEqual(ADBKeyPEM.pkcs1(fromPEMBody: pkcs1, label: ADBKeyPEM.pkcs1Label), pkcs1)
    }

    func testDecodeRejectsTextWithoutABlock() {
        XCTAssertNil(ADBKeyPEM.decode(""))
        XCTAssertNil(ADBKeyPEM.decode("not a key at all"))
    }

    func testPKCS8LabelUnwrapsThroughHelper() {
        let pem = ADBKeyPEM.encode(ADBKeyPEM.wrapPKCS8(pkcs1))
        guard let decoded = ADBKeyPEM.decode(pem) else {
            XCTFail("expected a PEM body")
            return
        }

        XCTAssertEqual(
            ADBKeyPEM.pkcs1(fromPEMBody: decoded.der, label: decoded.label),
            pkcs1
        )
    }
}
