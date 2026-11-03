import Darwin
import Foundation
import Network

/// Finds ADB endpoints without Bonjour.
///
/// Android tethering drops multicast traffic in many builds, and a car head
/// unit hosting a hotspot is one of the worst offenders. The host still accepts
/// TCP, so a direct probe recovers the device when mDNS cannot. Which address
/// to aim at depends on who runs the hotspot, and `NetworkRouteTable` supplies
/// both answers: the gateway when the unit hosts it, the ARP neighbours when
/// the phone does.
enum LocalNetworkProbe {
    /// IPv4 address of the Wi-Fi interface, e.g. `192.168.43.7`.
    static func wifiIPv4Address() -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(addresses) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(bitPattern: pointer.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            // Wi-Fi is en0 on iOS, including when the phone joined a hotspot.
            guard let name = pointer.pointee.ifa_name,
                  String(cString: name) == "en0" else { continue }
            guard let address = pointer.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }

            var socketAddress = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee
            }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(
                AF_INET,
                &socketAddress.sin_addr,
                &text,
                socklen_t(INET_ADDRSTRLEN)
            ) != nil else { continue }
            return String(cString: text)
        }
        return nil
    }

    /// Usable hosts in the /24 around `address`, lowest first.
    ///
    /// Tethering always hands out a /24 (or a smaller slice inside one), so the
    /// list stays bounded at 254 entries. This is the fallback for when neither
    /// the gateway nor ARP produced a candidate; it deliberately does not try to
    /// put the gateway first, because that address is read for real elsewhere
    /// and this ordering would otherwise bury it behind a wrong guess.
    /// The phone's own address is skipped because adbd never listens there.
    static func candidateHosts(address: String, limit: Int = 254) -> [String] {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4, limit > 0 else { return [] }
        let selfHost = Int(octets[3])
        let prefix = "\(octets[0]).\(octets[1]).\(octets[2])"

        var hosts: [String] = []
        hosts.reserveCapacity(254)
        for host in 1...254 {
            guard host != selfHost else { continue }
            hosts.append("\(prefix).\(host)")
            if hosts.count == limit { break }
        }
        return hosts
    }

    /// The port `adb tcpip` uses, and what head units with network debugging
    /// enabled listen on by default.
    static let adbPort: UInt16 = 5555

    /// Targets ordered by how likely each one is to be the head unit.
    ///
    /// The two hotspot topologies need different answers and only one of them
    /// has a shortcut:
    ///
    /// - **Unit hosts the hotspot.** The unit *is* the gateway, so one SYN to
    ///   `RTA_GATEWAY` settles it. Nothing else is needed.
    /// - **Phone hosts the hotspot.** The unit is a client with an address from
    ///   the pool, so it is not the gateway and may sit anywhere — one was
    ///   observed on `.155`. ARP is the shortcut here, and it only helps if the
    ///   two talked recently.
    ///
    /// Both shortcuts are tried before the blind neighbourhood walk, which is
    /// what makes the first pass feel instant.
    static func probeTargets(
        address: String,
        gateway: String?,
        neighbours: [String],
        known: [DiscoveryEndpoint],
        limit: Int = 16
    ) -> [DiscoveryEndpoint] {
        guard limit > 0 else { return [] }
        var targets: [DiscoveryEndpoint] = []
        var seen: Set<DiscoveryEndpoint> = []

        // Skips the phone itself: adbd never listens there, and on a phone
        // hosted hotspot the gateway *is* the phone.
        func append(_ host: String, port: UInt16 = adbPort) {
            guard targets.count < limit, host != address else { return }
            let endpoint = DiscoveryEndpoint(host: host, port: port)
            guard seen.insert(endpoint).inserted else { return }
            targets.append(endpoint)
        }

        // A remembered endpoint is the only way back to a device listening on a
        // random wireless-debugging port. It keeps the first slot, but the
        // gateway follows immediately because it survives a subnet change and
        // a remembered address does not.
        for endpoint in known {
            guard targets.count < limit else { break }
            guard seen.insert(endpoint).inserted else { continue }
            targets.append(endpoint)
        }
        // Same-subnet only: with a VPN up, the default route points at the
        // tunnel and dialling it would be a wasted timeout on every scan.
        if let gateway, isSameSubnet(address, gateway) {
            append(gateway)
        }
        for host in neighbours {
            append(host)
        }
        for host in candidateHosts(address: address, limit: limit) {
            append(host)
        }
        return targets
    }

    /// Every usable host in the /24, on the ADB port.
    ///
    /// Used as the last resort when neither Bonjour, SSDP, nor the gateway
    /// neighbourhood found anything. A head unit is not required to take the
    /// first address its own DHCP server hands out — one was observed on
    /// `.155` — so the cheap pass alone is not enough.
    static func probeSweep(address: String) -> [DiscoveryEndpoint] {
        candidateHosts(address: address, limit: 254).map {
            DiscoveryEndpoint(host: $0, port: adbPort)
        }
    }

    /// True when both addresses are valid IPv4 and sit in the same /24.
    ///
    /// Both sides must be complete addresses: a three-part string would
    /// otherwise share its first three components with anything underneath it
    /// and be reported as a match.
    static func isSameSubnet(_ address: String, _ other: String) -> Bool {
        let left = address.split(separator: ".")
        let right = other.split(separator: ".")
        guard left.count == 4, right.count == 4,
              left.allSatisfy({ UInt8($0) != nil }),
              right.allSatisfy({ UInt8($0) != nil })
        else { return false }
        return left.prefix(3).elementsEqual(right.prefix(3))
    }

    /// Opens a TCP connection and reports whether the port accepted it.
    static func isReachable(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: endpointPort,
            using: .tcp
        )

        return await withCheckedContinuation { continuation in
            // `stateUpdateHandler` and the timeout fire off this call stack on
            // different queues, so the first outcome wins. The gate owns the
            // flag instead of a captured local variable, which keeps it
            // `Sendable` and keeps `NSLock` out of an async context.
            let gate = ProbeGate(connection: connection, continuation: continuation)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.settle(true)
                case .failed, .cancelled:
                    gate.settle(false)
                default:
                    // `.waiting` means the route is still being resolved; keep
                    // waiting until the timeout decides.
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                gate.settle(false)
            }
        }
    }

    private static let queue = DispatchQueue(label: "com.iadb.probe", attributes: .concurrent)
}

/// Resolves one reachability probe exactly once.
private final class ProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private let connection: NWConnection
    private let continuation: CheckedContinuation<Bool, Never>

    init(connection: NWConnection, continuation: CheckedContinuation<Bool, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func settle(_ value: Bool) {
        lock.lock()
        let previous = settled
        settled = true
        lock.unlock()
        guard !previous else { return }
        connection.cancel()
        continuation.resume(returning: value)
    }
}
