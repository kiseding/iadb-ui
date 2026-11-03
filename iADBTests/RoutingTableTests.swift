import XCTest
@testable import iADB

/// Exercises the routing payload parser against synthetic kernel output.
///
/// `sysctl` cannot be scripted, so the split between "read the table" and
/// "walk the bytes" is what makes this testable at all. Getting the stride
/// wrong here does not crash — it silently returns plausible addresses read
/// from the wrong offset — which is exactly why the fixtures matter.
final class RoutingTableTests: XCTestCase {

    func testDefaultGatewayIsParsedFromThePayload() {
        let raw = payload(
            flags: rtfUp | rtfGateway,
            components: [(rtaDestination, "0.0.0.0"), (rtaGateway, "192.168.43.254")]
        )

        let messages = NetworkRouteTable.parse(raw)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(NetworkRouteTable.defaultGateway(in: messages), "192.168.43.254")
    }

    /// An on-link route carries `RTF_UP` too. Only the default route has an
    /// all-zero destination, and that is what separates the two.
    func testNonDefaultRouteIsNotReportedAsGateway() {
        let raw = payload(
            flags: rtfUp | rtfGateway,
            components: [(rtaDestination, "10.0.0.0"), (rtaGateway, "192.168.43.254")]
        )

        XCTAssertNil(NetworkRouteTable.defaultGateway(in: NetworkRouteTable.parse(raw)))
    }

    func testNeighboursComeFromTheArpEntries() {
        let raw = payload(
            flags: rtfUp | rtfLLInfo,
            components: [(rtaDestination, "192.168.43.155")]
        )

        XCTAssertEqual(
            NetworkRouteTable.neighbours(in: NetworkRouteTable.parse(raw)),
            ["192.168.43.155"]
        )
    }

    /// Two messages back to back prove the stride: a wrong record length would
    /// leave the second header misaligned and drop or mangle it.
    func testTwoMessagesInOnePayloadAreBothParsed() {
        let raw = payload(
            flags: rtfUp | rtfGateway,
            components: [(rtaDestination, "0.0.0.0"), (rtaGateway, "192.168.43.254")]
        ) + payload(
            flags: rtfUp | rtfLLInfo,
            components: [(rtaDestination, "192.168.43.155")]
        )

        let messages = NetworkRouteTable.parse(raw)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(NetworkRouteTable.defaultGateway(in: messages), "192.168.43.254")
        XCTAssertEqual(NetworkRouteTable.neighbours(in: messages), ["192.168.43.155"])
    }

    /// `struct rt_metrics` grew over time, so the header is 76 bytes on older
    /// releases and 96 on current ones. The parser works the size out from the
    /// payload, which is the only reason both can be read by the same code.
    func testOlderShorterHeaderIsAlsoUnderstood() {
        let raw = payload(
            headerSize: 76,
            flags: rtfUp | rtfGateway,
            components: [(rtaDestination, "0.0.0.0"), (rtaGateway, "192.168.1.1")]
        )

        XCTAssertEqual(
            NetworkRouteTable.defaultGateway(in: NetworkRouteTable.parse(raw)),
            "192.168.1.1"
        )
    }

    /// The header still claims the original length, so a truncated message must
    /// be dropped whole rather than reported with a half-read address.
    func testTruncatedPayloadYieldsNothing() {
        let raw = payload(
            flags: rtfUp | rtfGateway,
            components: [(rtaDestination, "0.0.0.0"), (rtaGateway, "192.168.43.254")]
        )

        XCTAssertTrue(NetworkRouteTable.parse(Array(raw.prefix(raw.count - 4))).isEmpty)
    }

    /// A payload that is not a routing table at all must not be walked as one.
    func testGarbagePayloadYieldsNothing() {
        let noise = (0 ..< 512).map { UInt8(($0 &* 37) & 0xFF) }
        XCTAssertTrue(NetworkRouteTable.parse(noise).isEmpty)
    }

    func testEmptyPayloadIsSafe() {
        XCTAssertTrue(NetworkRouteTable.parse([] as [UInt8]).isEmpty)
        XCTAssertNil(
            NetworkRouteTable.defaultGateway(in: [] as [NetworkRouteTable.RoutingMessage])
        )
        XCTAssertTrue(
            NetworkRouteTable.neighbours(in: [] as [NetworkRouteTable.RoutingMessage]).isEmpty
        )
    }

    // MARK: - Fixtures
    //
    // Built as raw bytes rather than by filling in `rt_msghdr`: that struct is
    // not imported into Swift on iOS, and its size differs between OS releases.

    private let rtfUp: Int32 = 0x1
    private let rtfGateway: Int32 = 0x2
    private let rtfLLInfo: Int32 = 0x400

    private let rtaDestination: Int32 = 0x1
    private let rtaGateway: Int32 = 0x2

    /// One routing message: a zeroed header of `headerSize` bytes with the
    /// fields the parser reads filled in, followed by its sockaddr records.
    private func payload(
        headerSize: Int = 96,
        flags: Int32,
        components: [(Int32, String)]
    ) -> [UInt8] {
        var bits: Int32 = 0
        var records: [UInt8] = []

        for (bit, text) in components {
            bits |= bit
            var record = [UInt8](repeating: 0, count: 16)
            record[0] = 16                      // sa_len
            record[1] = 2                       // AF_INET
            let octets = text.split(separator: ".").compactMap { UInt8($0) }
            for (index, octet) in octets.enumerated() where index < 4 {
                record[4 + index] = octet
            }
            records += record
        }

        let total = headerSize + records.count
        var bytes = [UInt8](repeating: 0, count: headerSize)
        bytes[0] = UInt8(total & 0xFF)          // rtm_msglen (low)
        bytes[1] = UInt8((total >> 8) & 0xFF)   // rtm_msglen (high)
        bytes[2] = 5                            // rtm_version
        bytes[3] = 4                            // rtm_type
        writeInt32(&bytes, 8, flags)            // rtm_flags
        writeInt32(&bytes, 12, bits)            // rtm_addrs
        return bytes + records
    }

    private func writeInt32(_ bytes: inout [UInt8], _ index: Int, _ value: Int32) {
        let raw = UInt32(bitPattern: value)
        bytes[index] = UInt8(raw & 0xFF)
        bytes[index + 1] = UInt8((raw >> 8) & 0xFF)
        bytes[index + 2] = UInt8((raw >> 16) & 0xFF)
        bytes[index + 3] = UInt8((raw >> 24) & 0xFF)
    }
}
