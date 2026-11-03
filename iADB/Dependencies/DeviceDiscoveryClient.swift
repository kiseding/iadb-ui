import Foundation
import ComposableArchitecture

/// One address worth probing directly, without Bonjour.
///
/// Wireless debugging assigns a random connect port on Android 11+, so an
/// endpoint that worked once is far more valuable than a port guess.
struct DiscoveryEndpoint: Equatable, Hashable, Sendable, Codable {
    var host: String
    var port: UInt16
}

/// Everything discovery needs before it starts browsing.
struct DiscoveryContext: Equatable, Sendable {
    var pairedKeys: [Data] = []
    /// Endpoints that connected before, newest first.
    var knownEndpoints: [DiscoveryEndpoint] = []

    init(pairedKeys: [Data] = [], knownEndpoints: [DiscoveryEndpoint] = []) {
        self.pairedKeys = pairedKeys
        self.knownEndpoints = knownEndpoints
    }
}

enum DeviceDiscoveryEvent: Equatable {
    /// Both Bonjour browsers are running. The initial scan is complete even if
    /// no services have been published yet.
    case ready
    /// Scanning is held back by the network itself — Wi-Fi switched away, or
    /// the interface is still being configured. Recoverable without user action.
    case waiting(String)
    case devices([DiscoveredDevice])
    case failure(String)
}

struct DeviceDiscoveryClient: Sendable {
    var start: @Sendable (DiscoveryContext) -> AsyncStream<DeviceDiscoveryEvent>
    var stop: @Sendable () -> Void
    /// Records an endpoint that just connected, so later runs can probe it even
    /// when the device listens on a random port.
    var rememberEndpoint: @Sendable (DiscoveryEndpoint) -> Void
    /// Records the marketing name a device reported over ADB, keyed by host.
    ///
    /// SSDP only names devices that answer UPnP, and plenty of head units do
    /// not. A device that was connected once already told us what it is, so
    /// caching that beats showing "ADB 192.168.43.155" forever.
    var rememberName: @Sendable (String, String) -> Void
}

extension DeviceDiscoveryClient: DependencyKey {
    static var liveValue: Self {
        let discovery = ADBDeviceDiscovery()
        return Self(
            start: { context in discovery.start(context: context) },
            stop: { discovery.stop() },
            rememberEndpoint: { endpoint in discovery.remember(endpoint: endpoint) },
            rememberName: { host, name in discovery.remember(name: name, forHost: host) }
        )
    }

    static var testValue: Self {
        Self(
            start: { _ in AsyncStream { $0.finish() } },
            stop: {},
            rememberEndpoint: { _ in },
            rememberName: { _, _ in }
        )
    }
}

extension DependencyValues {
    var deviceDiscoveryClient: DeviceDiscoveryClient {
        get { self[DeviceDiscoveryClient.self] }
        set { self[DeviceDiscoveryClient.self] = newValue }
    }
}
