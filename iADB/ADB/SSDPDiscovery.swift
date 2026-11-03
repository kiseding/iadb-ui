import Darwin
import Foundation

/// A device that answered an SSDP `M-SEARCH`.
///
/// SSDP is a request/response protocol: the host multicasts (or unicasts) a
/// search, and every UPnP device answers directly to the sender. That reply is
/// unicast, which is why this survives the multicast filtering that breaks
/// mDNS on phone hotspots and car head-unit access points.
struct SSDPService: Equatable, Sendable {
    var host: String
    var searchTarget: String
    var usn: String
    var server: String?
    /// `LOCATION` header: the device description document.
    var location: URL?
    /// `<friendlyName>` from the description, when it could be fetched.
    var friendlyName: String?
    /// `<modelName>` from the description.
    var modelName: String?

    /// Best available human name, or `nil` when the device published none.
    var displayName: String? {
        if let friendlyName, !friendlyName.isEmpty { return friendlyName }
        if let modelName, !modelName.isEmpty { return modelName }
        return nil
    }
}

/// One parsed SSDP response.
struct SSDPResponse: Equatable {
    var statusLine: String
    /// Header names are lowercased; values keep their original casing.
    var headers: [String: String]

    /// Parses an SSDP datagram. Returns `nil` for anything that is not an
    /// HTTP-style response, which filters out stray multicast traffic.
    static func parse(_ data: Data) -> SSDPResponse? {
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else { return nil }

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard let statusLine = lines.first, statusLine.hasPrefix("HTTP/") else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            headers[name] = value
        }
        return SSDPResponse(statusLine: statusLine, headers: headers)
    }
}

/// Discovery over SSDP/UPnP.
///
/// Apple gates IP multicast behind the `com.apple.developer.networking.multicast`
/// entitlement, which has to be requested from Apple and cannot be self-signed
/// onto a sideloaded build. So every search goes out twice: once to the SSDP
/// multicast group, which covers the whole subnet in a single datagram, and once
/// as a unicast copy to each candidate host, which needs no entitlement and is
/// what actually works on a device without it.
enum SSDPDiscovery {
    static let multicastAddress = "239.255.255.250"
    static let multicastPort: UInt16 = 1900

    /// Most specific first. DIAL is what Android TV runs; `ssdp:all` catches
    /// media renderers and anything else that answers.
    static let searchTargets = [
        "urn:dial-multiscreen-org:service:dial:1",
        "urn:schemas-upnp-org:device:MediaRenderer:1",
        "ssdp:all",
    ]

    /// Multicast for every search target, plus one unicast copy per host.
    ///
    /// The unicast leg is what makes this work without the multicast
    /// entitlement: a single repeated datagram keeps the burst inside the
    /// socket send buffer, so it repeats the broadest search rather than the
    /// narrowest.
    static func search(hosts: [String], timeout: TimeInterval) async -> [SSDPService] {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: performSearch(hosts: hosts, timeout: timeout))
            }
        }
    }

    /// Fetches the `LOCATION` document so the device can be shown by name
    /// before connecting. Best effort: a failure leaves the name empty.
    static func describe(_ service: SSDPService, timeout: TimeInterval = 2) async -> SSDPService {
        guard let location = service.location else { return service }

        var request = URLRequest(url: location)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let xml = String(data: data, encoding: .utf8) else {
            return service
        }

        var described = service
        described.friendlyName = tagValue("friendlyName", in: xml)
        described.modelName = tagValue("modelName", in: xml)
        return described
    }

    /// Describes every responder concurrently.
    static func describeAll(_ services: [SSDPService], timeout: TimeInterval = 2) async -> [SSDPService] {
        await withTaskGroup(of: SSDPService.self) { group in
            for service in services {
                group.addTask { await describe(service, timeout: timeout) }
            }
            var result: [SSDPService] = []
            for await service in group {
                result.append(service)
            }
            return result
        }
    }

    /// Value of the first `<tag>…</tag>` in `xml`, trimmed.
    ///
    /// The description documents are small and flat, so a scan beats pulling in
    /// an XML parser; it also tolerates the malformed prologs some cheap
    /// firmware emits, which a strict parser rejects.
    static func tagValue(_ tag: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(tag)>"),
              let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex)
        else { return nil }
        let value = String(xml[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// The `M-SEARCH` datagram. `MX` is the most the device may wait before
    /// answering; the whole search is bounded by it.
    static func mSearch(target: String, mx: Int = 2) -> String {
        [
            "M-SEARCH * HTTP/1.1",
            "HOST: \(multicastAddress):\(multicastPort)",
            "MAN: \"ssdp:discover\"",
            "MX: \(mx)",
            "ST: \(target)",
            "",
            "",
        ].joined(separator: "\r\n")
    }

    // MARK: - Socket work

    private static let queue = DispatchQueue(label: "com.iadb.ssdp", qos: .userInitiated)

    private static func performSearch(hosts: [String], timeout: TimeInterval) -> [SSDPService] {
        guard let descriptor = openSocket(localAddress: LocalNetworkProbe.wifiIPv4Address()) else {
            return []
        }
        defer { _ = close(descriptor) }

        // Multicast goes out once per target. The unicast leg repeats only
        // `ssdp:all`, which every UPnP device answers — including the DIAL
        // servers that also match the narrower searches.
        for target in searchTargets {
            send(mSearch(target: target), to: multicastAddress, descriptor: descriptor)
        }
        let unicast = mSearch(target: "ssdp:all")
        for host in hosts {
            send(unicast, to: host, descriptor: descriptor)
        }

        var byHost: [String: SSDPService] = [:]
        let deadline = Date().addingTimeInterval(timeout)
        var consecutiveFailures = 0

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }

            var pending = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pending, 1, Int32(remaining * 1000))
            if ready == 0 { break }
            if ready < 0 {
                // A signal interrupted the wait; the deadline still applies.
                if errno == EINTR { continue }
                break
            }

            guard let received = receive(descriptor: descriptor) else {
                // A readable socket can still hand back nothing. Backing off
                // after a few of those keeps a level-triggered condition from
                // turning into a spin, without stalling a real reply.
                consecutiveFailures += 1
                if consecutiveFailures > 8 {
                    usleep(5_000)
                    consecutiveFailures = 0
                }
                continue
            }
            consecutiveFailures = 0
            let (data, host) = received
            guard let response = SSDPResponse.parse(data) else { continue }
            guard let location = response.headers["location"],
                  let url = URL(string: location) else { continue }

            let searchTarget = response.headers["st"] ?? ""
            let service = SSDPService(
                host: host,
                searchTarget: searchTarget,
                usn: response.headers["usn"] ?? "",
                server: response.headers["server"],
                location: url
            )

            // A device answers once per search target. Prefer the DIAL record,
            // which is the one that carries a usable description.
            if let existing = byHost[host],
               existing.searchTarget == searchTargets[0] {
                continue
            }
            byHost[host] = service
        }

        return byHost.values.sorted { $0.host < $1.host }
    }

    private static func openSocket(localAddress: String?) -> Int32? {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return nil }

        var yes: Int32 = 1
        _ = setsockopt(
            descriptor, SOL_SOCKET, SO_REUSEADDR,
            &yes, socklen_t(MemoryLayout<Int32>.size)
        )

        // A /24 search is 253 datagrams fired back to back. The default UDP
        // send buffer is about 9 KB, so without this most of them are dropped
        // by `sendto` and the far half of the subnet never hears the search.
        var sendBuffer: Int32 = 256 * 1024
        _ = setsockopt(
            descriptor, SOL_SOCKET, SO_SNDBUF,
            &sendBuffer, socklen_t(MemoryLayout<Int32>.size)
        )

        // Bind explicitly. Devices answer to the source port of the search, so
        // the socket must own a port before the first datagram leaves — an
        // unbound socket only gets one as a side effect of a successful send,
        // and a multicast send can fail on its own without binding.
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr.s_addr = 0
        let bound = withUnsafePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            _ = close(descriptor)
            return nil
        }

        // Pin multicast egress to Wi-Fi. iOS routes multicast out of the
        // primary interface, which is cellular whenever the hotspot has no
        // internet — exactly the head-unit case, where the search would
        // otherwise leave through the wrong radio.
        if let localAddress {
            var egress = in_addr()
            if inet_pton(AF_INET, localAddress, &egress) == 1 {
                _ = setsockopt(
                    descriptor, IPPROTO_IP, IP_MULTICAST_IF,
                    &egress, socklen_t(MemoryLayout<in_addr>.size)
                )
            }
        }

        // Two hops is the SSDP convention and keeps the search inside the
        // local segment.
        var ttl: UInt8 = 2
        _ = setsockopt(
            descriptor, IPPROTO_IP, IP_MULTICAST_TTL,
            &ttl, socklen_t(MemoryLayout<UInt8>.size)
        )

        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            _ = close(descriptor)
            return nil
        }
        return descriptor
    }

    private static func send(_ payload: String, to host: String, descriptor: Int32) {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = multicastPort.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return }

        let bytes = Array(payload.utf8)
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bytes.withUnsafeBufferPointer { buffer in
                    sendto(
                        descriptor,
                        buffer.baseAddress,
                        buffer.count,
                        0,
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
    }

    private static func receive(descriptor: Int32) -> (Data, String)? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)

        let count = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                recvfrom(descriptor, &buffer, buffer.count, 0, socketAddress, &length)
            }
        }
        guard count > 0 else { return nil }

        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var raw = address.sin_addr
        guard inet_ntop(AF_INET, &raw, &text, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
        }
        return (Data(buffer[0..<count]), String(cString: text))
    }
}
