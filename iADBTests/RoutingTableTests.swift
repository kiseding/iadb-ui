import Darwin
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

        XCTAssertNil(
            NetworkRouteTable.defaultGateway(in: NetworkRouteTable.parse(raw))
        )
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

    /// The header still claims the original length, so a truncated message must
    /// be dropped whole rather than reported with a half-read address.
    func testTruncatedPayloadYieldsNothing() {
        let raw = payload(
            flags: rtfUp | rtfGateway,
            components: [(rtaDestination, "0.0.0.0"), (rtaGateway, "192.168.43.254")]
        )

        XCTAssertTrue(NetworkRouteTable.parse(Array(raw.prefix(raw.count - 4))).isEmpty)
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

    private let rtfUp: Int32 = 0x1
    private let rtfGateway: Int32 = 0x2
    private let rtfLLInfo: Int32 = 0x400

    private let rtaDestination: Int32 = 0x1
    private let rtaGateway: Int32 = 0x2

    /// One `rt_msghdr` followed by its sockaddr components, in bit order.
    private func payload(flags: Int32, components: [(Int32, String)]) -> [UInt8] {
        var bits: Int32 = 0
        for (bit, _) in components { bits |= bit }

        var header = rt_msghdr()
        header.rtm_version = 5      // RTM_VERSION
        header.rtm_type = 4         // RTM_GET
        header.rtm_flags = flags
        header.rtm_addrs = bits

        var bytes = withUnsafeBytes(of: header) { Array($0) }
        for (_, text) in components {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            _ = inet_pton(AF_INET, text, &address.sin_addr)
            bytes += withUnsafeBytes(of: address) { Array($0) }
        }

        // `rtm_msglen` is the first field and is only known once every
        // component has been appended.
        let length = UInt16(bytes.count)
        withUnsafeBytes(of: length) { raw in
            for (index, byte) in raw.enumerated() {
                bytes[index] = byte
            }
        }
        return bytes
    }
}
