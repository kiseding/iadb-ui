import ComposableArchitecture
import Foundation

@Reducer
struct AppFeature {
    @ObservableState
    struct State: Equatable {
        var connection = ConnectionFeature.State()
        var pairing = PairingFeature.State()
        var deviceInfo = DeviceInfoFeature.State()
        var apps = AppsFeature.State()
        var files = FileManagerFeature.State()
        var shell = ShellFeature.State()
        var logcat = LogcatFeature.State()
        var screenshots = ScreenshotFeature.State()
    }

    enum Action {
        case bootstrap
        case connection(ConnectionFeature.Action)
        case pairing(PairingFeature.Action)
        case deviceInfo(DeviceInfoFeature.Action)
        case apps(AppsFeature.Action)
        case files(FileManagerFeature.Action)
        case shell(ShellFeature.Action)
        case logcat(LogcatFeature.Action)
        case screenshots(ScreenshotFeature.Action)
    }

    var body: some ReducerOf<Self> {
        Scope(state: \.connection, action: \.connection) { ConnectionFeature() }
        Scope(state: \.pairing, action: \.pairing) { PairingFeature() }
        Scope(state: \.deviceInfo, action: \.deviceInfo) { DeviceInfoFeature() }
        Scope(state: \.apps, action: \.apps) { AppsFeature() }
        Scope(state: \.files, action: \.files) { FileManagerFeature() }
        Scope(state: \.shell, action: \.shell) { ShellFeature() }
        Scope(state: \.logcat, action: \.logcat) { LogcatFeature() }
        Scope(state: \.screenshots, action: \.screenshots) { ScreenshotFeature() }

        Reduce { state, action in
            func releaseSession() -> Effect<Action> {
                .merge(
                    .send(.deviceInfo(.cancel)),
                    .send(.apps(.setConnected(false))),
                    .send(.files(.setConnected(false))),
                    .send(.shell(.setConnected(false))),
                    .send(.logcat(.setConnected(false))),
                    .send(.screenshots(.setConnected(false)))
                )
            }

            switch action {
            case .bootstrap:
                return .merge(
                    .send(.connection(.loadSavedDevices)),
                    .send(.shell(.loadHistory)),
                    .send(.screenshots(.load))
                )

            case .connection(.savedDevicesLoaded),
                 .connection(.pairedDeviceSaved(.success)),
                 .connection(.deviceForgotten(.success)):
                return .send(.connection(.refreshDiscovery))

            case .pairing(.completed(let name, let guid)):
                let host = state.pairing.host.trimmingCharacters(in: .whitespacesAndNewlines)
                let device = PairedDevice(
                    name: name.isEmpty ? host : name,
                    guid: guid,
                    lastHost: host,
                    lastPort: UInt16(state.pairing.port)
                )
                return .merge(
                    .send(.connection(.savePairedDevice(device))),
                    .send(.connection(.startDiscovery))
                )

            case .connection(.connectionFinished(let device, .success)):
                let identity = DeviceIdentity.resolved(
                    from: device,
                    pairedDevices: state.connection.pairedDevices
                )
                return .merge(
                    .send(.apps(.setConnected(true))),
                    .send(.files(.setConnected(true))),
                    .send(.shell(.setDevice(identity.stableID))),
                    .send(.shell(.setConnected(true))),
                    .send(.logcat(.setConnected(true))),
                    .send(.screenshots(.setDevice(id: identity.stableID, name: identity.displayName))),
                    .send(.screenshots(.setConnected(true))),
                    .send(.deviceInfo(.fetch)),
                    .send(.apps(.load)),
                    .send(.files(.load()))
                )

            case .connection(.connectionFinished(_, .failure)),
                 .connection(.disconnect):
                return releaseSession()

            case .connection(.identityReset(.success)):
                return .merge(
                    releaseSession(),
                    .send(.connection(.startDiscovery))
                )

            default:
                return .none
            }
        }
    }
}
