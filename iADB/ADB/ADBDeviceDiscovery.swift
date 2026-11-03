import Foundation
import Network

final class ADBDeviceDiscovery: @unchecked Sendable {
    private enum BrowserKind: Hashable {
        case connect
        case pairing
    }

    private var connectBrowser: NWBrowser?
    private var pairingBrowser: NWBrowser?
    private var pathMonitor: NWPathMonitor?
    private var probeTask: Task<Void, Never>?
    private var gatewayTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var verifyTask: Task<Void, Never>?
    private var ssdpTask: Task<Void, Never>?
    private var sweepTask: Task<Void, Never>?

    private let queue = DispatchQueue(label: "com.iadb.discovery")
    private let resolveTimeout: TimeInterval = 5

    /// Резолвленные connect-сервисы: [host: DiscoveredDevice]
    private var connectDevices: [String: DiscoveredDevice] = [:]
    /// Hosts found by a direct TCP probe, with the channel that found them.
    private var directEndpoints: [String: ProbeRecord] = [:]
    /// Резолвленные pairing-сервисы: [host: port]
    private var pairingPorts: [String: UInt16] = [:]
    /// SSDP responders by host. Holds the marketing name of the device, which
    /// mDNS never provides.
    private var ssdpServices: [String: SSDPService] = [:]
    /// Endpoints that connected before, newest first.
    private var knownEndpoints: [DiscoveryEndpoint] = []

    private let stateLock = NSLock()

    /// `NSLock.lock()` is `noasync`, so calling it directly from an async
    /// method warns and breaks in the Swift 6 language mode. Every critical
    /// section here is fully synchronous and never awaits while holding the
    /// lock, which these helpers keep explicit.
    @inline(__always)
    private func acquireState() { stateLock.lock() }

    @inline(__always)
    private func releaseState() { stateLock.unlock() }
    private var activeContinuation: AsyncStream<DeviceDiscoveryEvent>.Continuation?
    private var activeRunID: UUID?
    private var readyBrowsers: Set<BrowserKind> = []
    private var connectResolutionGeneration = 0
    private var pairingResolutionGeneration = 0
    private var lastPathSignature: String?

    func start(context: DiscoveryContext) -> AsyncStream<DeviceDiscoveryEvent> {
        stop()

        let known = Self.mergedKnownEndpoints(context.knownEndpoints, Self.loadRememberedEndpoints())

        return AsyncStream { [weak self] continuation in
            guard let self else { return }
            let runID = UUID()
            let knownNames = Self.loadKnownNames()
            self.acquireState()
            self.activeRunID = runID
            self.knownEndpoints = known
            self.knownNames = knownNames
            self.activeContinuation = continuation
            self.connectDevices.removeAll()
            self.directEndpoints.removeAll()
            self.pairingPorts.removeAll()
            self.ssdpServices.removeAll()
            self.readyBrowsers.removeAll()
            self.connectResolutionGeneration = 0
            self.pairingResolutionGeneration = 0
            self.lastPathSignature = nil
            self.releaseState()

            self.startBrowsers(runID: runID)
            self.startPathMonitor(runID: runID)
            // SSDP answers faster than the browser list settles, and it is the
            // only channel that produces a human device name before connecting.
            self.scheduleGatewayProbe(runID: runID, delay: 0.15)
            self.scheduleSSDP(runID: runID, delay: 0.2)
            self.scheduleDirectProbe(runID: runID, delay: 0.8)
            self.scheduleSweep(runID: runID, delay: 6)

            continuation.onTermination = { [weak self] _ in
                self?.stop(runID: runID)
            }
        }
    }

    func stop() {
        stop(runID: nil)
    }

    private func stop(runID: UUID?) {
        acquireState()
        if let runID, activeRunID != runID {
            releaseState()
            return
        }
        activeRunID = nil
        activeContinuation = nil
        readyBrowsers.removeAll()
        let connectBrowser = connectBrowser
        let pairingBrowser = pairingBrowser
        let monitor = pathMonitor
        let probe = probeTask
        let gateway = gatewayTask
        let restart = restartTask
        let verify = verifyTask
        let ssdp = ssdpTask
        let sweep = sweepTask
        self.connectBrowser = nil
        self.pairingBrowser = nil
        pathMonitor = nil
        probeTask = nil
        gatewayTask = nil
        restartTask = nil
        verifyTask = nil
        ssdpTask = nil
        sweepTask = nil
        ssdpServices.removeAll()
        lastPathSignature = nil
        releaseState()

        connectBrowser?.cancel()
        pairingBrowser?.cancel()
        monitor?.cancel()
        probe?.cancel()
        gateway?.cancel()
        restart?.cancel()
        verify?.cancel()
        ssdp?.cancel()
        sweep?.cancel()
    }

    // MARK: - Known endpoints

    /// Stores an endpoint that just worked, so the next run probes it before
    /// falling back to the gateway guesswork. Written through to disk because
    /// the wireless-debugging port is random and would otherwise be lost on
    /// relaunch.
    func remember(endpoint: DiscoveryEndpoint) {
        let stored = Self.mergedKnownEndpoints([endpoint], Self.loadRememberedEndpoints())
        Self.saveRememberedEndpoints(stored)

        acquireState()
        knownEndpoints = stored
        releaseState()
    }

    private static let rememberedKey = "iadb.discovery.knownEndpoints"
    private static let rememberedLimit = 5
    private static let namesKey = "iadb.discovery.deviceNames"
    private static let namesLimit = 10

    /// Host → marketing name, learned the first time the device connected.
    private var knownNames: [String: String] = [:]

    /// Caches the name a device reported over ADB so the next scan can label it
    /// before connecting. Keyed by host because that is all a probe has.
    func remember(name: String, forHost host: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !host.isEmpty else { return }

        acquireState()
        knownNames[host] = trimmed
        let snapshot = knownNames
        releaseState()

        UserDefaults.standard.set(snapshot, forKey: Self.namesKey)
    }

    private static func loadKnownNames() -> [String: String] {
        guard let names = UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] else {
            return [:]
        }
        // Bounded so a long history of one-off networks cannot grow forever.
        return names.count > namesLimit
            ? Dictionary(uniqueKeysWithValues: Array(names).prefix(namesLimit).map { ($0.key, $0.value) })
            : names
    }

    private static func mergedKnownEndpoints(
        _ first: [DiscoveryEndpoint],
        _ second: [DiscoveryEndpoint]
    ) -> [DiscoveryEndpoint] {
        var result: [DiscoveryEndpoint] = []
        for endpoint in first + second {
            guard !result.contains(endpoint) else { continue }
            result.append(endpoint)
            if result.count == rememberedLimit { break }
        }
        return result
    }

    private static func loadRememberedEndpoints() -> [DiscoveryEndpoint] {
        guard let data = UserDefaults.standard.data(forKey: rememberedKey),
              let endpoints = try? JSONDecoder().decode([DiscoveryEndpoint].self, from: data) else {
            return []
        }
        return endpoints
    }

    private static func saveRememberedEndpoints(_ endpoints: [DiscoveryEndpoint]) {
        guard let data = try? JSONEncoder().encode(endpoints) else { return }
        UserDefaults.standard.set(data, forKey: rememberedKey)
    }

    // MARK: - Browsers

    private func startBrowsers(runID: UUID) {
        let params = NWParameters()
        params.allowLocalEndpointReuse = true
        params.acceptLocalOnly = true

        let connectBrowser = NWBrowser(
            for: .bonjour(type: "_adb-tls-connect._tcp", domain: "local."),
            using: params
        )
        connectBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.resolveServices(results: results, kind: .connect, runID: runID)
        }
        connectBrowser.stateUpdateHandler = { [weak self] state in
            self?.handleBrowserState(state, kind: .connect, runID: runID)
        }

        let pairingBrowser = NWBrowser(
            for: .bonjour(type: "_adb-tls-pairing._tcp", domain: "local."),
            using: params
        )
        pairingBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.resolveServices(results: results, kind: .pairing, runID: runID)
        }
        pairingBrowser.stateUpdateHandler = { [weak self] state in
            self?.handleBrowserState(state, kind: .pairing, runID: runID)
        }

        acquireState()
        guard activeRunID == runID else {
            releaseState()
            connectBrowser.cancel()
            pairingBrowser.cancel()
            return
        }
        self.connectBrowser = connectBrowser
        self.pairingBrowser = pairingBrowser
        releaseState()

        connectBrowser.start(queue: queue)
        pairingBrowser.start(queue: queue)
    }

    /// Rebuilds both browsers. Bonjour browsing does not reliably pick up
    /// services published before the phone joined a network, and a browser
    /// stuck in `.waiting` never recovers on its own, so a network change
    /// always starts from scratch.
    private func restartBrowsers(runID: UUID) {
        acquireState()
        guard activeRunID == runID else {
            releaseState()
            return
        }
        let oldConnect = connectBrowser
        let oldPairing = pairingBrowser
        connectBrowser = nil
        pairingBrowser = nil
        readyBrowsers.removeAll()
        connectDevices.removeAll()
        directEndpoints.removeAll()
        pairingPorts.removeAll()
        ssdpServices.removeAll()
        let devices = mergedDevicesLocked()
        let continuation = activeContinuation
        releaseState()

        oldConnect?.cancel()
        oldPairing?.cancel()
        continuation?.yield(.devices(devices))
        startBrowsers(runID: runID)
    }

    private func scheduleBrowserRestart(runID: UUID) {
        acquireState()
        restartTask?.cancel()
        releaseState()

        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.restartBrowsers(runID: runID)
        }

        acquireState()
        restartTask = task
        releaseState()
    }

    private func handleBrowserState(_ state: NWBrowser.State, kind: BrowserKind, runID: UUID) {
        switch state {
        case .ready:
            acquireState()
            guard activeRunID == runID else {
                releaseState()
                return
            }
            readyBrowsers.insert(kind)
            let allReady = readyBrowsers.count == 2
            let continuation = activeContinuation
            releaseState()
            if allReady {
                continuation?.yield(.ready)
            }

        case .waiting(let error):
            // Transient: the interface is down or still being configured. Keep
            // the browsers alive and tell the UI we are waiting rather than
            // painting a permanent error the user cannot act on.
            acquireState()
            guard activeRunID == runID else {
                releaseState()
                return
            }
            readyBrowsers.remove(kind)
            let nothingReady = readyBrowsers.isEmpty
            let continuation = activeContinuation
            releaseState()
            if nothingReady {
                continuation?.yield(.waiting(Self.waitingMessage(for: error)))
            }

        case .failed(let error):
            acquireState()
            guard activeRunID == runID else {
                releaseState()
                return
            }
            readyBrowsers.remove(kind)
            let continuation = activeContinuation
            releaseState()
            continuation?.yield(.failure(Self.discoveryMessage(for: error)))
            // A denied Local Network permission will not fix itself; anything
            // else can be retried after the network settles.
            if !Self.isPermissionDenied(error) {
                scheduleBrowserRestart(runID: runID)
            }

        case .setup, .cancelled:
            break

        @unknown default:
            yield(
                .failure(String(localized: "Device discovery stopped unexpectedly. Tap Rescan to try again.")),
                runID: runID
            )
        }
    }

    private static func isPermissionDenied(_ error: NWError) -> Bool {
        if case .posix(let code) = error, code == .EPERM { return true }
        return false
    }

    private static func discoveryMessage(for error: NWError) -> String {
        if isPermissionDenied(error) {
            return String(localized: "Local Network access is disabled. Allow it in Settings, then tap Rescan.")
        }
        return String(
            localized: "Wireless debugging discovery is unavailable: \(error.localizedDescription). Check Wi-Fi and Local Network access, then tap Rescan."
        )
    }

    private static func waitingMessage(for error: NWError) -> String {
        if isPermissionDenied(error) {
            return String(localized: "Local Network access is disabled. Allow it in Settings, then tap Rescan.")
        }
        return String(localized: "Waiting for the Wi-Fi network. Discovery resumes automatically.")
    }

    private func yield(_ event: DeviceDiscoveryEvent, runID: UUID) {
        acquireState()
        let continuation = activeRunID == runID ? activeContinuation : nil
        releaseState()
        continuation?.yield(event)
    }

    // MARK: - Path monitoring

    private func startPathMonitor(runID: UUID) {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path, runID: runID)
        }

        acquireState()
        guard activeRunID == runID else {
            releaseState()
            monitor.cancel()
            return
        }
        pathMonitor = monitor
        releaseState()
        monitor.start(queue: queue)
    }

    private func handlePathUpdate(_ path: NWPath, runID: UUID) {
        guard path.status == .satisfied else {
            acquireState()
            guard activeRunID == runID else {
                releaseState()
                return
            }
            lastPathSignature = "offline"
            let continuation = activeContinuation
            releaseState()
            continuation?.yield(.waiting(String(localized: "Waiting for the Wi-Fi network. Discovery resumes automatically.")))
            return
        }

        // Interface names do not change when the phone hops from home Wi-Fi to
        // a head unit hotspot — the address does. That is the signal that the
        // browsers have to start over.
        let signature = currentSignature()

        acquireState()
        guard activeRunID == runID else {
            releaseState()
            return
        }
        let previous = lastPathSignature
        lastPathSignature = signature
        releaseState()

        guard let previous else {
            // First satisfied update of this run: browsers are already fresh
            // and `start()` has the direct probe scheduled.
            schedulePathVerification(runID: runID)
            return
        }
        guard previous != signature else { return }

        restartBrowsers(runID: runID)
        yield(.waiting(String(localized: "Network changed. Scanning again.")), runID: runID)
        scheduleGatewayProbe(runID: runID, delay: 0.1)
        scheduleSSDP(runID: runID, delay: 0.2)
        scheduleDirectProbe(runID: runID, delay: 0.6)
        scheduleSweep(runID: runID, delay: 6)
        schedulePathVerification(runID: runID)
    }

    /// The address is often assigned a moment after the path turns ready, so a
    /// single update can miss the subnet switch. Re-check once it settles.
    private func schedulePathVerification(runID: UUID) {
        acquireState()
        verifyTask?.cancel()
        releaseState()

        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            let signature = self.currentSignature()
            self.acquireState()
            let changed = self.activeRunID == runID && self.lastPathSignature != signature
            if changed { self.lastPathSignature = signature }
            self.releaseState()
            guard changed else { return }
            self.restartBrowsers(runID: runID)
            self.scheduleGatewayProbe(runID: runID, delay: 0.1)
            self.scheduleSSDP(runID: runID, delay: 0.2)
            self.scheduleDirectProbe(runID: runID, delay: 0.4)
            self.scheduleSweep(runID: runID, delay: 6)
        }

        acquireState()
        verifyTask = task
        releaseState()
    }

    private func currentSignature() -> String {
        LocalNetworkProbe.wifiIPv4Address() ?? "none"
    }

    // MARK: - SSDP

    private func scheduleSSDP(runID: UUID, delay: TimeInterval) {
        acquireState()
        ssdpTask?.cancel()
        releaseState()

        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.probeSSDP(runID: runID)
        }

        acquireState()
        ssdpTask = task
        releaseState()
    }

    /// Asks every host on the subnet to identify itself over SSDP.
    ///
    /// This is the only channel that survives an access point which drops
    /// multicast — a head unit hotspot typically does — because the reply is a
    /// unicast datagram addressed to this phone. It also carries the device's
    /// marketing name, which mDNS never exposes.
    private func probeSSDP(runID: UUID) async {
        guard let address = LocalNetworkProbe.wifiIPv4Address() else { return }
        let hosts = LocalNetworkProbe.candidateHosts(address: address, limit: 254)
        guard !hosts.isEmpty else { return }

        // `MX: 2` is the ceiling a device may wait before answering, so the
        // collection window has to outlast it.
        let responders = await SSDPDiscovery.search(hosts: hosts, timeout: 2.5)
        guard !responders.isEmpty, !Task.isCancelled else { return }

        acquireState()
        guard activeRunID == runID else {
            releaseState()
            return
        }
        let known = knownEndpoints
        releaseState()

        // A media renderer that does not run adbd is noise in a list of ADB
        // endpoints. Keep a responder only when it answers on the ADB port, or
        // when a port from an earlier session is already remembered for it.
        // This runs before the description fetch so TVs never cost an HTTP
        // round trip.
        let accepted = await withTaskGroup(of: SSDPService?.self) { group -> [SSDPService] in
            for service in responders {
                group.addTask {
                    if known.contains(where: { $0.host == service.host }) {
                        return service
                    }
                    let open = await LocalNetworkProbe.isReachable(
                        host: service.host,
                        port: LocalNetworkProbe.adbPort,
                        timeout: 1
                    )
                    return open ? service : nil
                }
            }
            var result: [SSDPService] = []
            for await service in group {
                if let service { result.append(service) }
            }
            return result
        }

        guard !accepted.isEmpty, !Task.isCancelled else { return }

        // Now that the list is short, pay for the names.
        let described = await SSDPDiscovery.describeAll(accepted, timeout: 2)
        guard !Task.isCancelled else { return }

        for service in described {
            adopt(ssdp: service, known: known, runID: runID)
        }
    }

    private func adopt(ssdp service: SSDPService, known: [DiscoveryEndpoint], runID: UUID) {
        acquireState()
        guard activeRunID == runID else {
            releaseState()
            return
        }

        let remembered = known.first { $0.host == service.host }
        // A remembered port beats the default: wireless debugging assigns a
        // random one, and a 5555 probe only finds the `adb tcpip` case.
        let port = remembered?.port ?? LocalNetworkProbe.adbPort

        // A probe can outlive the network it started on.
        if remembered == nil,
           let address = LocalNetworkProbe.wifiIPv4Address(),
           !LocalNetworkProbe.isSameSubnet(address, service.host) {
            releaseState()
            return
        }

        ssdpServices[service.host] = service
        if connectDevices[service.host] == nil {
            directEndpoints[service.host] = ProbeRecord(port: port, source: .ssdp)
        }
        let devices = mergedDevicesLocked()
        let continuation = activeContinuation
        releaseState()

        continuation?.yield(.devices(devices))
    }

    // MARK: - Direct probe

    private func scheduleSweep(runID: UUID, delay: TimeInterval) {
        acquireState()
        sweepTask?.cancel()
        releaseState()

        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.sweepSubnet(runID: runID)
        }

        acquireState()
        sweepTask = task
        releaseState()
    }

    private func scheduleGatewayProbe(runID: UUID, delay: TimeInterval) {
        acquireState()
        gatewayTask?.cancel()
        releaseState()

        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.probeGateway(runID: runID)
        }

        acquireState()
        gatewayTask = task
        releaseState()
    }

    /// Dials the default gateway before anything else does any work.
    ///
    /// Exactly one SYN, sent a fraction of a second into the run. When the head
    /// unit hosts the hotspot it *is* the gateway, so this is both the cheapest
    /// and the most likely step in the whole chain — and unlike mDNS or SSDP it
    /// does not need the device to announce anything. Reading the address
    /// instead of assuming `.1` is what makes it work on a unit that picked
    /// something else.
    private func probeGateway(runID: UUID) async {
        guard !hasAnyDevice(runID: runID) else { return }
        guard let address = LocalNetworkProbe.wifiIPv4Address(),
              let gateway = NetworkRouteTable.defaultGatewayIPv4(),
              // A phone hosted hotspot makes the phone the gateway, and adbd
              // never listens on the phone. A VPN makes the default route point
              // at the tunnel, which is not on this subnet at all.
              gateway != address,
              LocalNetworkProbe.isSameSubnet(address, gateway)
        else { return }

        guard await LocalNetworkProbe.isReachable(
            host: gateway,
            port: LocalNetworkProbe.adbPort,
            timeout: 1
        ), !Task.isCancelled else { return }

        adopt(
            endpoint: DiscoveryEndpoint(host: gateway, port: LocalNetworkProbe.adbPort),
            runID: runID,
            source: .gateway
        )
    }

    private func scheduleDirectProbe(runID: UUID, delay: TimeInterval) {
        acquireState()
        probeTask?.cancel()
        releaseState()

        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.probeSubnet(runID: runID)
        }

        acquireState()
        probeTask = task
        releaseState()
    }

    private func probeSubnet(runID: UUID) async {
        // Bonjour already answered; do not touch the network again.
        guard !hasAnyDevice(runID: runID) else { return }
        guard let address = LocalNetworkProbe.wifiIPv4Address() else { return }

        acquireState()
        guard activeRunID == runID else {
            releaseState()
            return
        }
        let known = knownEndpoints
        releaseState()

        // Both shortcuts are read fresh for every attempt: a hotspot can come up
        // and go down between two probes, and a stale gateway is worse than no
        // gateway because it costs a full connect timeout.
        let gateway = NetworkRouteTable.defaultGatewayIPv4()
        let neighbours = NetworkRouteTable.neighbourIPv4Addresses()

        let targets = LocalNetworkProbe.probeTargets(
            address: address,
            gateway: gateway,
            neighbours: neighbours,
            known: known
        )
        guard !targets.isEmpty else { return }

        guard let found = await firstReachable(targets), !Task.isCancelled else { return }
        // The gateway probe has its own head start, but a slow gateway can lose
        // the race to its own neighbourhood. Report the channel that actually
        // produced the hit, not the one that was scheduled first.
        adopt(
            endpoint: found,
            runID: runID,
            source: found.host == gateway ? .gateway : .probe
        )
    }

    /// Sweeps the whole /24, but only after the cheap channels have all had
    /// their turn.
    ///
    /// A head unit is not obliged to take the first address its own DHCP server
    /// hands out — one was observed on `.155` — so the gateway neighbourhood
    /// alone misses real devices. This runs late and only when nothing was
    /// found, because 253 TCP connects is not something to do on every launch.
    private func sweepSubnet(runID: UUID) async {
        guard !Task.isCancelled, !hasAnyDevice(runID: runID) else { return }
        guard let address = LocalNetworkProbe.wifiIPv4Address() else { return }

        let probed = Set(
            LocalNetworkProbe.probeTargets(
                address: address,
                gateway: NetworkRouteTable.defaultGatewayIPv4(),
                neighbours: NetworkRouteTable.neighbourIPv4Addresses(),
                known: []
            ).map(\.host)
        )
        let rest = LocalNetworkProbe.probeSweep(address: address)
            .filter { !probed.contains($0.host) }
        guard !rest.isEmpty else { return }

        guard let found = await firstReachable(rest), !Task.isCancelled else { return }
        adopt(endpoint: found, runID: runID)
    }

    /// Returns the first target that accepts a TCP connection, or `nil`.
    ///
    /// Bounded concurrency keeps a 253-address sweep from opening hundreds of
    /// sockets at once, which iOS throttles hard enough to produce false
    /// negatives.
    private func firstReachable(
        _ targets: [DiscoveryEndpoint],
        batchSize: Int = 64,
        timeout: TimeInterval = 1
    ) async -> DiscoveryEndpoint? {
        var index = 0
        while index < targets.count {
            guard !Task.isCancelled else { return nil }
            let slice = Array(targets[index..<min(index + batchSize, targets.count)])
            let found = await withTaskGroup(of: DiscoveryEndpoint?.self) { group -> DiscoveryEndpoint? in
                for target in slice {
                    group.addTask {
                        await LocalNetworkProbe.isReachable(
                            host: target.host,
                            port: target.port,
                            timeout: timeout
                        ) ? target : nil
                    }
                }
                for await result in group {
                    if let result {
                        group.cancelAll()
                        return result
                    }
                }
                return nil
            }
            if let found { return found }
            index += batchSize
        }
        return nil
    }

    private func hasAnyDevice(runID: UUID) -> Bool {
        acquireState()
        defer { releaseState() }
        guard activeRunID == runID else { return true }
        return !(connectDevices.isEmpty && directEndpoints.isEmpty)
    }

    private func adopt(
        endpoint: DiscoveryEndpoint,
        runID: UUID,
        source: DiscoverySource = .probe
    ) {
        acquireState()
        guard activeRunID == runID,
              connectDevices[endpoint.host] == nil,
              // SSDP and the sweep both run at launch. Whoever lands first owns
              // the port: an SSDP hit may already carry the remembered
              // wireless-debugging port, which a plain 5555 probe would undo.
              directEndpoints[endpoint.host] == nil else {
            releaseState()
            return
        }
        // A probe can outlive the network it started on. Hosts outside the
        // current subnet are only trusted when the app remembers them.
        if !knownEndpoints.contains(endpoint),
           let address = LocalNetworkProbe.wifiIPv4Address(),
           !LocalNetworkProbe.isSameSubnet(address, endpoint.host) {
            releaseState()
            return
        }
        directEndpoints[endpoint.host] = ProbeRecord(port: endpoint.port, source: source)
        let devices = mergedDevicesLocked()
        let continuation = activeContinuation
        releaseState()
        continuation?.yield(.devices(devices))
    }

    // MARK: - Resolution

    private func resolveServices(results: Set<NWBrowser.Result>, kind: BrowserKind, runID: UUID) {
        acquireState()
        guard activeRunID == runID else {
            releaseState()
            return
        }
        let generation: Int
        switch kind {
        case .connect:
            connectResolutionGeneration += 1
            generation = connectResolutionGeneration
        case .pairing:
            pairingResolutionGeneration += 1
            generation = pairingResolutionGeneration
        }
        releaseState()

        let group = DispatchGroup()
        var resolved: [(String, UInt16, String)] = [] // (host, port, name)
        let lock = NSLock()

        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }

            group.enter()
            var done = false
            let doneLock = NSLock()

            func finish(connection: NWConnection, host: String?, port: UInt16?) {
                doneLock.lock()
                defer { doneLock.unlock() }
                guard !done else { return }
                done = true
                if let host, let port {
                    lock.lock()
                    resolved.append((host, port, name))
                    lock.unlock()
                }
                connection.cancel()
                group.leave()
            }

            // Принудительно резолвим в IPv4: AOSP adbd на некоторых Android-версиях
            // отвергает TLS-handshake с IPv6 link-local источников. Mac adb по факту
            // использует IPv4, и работает; наш iOS на link-local IPv6 валится с RST.
            let ipv4Params = NWParameters.tcp
            ipv4Params.allowLocalEndpointReuse = true
            if let ipOptions = ipv4Params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ipOptions.version = .v4
            }

            let connection = NWConnection(to: result.endpoint, using: ipv4Params)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready, .waiting:
                    if let remoteEndpoint = connection.currentPath?.remoteEndpoint,
                       case .hostPort(let hostEndpoint, let portEndpoint) = remoteEndpoint {
                        let hostString: String
                        switch hostEndpoint {
                        case .ipv4(let ipv4Address):
                            // IPv4Address.description иногда добавляет %en0 zone —
                            // для IPv4 это невалидно и ломает NWEndpoint.Host позже.
                            let bytes = [UInt8](ipv4Address.rawValue)
                            hostString = bytes.count == 4
                                ? "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3])"
                                : "\(ipv4Address)"
                        case .ipv6(let ipv6Address):
                            hostString = "\(ipv6Address)"
                        default:
                            hostString = "\(hostEndpoint)"
                        }
                        finish(
                            connection: connection,
                            host: hostString,
                            port: portEndpoint.rawValue
                        )
                    }
                case .failed, .cancelled:
                    finish(connection: connection, host: nil, port: nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + resolveTimeout) {
                finish(connection: connection, host: nil, port: nil)
            }
        }

        group.notify(queue: queue) { [weak self] in
            self?.handleResolved(resolved, kind: kind, runID: runID, generation: generation)
        }
    }

    private func handleResolved(
        _ resolved: [(String, UInt16, String)],
        kind: BrowserKind,
        runID: UUID,
        generation: Int
    ) {
        acquireState()
        guard activeRunID == runID else {
            releaseState()
            return
        }
        let isLatestGeneration: Bool
        switch kind {
        case .connect:
            isLatestGeneration = generation == connectResolutionGeneration
        case .pairing:
            isLatestGeneration = generation == pairingResolutionGeneration
        }
        guard isLatestGeneration else {
            releaseState()
            return
        }

        if kind == .connect {
            var fresh: [String: DiscoveredDevice] = [:]
            for (host, port, name) in resolved {
                fresh[host] = DiscoveredDevice(
                    id: name,
                    name: name.replacingOccurrences(of: "adb-", with: ""),
                    host: host,
                    port: port,
                    isPaired: false,
                    pairingPort: pairingPorts[host],
                    source: .bonjour
                )
            }
            connectDevices = fresh
        } else {
            pairingPorts.removeAll()
            for (host, port, _) in resolved {
                pairingPorts[host] = port
            }
            // A pairing service only exists while Android's pairing dialog is
            // open. Clear every old port before applying the current snapshot.
            for host in Array(connectDevices.keys) {
                connectDevices[host]?.pairingPort = pairingPorts[host]
            }
        }

        let devices = mergedDevicesLocked()
        let continuation = activeContinuation
        releaseState()

        continuation?.yield(.devices(devices))
    }

    /// Bonjour results plus the endpoints found by SSDP and the direct probe.
    ///
    /// A Bonjour record wins on identity because it carries the real ADB
    /// service name, but the SSDP friendly name wins on presentation: "KD-55X85J"
    /// beats "adb-3A4F1B2C-9xQz0w" on a card.
    private func mergedDevicesLocked() -> [DiscoveredDevice] {
        var devices = Array(connectDevices.values)
        for index in devices.indices {
            let host = devices[index].host
            if let ssdp = ssdpServices[host], let name = ssdp.displayName {
                devices[index].name = name
                devices[index].modelName = ssdp.modelName
            }
            devices[index].source = .bonjour
        }
        for (host, record) in directEndpoints where connectDevices[host] == nil {
            let ssdp = ssdpServices[host]
            devices.append(
                DiscoveredDevice(
                    id: "direct:\(host)",
                    // SSDP's friendly name beats a cached `ro.product.model`,
                    // which in turn beats the bare address.
                    name: ssdp?.displayName ?? knownNames[host] ?? "ADB \(host)",
                    host: host,
                    port: record.port,
                    isPaired: false,
                    pairingPort: pairingPorts[host],
                    source: ssdp == nil ? record.source : .ssdp,
                    modelName: ssdp?.modelName
                )
            )
        }
        return devices.sorted { lhs, rhs in
            (lhs.host, lhs.port) < (rhs.host, rhs.port)
        }
    }
}

/// Where a directly probed host came from.
///
/// Kept apart from `DiscoverySource` because a host can be found by SSDP and
/// still end up here carrying the port that SSDP supplied; the record has to
/// remember which channel produced the address, not which one named it.
private struct ProbeRecord {
    var port: UInt16
    var source: DiscoverySource
}
