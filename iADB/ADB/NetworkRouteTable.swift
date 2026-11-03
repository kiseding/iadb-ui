import Darwin
import Foundation

/// Reads the kernel routing table through `sysctl`.
///
/// Two facts live here and neither is reachable from `getifaddrs`:
///
/// - A hotspot host is not obliged to claim `.1`. DHCP hands out whatever the
///   host was configured with, so the gateway has to be read, not guessed.
/// - The ARP cache lists every neighbour the phone has actually exchanged
///   frames with. On a hotspot that is usually the only other device, which
///   makes it a far better candidate list than sweeping 253 addresses.
///
/// Both are plain BSD interfaces and need no entitlement, unlike multicast.
enum NetworkRouteTable {
    /// IPv4 default gateway currently in use, e.g. `192.168.43.1`.
    ///
    /// A head unit that hosts the hotspot *is* this address, so probing it is
    /// the single cheapest discovery step available — one TCP SYN, no scan.
    static func defaultGatewayIPv4() -> String? {
        defaultGateway(in: messages([netControl, routeFamily, 0, inetFamily, dumpRequest, 0]))
    }

    /// Picks the default route out of an already parsed table.
    static func defaultGateway(in messages: [RoutingMessage]) -> String? {
        for entry in messages {
            guard entry.flags & rtfUp != 0, entry.flags & rtfGateway != 0 else { continue }

            // A default route matches every destination. The kernel writes it
            // either without an `RTA_DST` component at all, or with `0.0.0.0`.
            let destination = entry.addresses[rtaDestination]
            guard destination == nil || destination == "0.0.0.0" else { continue }

            guard let gateway = entry.addresses[rtaGateway] else { continue }
            return gateway
        }
        return nil
    }

    /// IPv4 neighbours from the ARP cache, most recently used first.
    ///
    /// When the *phone* hosts the hotspot the head unit is a client, so it can
    /// sit anywhere in the DHCP pool — one was observed on `.155` — and it will
    /// never be the gateway. It is however a neighbour, provided the two have
    /// exchanged a frame recently.
    static func neighbourIPv4Addresses() -> [String] {
        neighbours(
            in: messages([netControl, routeFamily, 0, inetFamily, flagRequest, rtfLLInfo])
        )
    }

    /// Collects the destinations of an already parsed ARP table.
    static func neighbours(in messages: [RoutingMessage]) -> [String] {
        var hosts: [String] = []
        var seen: Set<String> = []
        for entry in messages where entry.flags & rtfLLInfo != 0 {
            // `RTA_DST` carries the neighbour; `RTA_GATEWAY` carries its link
            // layer address and is not an IPv4 string we can use.
            guard let host = entry.addresses[rtaDestination] else { continue }
            guard host != "0.0.0.0", host != "255.255.255.255" else { continue }
            guard seen.insert(host).inserted else { continue }
            hosts.append(host)
        }
        return hosts
    }

    // MARK: - Parsing

    struct RoutingMessage: Equatable {
        let flags: Int32
        /// Rendered address text keyed by its `RTA_*` bit.
        let addresses: [Int32: String]
    }

    /// Runs `sysctl` twice — once for the size, once for the payload.
    private static func messages(_ mib: [Int32]) -> [RoutingMessage] {
        var mib = mib
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
            return []
        }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0, size > 0 else {
            return []
        }
        return parse(Array(buffer.prefix(size)))
    }

    /// Splits a raw routing payload into messages.
    ///
    /// Kept separate from the `sysctl` call so it can be exercised against a
    /// synthetic payload. This is byte arithmetic over kernel output, which is
    /// exactly the kind of code that is wrong in ways only a fixture catches —
    /// a wrong stride silently yields plausible addresses from the wrong offset.
    static func parse(_ buffer: [UInt8]) -> [RoutingMessage] {
        let headerSize = MemoryLayout<rt_msghdr>.size
        var result: [RoutingMessage] = []
        var offset = 0

        while offset + headerSize <= buffer.count {
            var header = rt_msghdr()
            withUnsafeMutableBytes(of: &header) { destination in
                buffer.withUnsafeBytes { source in
                    destination.copyBytes(
                        from: UnsafeRawBufferPointer(
                            rebasing: source[offset ..< offset + headerSize]
                        )
                    )
                }
            }

            let length = Int(header.rtm_msglen)
            guard length >= headerSize, offset + length <= buffer.count else { break }
            let end = offset + length

            var addresses: [Int32: String] = [:]
            var cursor = offset + headerSize
            var bit: Int32 = 1

            while bit <= rtaBroadcast {
                defer { bit <<= 1 }
                guard header.rtm_addrs & bit != 0 else { continue }
                guard cursor + 2 <= end else { break }

                // `sa_len` is the whole record: header plus payload, already
                // padded by the kernel to a four byte boundary.
                let recordLength = Int(buffer[cursor])
                guard recordLength >= 2, cursor + recordLength <= end else { break }

                let family = Int32(buffer[cursor + 1])
                if family == inetFamily, recordLength >= MemoryLayout<sockaddr_in>.size {
                    if let text = ipv4Text(buffer: buffer, at: cursor) {
                        addresses[bit] = text
                    }
                }
                cursor += (recordLength + 3) & ~3
            }

            result.append(RoutingMessage(flags: header.rtm_flags, addresses: addresses))
            offset = end
        }
        return result
    }

    private static func ipv4Text(buffer: [UInt8], at offset: Int) -> String? {
        var socketAddress = sockaddr_in()
        let needed = MemoryLayout<sockaddr_in>.size
        guard offset + needed <= buffer.count else { return nil }

        withUnsafeMutableBytes(of: &socketAddress) { destination in
            buffer.withUnsafeBytes { source in
                destination.copyBytes(
                    from: UnsafeRawBufferPointer(rebasing: source[offset ..< offset + needed])
                )
            }
        }

        var address = socketAddress.sin_addr
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
        }
        return String(cString: text)
    }

    // MARK: - Constants
    //
    // Spelled out rather than imported: `net/route.h` exposes most of these as
    // macros, which Swift does not surface to every target configuration.

    private static let netControl: Int32 = 4        // CTL_NET
    private static let routeFamily: Int32 = 17      // PF_ROUTE
    private static let inetFamily: Int32 = 2        // AF_INET
    private static let dumpRequest: Int32 = 0       // NET_RT_DUMP
    private static let flagRequest: Int32 = 1       // NET_RT_FLAGS

    private static let rtfUp: Int32 = 0x1           // RTF_UP
    private static let rtfGateway: Int32 = 0x2      // RTF_GATEWAY
    private static let rtfLLInfo: Int32 = 0x400     // RTF_LLINFO

    private static let rtaDestination: Int32 = 0x1  // RTA_DST
    private static let rtaGateway: Int32 = 0x2      // RTA_GATEWAY
    private static let rtaBroadcast: Int32 = 0x80   // RTA_BRD
}
