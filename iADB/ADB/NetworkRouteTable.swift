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
///
/// Everything is parsed as raw bytes on purpose. `struct rt_msghdr` is declared
/// in `<net/route.h>`, but that header is not imported into Swift on iOS, and
/// its size is not a constant either — `struct rt_metrics` grew over the years,
/// so the header is 76 bytes on older releases and 92 or 96 on current ones.
/// Binding the C type would fail to compile; hard coding an offset would be
/// wrong on some OS versions and, worse, wrong silently. The header length is
/// therefore derived from the payload itself.
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

    /// Walks a raw routing payload and renders the addresses in each message.
    ///
    /// Exposed separately from the `sysctl` call so it can be driven by a
    /// synthetic payload. This is byte arithmetic over kernel output: a wrong
    /// stride does not crash, it returns plausible addresses read from the
    /// wrong offset, which is exactly the failure a fixture can catch.
    static func parse(_ buffer: [UInt8]) -> [RoutingMessage] {
        var result: [RoutingMessage] = []
        var offset = 0
        var knownHeaderSize: Int?

        while offset + fixedHeaderSize <= buffer.count {
            let length = Int(readUInt16(buffer, offset))
            guard length >= fixedHeaderSize, offset + length <= buffer.count else { break }
            let end = offset + length

            let flags = readInt32(buffer, offset + 8)
            let addrs = readInt32(buffer, offset + 12)

            // The header length is the same for every message in one payload,
            // so it is worked out once and then reused.
            guard let headerSize = knownHeaderSize
                ?? headerLength(buffer, offset: offset, length: length, addrs: addrs)
            else { break }
            knownHeaderSize = headerSize

            var addresses: [Int32: String] = [:]
            var cursor = offset + headerSize
            var bit: Int32 = 1
            var intact = true

            while bit <= rtaBroadcast {
                defer { bit <<= 1 }
                guard addrs & bit != 0 else { continue }
                guard cursor + 2 <= end else {
                    intact = false
                    break
                }

                // `sa_len` covers the whole record, already padded by the
                // kernel to a four byte boundary.
                let recordLength = Int(buffer[cursor])
                guard recordLength >= 2, cursor + recordLength <= end else {
                    intact = false
                    break
                }

                if Int32(buffer[cursor + 1]) == inetFamily,
                   recordLength == ipv4RecordSize,
                   let text = ipv4Text(buffer, at: cursor) {
                    addresses[bit] = text
                }
                cursor += (recordLength + 3) & ~3
            }

            if intact {
                result.append(RoutingMessage(flags: flags, addresses: addresses))
            }
            offset = end
        }
        return result
    }

    /// Derives `sizeof(struct rt_msghdr)` from the payload instead of assuming
    /// it.
    ///
    /// The address area has to end exactly on the message boundary for a
    /// candidate to be accepted, and every AF_INET record inside it has to be
    /// the standard 16 bytes. A wrong header size shifts the first `sa_len` into
    /// the middle of the metrics block, and the walk then almost never lands on
    /// the boundary by accident. When nothing fits the message is dropped, and
    /// discovery falls back to the neighbourhood sweep.
    private static func headerLength(
        _ buffer: [UInt8],
        offset: Int,
        length: Int,
        addrs: Int32
    ) -> Int? {
        guard addrs != 0 else { return nil }
        let end = offset + length

        // 76 through 96 covers every release still in service; the wider range
        // costs nothing and survives a metrics field being added later.
        for candidate in stride(from: 64, through: 128, by: 4) {
            guard offset + candidate <= end else { break }
            var cursor = offset + candidate
            var bit: Int32 = 1
            var fits = true

            while bit <= rtaBroadcast {
                defer { bit <<= 1 }
                guard addrs & bit != 0 else { continue }
                guard cursor + 2 <= end else {
                    fits = false
                    break
                }
                let recordLength = Int(buffer[cursor])
                guard recordLength >= 2, cursor + recordLength <= end else {
                    fits = false
                    break
                }
                if Int32(buffer[cursor + 1]) == inetFamily, recordLength != ipv4RecordSize {
                    fits = false
                    break
                }
                cursor += (recordLength + 3) & ~3
            }

            if fits, cursor == end {
                return candidate
            }
        }
        return nil
    }

    /// Reads the four address bytes of an AF_INET record.
    ///
    /// The layout is `sa_len` (1), `sa_family` (1), `sin_port` (2), `sin_addr`
    /// (4), so the address starts four bytes in.
    private static func ipv4Text(_ buffer: [UInt8], at offset: Int) -> String? {
        guard offset + ipv4RecordSize <= buffer.count else { return nil }
        let a = buffer[offset + 4]
        let b = buffer[offset + 5]
        let c = buffer[offset + 6]
        let d = buffer[offset + 7]
        return "\(a).\(b).\(c).\(d)"
    }

    // MARK: - Byte access
    //
    // Little endian throughout: every platform this runs on is arm64 or x86_64.

    private static func readUInt16(_ buffer: [UInt8], _ index: Int) -> UInt16 {
        guard index + 2 <= buffer.count else { return 0 }
        return UInt16(buffer[index]) | (UInt16(buffer[index + 1]) << 8)
    }

    private static func readInt32(_ buffer: [UInt8], _ index: Int) -> Int32 {
        guard index + 4 <= buffer.count else { return 0 }
        let raw = UInt32(buffer[index])
            | (UInt32(buffer[index + 1]) << 8)
            | (UInt32(buffer[index + 2]) << 16)
            | (UInt32(buffer[index + 3]) << 24)
        return Int32(bitPattern: raw)
    }

    // MARK: - Constants
    //
    // Spelled out rather than imported: `net/route.h` exposes these as macros,
    // and Swift does not surface them on every target configuration.

    /// The prefix of `rt_msghdr` that never moves: `rtm_msglen`, `rtm_version`,
    /// `rtm_type`, `rtm_index`, `rtm_flags`, `rtm_addrs`. Everything past
    /// `rtm_inits` depends on the metrics struct, so only this much is read at
    /// fixed offsets.
    private static let fixedHeaderSize = 16

    /// `sizeof(struct sockaddr_in)` on BSD.
    private static let ipv4RecordSize = 16

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
