import Foundation

/// Detailed device info fetched via ADB
struct DeviceDetails: Equatable {
    var model: String = ""
    var manufacturer: String = ""
    var androidVersion: String = ""
    var sdkVersion: String = ""
    var serialNumber: String = ""
    var buildFingerprint: String = ""
    var batteryLevel: String = ""
    var cpuAbi: String = ""
    var deviceName: String = ""
}

/// How a device was found. Shown in the UI because the channels fail
/// independently and the answer decides what to fix when nothing appears.
enum DiscoverySource: String, Equatable, Sendable {
    /// Bonjour/mDNS service record. Carries the real ADB service name.
    case bonjour
    /// SSDP/UPnP responder. Survives multicast filtering, and often knows the
    /// marketing model name of the device.
    case ssdp
    /// Direct TCP probe of port 5555.
    case probe
    /// The default gateway of the current network, dialled as soon as the run
    /// starts. Only matches when the device hosts the hotspot itself.
    case gateway
    /// Typed in by hand.
    case manual

    var label: String {
        switch self {
        case .bonjour: return String(localized: "mDNS")
        case .ssdp: return String(localized: "SSDP")
        case .probe: return String(localized: "Probe")
        case .gateway: return String(localized: "Gateway")
        case .manual: return String(localized: "Manual")
        }
    }
}

struct DiscoveredDevice: Identifiable, Equatable {
    let id: String
    var name: String
    var host: String
    var port: UInt16
    var isPaired: Bool
    /// Порт pairing-сервиса (появляется когда на Android нажали "Pair with code")
    var pairingPort: UInt16?
    /// Which channel produced this row.
    var source: DiscoverySource = .manual
    /// `<modelName>` from the UPnP description, when SSDP supplied one.
    var modelName: String?
}

struct PairedDevice: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var guid: String
    var lastHost: String
    var lastPort: UInt16?
    /// Fingerprint of the iADB public key used when this device was paired.
    var identityFingerprint: String?
    /// Set after Android explicitly rejects this host identity. The record is
    /// kept so the user can pair the same device again without losing its name.
    var requiresPairing: Bool
    /// Persistent mDNS identity derived from Android's ADB_DEVICE_GUID.
    /// It is authenticated by the pairing-code exchange; host/port are only
    /// mutable network locators and must never identify a saved device.
    var serviceName: String?

    init(
        id: UUID = UUID(),
        name: String,
        guid: String,
        lastHost: String,
        lastPort: UInt16? = nil,
        identityFingerprint: String? = nil,
        requiresPairing: Bool = false,
        serviceName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.guid = guid
        self.lastHost = lastHost
        self.lastPort = lastPort
        self.identityFingerprint = identityFingerprint
        self.requiresPairing = requiresPairing
        self.serviceName = serviceName
    }

    var publicKey: Data { Data(guid.utf8) }

    var displayName: String {
        name.isEmpty ? lastHost : name
    }
}

/// Connection state
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)

}
