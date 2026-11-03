import ComposableArchitecture
import ConcurrencyExtras
import Foundation
import XCTest
@testable import iADB

@MainActor
final class DiscoveryTests: XCTestCase {
    func testCandidateHostsStartsAtTheGatewayAndSkipsThePhone() {
        let hosts = LocalNetworkProbe.candidateHosts(address: "192.168.43.7")

        XCTAssertEqual(hosts.first, "192.168.43.1")
        XCTAssertEqual(hosts.last, "192.168.43.254")
        XCTAssertEqual(hosts.count, 253)
        XCTAssertFalse(hosts.contains("192.168.43.7"))
        XCTAssertFalse(hosts.contains("192.168.43.0"))
        XCTAssertFalse(hosts.contains("192.168.43.255"))
    }

    func testCandidateHostsRejectsMalformedAddresses() {
        XCTAssertTrue(LocalNetworkProbe.candidateHosts(address: "").isEmpty)
        XCTAssertTrue(LocalNetworkProbe.candidateHosts(address: "192.168.43").isEmpty)
        XCTAssertTrue(LocalNetworkProbe.candidateHosts(address: "192.168.43.256").isEmpty)
        XCTAssertTrue(LocalNetworkProbe.candidateHosts(address: "192.168.43.7", limit: 0).isEmpty)
    }

    func testCandidateHostsHonoursTheLimit() {
        let hosts = LocalNetworkProbe.candidateHosts(address: "10.0.0.5", limit: 10)
        XCTAssertEqual(hosts.count, 10)
        XCTAssertEqual(hosts.first, "10.0.0.1")
        XCTAssertFalse(hosts.contains("10.0.0.5"))
    }

    func testSubnetComparison() {
        XCTAssertTrue(LocalNetworkProbe.isSameSubnet("192.168.43.7", "192.168.43.1"))
        XCTAssertFalse(LocalNetworkProbe.isSameSubnet("192.168.43.7", "10.0.0.1"))
        XCTAssertFalse(LocalNetworkProbe.isSameSubnet("192.168.43", "192.168.43.1"))
    }

    func testProbeTargetsPreferRememberedEndpoints() {
        let remembered = DiscoveryEndpoint(host: "192.168.43.1", port: 37_123)
        let targets = LocalNetworkProbe.probeTargets(
            address: "192.168.43.7",
            gateway: nil,
            neighbours: [],
            known: [remembered],
            limit: 5
        )

        XCTAssertEqual(targets.first, remembered)
        XCTAssertEqual(targets.count, 5)
        // The same host on the default port is a different target.
        XCTAssertTrue(targets.contains(DiscoveryEndpoint(host: "192.168.43.1", port: 5_555)))
    }

    func testProbeTargetsNeverDuplicateAPort() {
        let remembered = DiscoveryEndpoint(host: "192.168.43.1", port: 5_555)
        let targets = LocalNetworkProbe.probeTargets(
            address: "192.168.43.7",
            gateway: nil,
            neighbours: [],
            known: [remembered],
            limit: 4
        )

        XCTAssertEqual(targets.filter { $0 == remembered }.count, 1)
        XCTAssertEqual(targets.count, 4)
    }

    /// A unit that hosts the hotspot is the gateway, and DHCP does not promise
    /// it `.1`. Reading it is the whole point of `NetworkRouteTable`.
    func testProbeTargetsProbeTheRealGateway() {
        let targets = LocalNetworkProbe.probeTargets(
            address: "192.168.43.7",
            gateway: "192.168.43.254",
            neighbours: [],
            known: [],
            limit: 4
        )

        XCTAssertEqual(targets.first, DiscoveryEndpoint(host: "192.168.43.254", port: 5_555))
    }

    /// A phone hosted hotspot makes the phone itself the gateway. Probing it
    /// can never reach adbd, so it must not consume a slot.
    func testProbeTargetsSkipThePhoneAsGateway() {
        let targets = LocalNetworkProbe.probeTargets(
            address: "192.168.43.1",
            gateway: "192.168.43.1",
            neighbours: ["192.168.43.155"],
            known: [],
            limit: 4
        )

        XCTAssertFalse(targets.contains(DiscoveryEndpoint(host: "192.168.43.1", port: 5_555)))
        XCTAssertEqual(targets.first, DiscoveryEndpoint(host: "192.168.43.155", port: 5_555))
    }

    func testProbeTargetsPreferNeighboursOverTheBlindWalk() {
        let targets = LocalNetworkProbe.probeTargets(
            address: "192.168.43.1",
            gateway: "192.168.43.1",
            neighbours: ["192.168.43.155"],
            known: [],
            limit: 3
        )

        XCTAssertEqual(
            targets.map(\.host),
            ["192.168.43.155", "192.168.43.2", "192.168.43.3"]
        )
    }

    /// With a VPN up the default route leaves the subnet entirely. Dialling it
    /// would cost a timeout on every scan and could never reach adbd.
    func testProbeTargetsIgnoreAnOffSubnetGateway() {
        let targets = LocalNetworkProbe.probeTargets(
            address: "192.168.43.7",
            gateway: "10.8.0.1",
            neighbours: [],
            known: [],
            limit: 2
        )

        XCTAssertEqual(targets.map(\.host), ["192.168.43.1", "192.168.43.2"])
    }

    /// Values depend on the machine, so only the shape is asserted. What must
    /// hold everywhere is that neither call traps: both run on every probe, and
    /// a broken parser would crash the app rather than fail a test.
    // Reading the live routing table is deliberately not covered here:
    // `sysctl(CTL_NET, PF_ROUTE, ...)` can block the calling thread on the
    // simulator, which hangs the entire test run rather than failing it. The
    // byte-level behaviour is covered by RoutingTableTests against fixtures.

    func testProbeSweepCoversTheWholeSubnetOnTheAdbPort() {
        let sweep = LocalNetworkProbe.probeSweep(address: "192.168.43.7")

        XCTAssertEqual(sweep.count, 253)
        XCTAssertTrue(sweep.allSatisfy { $0.port == LocalNetworkProbe.adbPort })
        XCTAssertTrue(sweep.contains(DiscoveryEndpoint(host: "192.168.43.155", port: 5_555)))
        XCTAssertFalse(sweep.contains(DiscoveryEndpoint(host: "192.168.43.7", port: 5_555)))
    }

    func testProbeSweepRejectsMalformedAddresses() {
        XCTAssertTrue(LocalNetworkProbe.probeSweep(address: "").isEmpty)
        XCTAssertTrue(LocalNetworkProbe.probeSweep(address: "192.168.43").isEmpty)
    }

    func testSuccessfulConnectRemembersTheEndpoint() async {
        let remembered = LockIsolated<[DiscoveryEndpoint]>([])
        let store = TestStore(initialState: ConnectionFeature.State()) { ConnectionFeature() }
            withDependencies: {
                $0.deviceDiscoveryClient.rememberEndpoint = { endpoint in
                    remembered.withValue { $0.append(endpoint) }
                }
                $0.deviceDiscoveryClient.rememberName = { _, _ in }
                $0.adbClient.getDeviceProperty = { _ in "XR-75A80L" }
            }
        let device = DiscoveredDevice(
            id: "adb-desk",
            name: "desk",
            host: "192.168.43.1",
            port: 37_123,
            isPaired: true,
            pairingPort: nil
        )

        await store.send(.connectionFinished(device, .success("banner"))) {
            $0.connectedDevice = device
            $0.connectionState = .connected
        }
        // The reducer also asks the device for its model.
        await store.receive(\.deviceNameRemembered)

        XCTAssertEqual(remembered.value, [DiscoveryEndpoint(host: "192.168.43.1", port: 37_123)])
    }

    func testConnectionReportsTheDeviceModelForLaterScanning() async {
        let named = LockIsolated<(String, String)?>(nil)
        let store = TestStore(initialState: ConnectionFeature.State()) { ConnectionFeature() }
            withDependencies: {
                $0.deviceDiscoveryClient.rememberEndpoint = { _ in }
                $0.deviceDiscoveryClient.rememberName = { host, name in
                    named.withValue { $0 = (host, name) }
                }
                $0.adbClient.getDeviceProperty = { _ in "XR-75A80L" }
            }
        let device = DiscoveredDevice(
            id: "direct:192.168.43.155",
            name: "ADB 192.168.43.155",
            host: "192.168.43.155",
            port: 5_555,
            isPaired: false,
            pairingPort: nil,
            source: .probe
        )

        await store.send(.connectionFinished(device, .success("banner"))) {
            $0.connectedDevice = device
            $0.connectionState = .connected
        }
        await store.receive(\.deviceNameRemembered)

        XCTAssertEqual(named.value?.0, "192.168.43.155")
        XCTAssertEqual(named.value?.1, "XR-75A80L")
    }

    func testReportedModelRenamesAProbeRowButNotAnSSDPRow() async {
        var state = ConnectionFeature.State()
        state.discoveredDevices = [
            DiscoveredDevice(
                id: "direct:192.168.43.155",
                name: "ADB 192.168.43.155",
                host: "192.168.43.155",
                port: 5_555,
                isPaired: false,
                pairingPort: nil,
                source: .probe
            ),
            DiscoveredDevice(
                id: "direct:192.168.43.1",
                name: "BRAVIA 4K",
                host: "192.168.43.1",
                port: 5_555,
                isPaired: false,
                pairingPort: nil,
                source: .ssdp
            ),
        ]
        let store = TestStore(initialState: state) { ConnectionFeature() }

        await store.send(.deviceNameRemembered(host: "192.168.43.155", name: "XR-75A80L")) {
            $0.discoveredDevices[0].name = "XR-75A80L"
        }
        // SSDP already supplied a better name; this row must not change.
        await store.send(.deviceNameRemembered(host: "192.168.43.1", name: "KD-55X85J"))
    }

    func testWaitingKeepsScanningWithoutAnError() async {
        let store = TestStore(initialState: ConnectionFeature.State()) { ConnectionFeature() }

        await store.send(.discoveryEvent(.waiting("Network changed. Scanning again."))) {
            $0.isScanning = true
            $0.discoveryHint = "Network changed. Scanning again."
        }
    }

    func testReadyClearsTheWaitingHint() async {
        var state = ConnectionFeature.State()
        state.isScanning = true
        state.discoveryHint = "Network changed. Scanning again."
        let store = TestStore(initialState: state) { ConnectionFeature() }

        await store.send(.discoveryEvent(.ready)) {
            $0.isScanning = false
            $0.discoveryHint = nil
        }
    }
}
