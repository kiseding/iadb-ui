import ComposableArchitecture
import Foundation

@Reducer
struct ConnectionFeature {
    @ObservableState
    struct State: Equatable {
        var discoveredDevices: [DiscoveredDevice] = []
        var pairedDevices: [PairedDevice] = []
        var isScanning = false
        var connectionState: ConnectionState = .disconnected
        var connectedDevice: DiscoveredDevice?
        var errorMessage: String?
        /// User explicitly stopped Bonjour. Automatic refreshes must not resume it.
        var discoveryPaused = false
        /// Recoverable network state, shown as a quiet note instead of an error.
        var discoveryHint: String?
        /// SHA-256 of the stored ADB public key, or `nil` before one exists.
        var identityFingerprint: String?
        /// One-line feedback for the key import and export actions.
        var identityNote: IdentityNote?
        /// Text the view should place on the pasteboard, then clear.
        var identityClipboard: String?
    }

    enum Action {
        case loadSavedDevices
        case savedDevicesLoaded(Result<[PairedDevice], Error>)
        case startDiscovery
        case refreshDiscovery
        case discoveryEvent(DeviceDiscoveryEvent)
        case stopDiscovery
        case connect(DiscoveredDevice)
        case connectionFinished(DiscoveredDevice, Result<String, Error>)
        case disconnect
        case savePairedDevice(PairedDevice)
        case pairedDeviceSaved(Result<[PairedDevice], Error>)
        case forgetDevice(UUID)
        case deviceForgotten(Result<[PairedDevice], Error>)
        case resetIdentity
        case identityReset(Result<Void, Error>)
        /// Re-reads the stored key fingerprint for the identity card.
        case refreshIdentity
        case copyPublicKey
        case exportIdentityKey
        case importIdentityKey(String)
        case identityTextReady(String)
        case identityClipboardCopied
        case identityNote(IdentityNote?)
        /// The connected device reported its model, so discovery can label the
        /// address next time even when it never answers SSDP.
        case deviceNameRemembered(host: String, name: String)
    }

    /// Outcome of a key action, kept free of localized text so the reducer stays
    /// testable and the view owns the wording.
    enum IdentityNote: Equatable {
        case privateKeyCopied
        case keyImported
        case failed(ADBError)
    }

    private enum CancelID { case discovery, connection }

    @Dependency(\.adbClient) var adbClient
    @Dependency(\.deviceDiscoveryClient) var discoveryClient
    @Dependency(\.pairedDevicesClient) var pairedDevicesClient

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            // Key work only throws ADBError; the fallback keeps a stray system
            // error visible instead of swallowing it.
            func identityNote(for error: Error) -> IdentityNote {
                .failed(error as? ADBError ?? .cryptoError(error.localizedDescription))
            }

            switch action {
            case .loadSavedDevices:
                return .run { send in
                    await send(.savedDevicesLoaded(Result { try pairedDevicesClient.load() }))
                }

            case .savedDevicesLoaded(.success(let devices)):
                state.pairedDevices = devices
                state.errorMessage = nil
                return .none

            case .savedDevicesLoaded(.failure(let error)):
                state.errorMessage = error.localizedDescription
                return .none

            case .startDiscovery:
                state.discoveryPaused = false
                state.isScanning = true
                state.errorMessage = nil
                state.discoveryHint = nil
                let context = DiscoveryContext(
                    pairedKeys: state.pairedDevices.map(\.publicKey),
                    knownEndpoints: state.pairedDevices.compactMap { device -> DiscoveryEndpoint? in
                        guard let port = device.lastPort, !device.lastHost.isEmpty else { return nil }
                        return DiscoveryEndpoint(host: device.lastHost, port: port)
                    }
                )
                return .run { send in
                    for await event in discoveryClient.start(context) {
                        await send(.discoveryEvent(event))
                    }
                }
                .cancellable(id: CancelID.discovery, cancelInFlight: true)

            case .discoveryEvent(.ready):
                state.isScanning = false
                state.discoveryHint = nil
                return .none

            case .discoveryEvent(.waiting(let message)):
                // The network is between states — a hotspot hand-off looks
                // exactly like this. Keep the spinner alive and say what is
                // happening instead of flashing a failure banner.
                state.isScanning = true
                state.errorMessage = nil
                state.discoveryHint = message
                return .none

            case .discoveryEvent(.devices(let devices)):
                state.discoveredDevices = devices
                state.discoveryHint = nil
                return .none

            case .discoveryEvent(.failure(let message)):
                state.isScanning = false
                state.discoveryHint = nil
                state.errorMessage = message
                return .none

            case .refreshDiscovery:
                guard !state.discoveryPaused else { return .none }
                return .send(.startDiscovery)

            case .stopDiscovery:
                state.discoveryPaused = true
                state.isScanning = false
                state.discoveryHint = nil
                discoveryClient.stop()
                return .cancel(id: CancelID.discovery)

            case .connect(let device):
                state.connectionState = .connecting
                state.errorMessage = nil
                return .run { send in
                    do {
                        let banner = try await adbClient.connect(device.host, device.port)
                        await send(.connectionFinished(device, .success(banner)))
                    } catch {
                        await send(.connectionFinished(device, .failure(error)))
                    }
                }
                .cancellable(id: CancelID.connection, cancelInFlight: true)

            case .connectionFinished(let device, .success):
                state.connectedDevice = device
                state.connectionState = .connected
                // Remember the exact endpoint. A wireless-debugging port is
                // random per boot, so the address that just worked is the only
                // reliable way to find the device next time.
                discoveryClient.rememberEndpoint(
                    DiscoveryEndpoint(host: device.host, port: device.port)
                )
                // Ask the device what it is. This is the only name a head unit
                // that skips SSDP and hides from mDNS will ever get.
                let host = device.host
                return .run { send in
                    guard let model = try? await adbClient.getDeviceProperty("ro.product.model"),
                          !model.isEmpty else { return }
                    discoveryClient.rememberName(host, model)
                    await send(.deviceNameRemembered(host: host, name: model))
                }

            case .deviceNameRemembered(let host, let name):
                for index in state.discoveredDevices.indices {
                    // A real model beats "ADB 192.168.43.155", but an SSDP
                    // friendly name is what the vendor chose to show, so it
                    // stays.
                    guard state.discoveredDevices[index].host == host,
                          state.discoveredDevices[index].source == .probe else { continue }
                    state.discoveredDevices[index].name = name
                }
                return .none

            case .connectionFinished(_, .failure(let error)):
                state.connectedDevice = nil
                state.connectionState = .error(error.localizedDescription)
                state.errorMessage = error.localizedDescription
                return .none

            case .disconnect:
                adbClient.disconnect()
                state.connectedDevice = nil
                state.connectionState = .disconnected
                return .cancel(id: CancelID.connection)

            case .savePairedDevice(let device):
                var devices = state.pairedDevices.filter { existing in
                    if existing.id == device.id { return false }
                    if !device.guid.isEmpty, existing.guid == device.guid { return false }
                    return true
                }
                devices.append(device)
                let savedDevices = devices
                return .run { send in
                    await send(.pairedDeviceSaved(Result {
                        try pairedDevicesClient.save(savedDevices)
                        return savedDevices
                    }))
                }

            case .pairedDeviceSaved(.success(let devices)),
                 .deviceForgotten(.success(let devices)):
                state.pairedDevices = devices
                state.errorMessage = nil
                return .none

            case .pairedDeviceSaved(.failure(let error)),
                 .deviceForgotten(.failure(let error)):
                state.errorMessage = error.localizedDescription
                return .none

            case .forgetDevice(let id):
                let devices = state.pairedDevices.filter { $0.id != id }
                return .run { send in
                    await send(.deviceForgotten(Result {
                        try pairedDevicesClient.save(devices)
                        return devices
                    }))
                }

            case .resetIdentity:
                return .run { send in
                    do {
                        try await adbClient.resetIdentity()
                        try pairedDevicesClient.reset()
                        try adbClient.completeIdentityReset()
                        await send(.identityReset(.success(())))
                    } catch {
                        await send(.identityReset(.failure(error)))
                    }
                }

            case .identityReset(.success):
                state = State()
                return .send(.refreshIdentity)

            case .identityReset(.failure(let error)):
                state.errorMessage = error.localizedDescription
                return .none

            case .refreshIdentity:
                state.identityFingerprint = adbClient.identityFingerprint()
                return .none

            case .copyPublicKey:
                return .run { send in
                    do {
                        await send(.identityTextReady(try adbClient.publicKeyText()))
                    } catch {
                        await send(.identityNote(identityNote(for: error)))
                    }
                }

            case .exportIdentityKey:
                return .run { send in
                    do {
                        await send(.identityTextReady(try adbClient.exportPrivateKeyPEM()))
                        await send(.identityNote(.privateKeyCopied))
                    } catch {
                        await send(.identityNote(identityNote(for: error)))
                    }
                }

            case .importIdentityKey(let pem):
                return .run { send in
                    do {
                        try adbClient.importPrivateKeyPEM(pem)
                        await send(.refreshIdentity)
                        await send(.identityNote(.keyImported))
                    } catch {
                        await send(.identityNote(identityNote(for: error)))
                    }
                }

            case .identityTextReady(let text):
                state.identityClipboard = text
                return .none

            case .identityClipboardCopied:
                state.identityClipboard = nil
                return .none

            case .identityNote(let note):
                state.identityNote = note
                return .none
            }
        }
    }
}
