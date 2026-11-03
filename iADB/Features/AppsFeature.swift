import ComposableArchitecture
import ConcurrencyExtras
import Foundation

@Reducer
struct AppsFeature {
    @ObservableState
    struct State: Equatable {
        var apps: [AppInfo] = []
        var isConnected = false
        var isLoading = false
        var isMutating = false
        var isInstalling = false
        var installProgress: InstallProgress?
        /// `pm install -g`: grant every runtime permission the package declares.
        /// Android Studio does the same, and a manual device install would
        /// otherwise stop at a permission dialog the user cannot reach from here.
        var grantsPermissions = true
        var errorMessage: String?
    }

    enum Action {
        case setConnected(Bool)
        case load
        case loaded(Result<[String], Error>)
        case uninstall(String)
        case forceStop(String)
        case clearData(String)
        case launch(String)
        case mutationFinished(package: String, removesPackage: Bool, Result<Void, Error>)
        case install(URL)
        case installRemote(String)
        case installProgressed(TransferProgress)
        case installUploadFinished
        case installFinished(Result<Void, Error>)
        case setGrantsPermissions(Bool)
        case cancel
    }

    private enum CancelID { case request }
    @Dependency(\.adbClient) var adbClient

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .setConnected(let value):
                state.isConnected = value
                return value ? .none : .send(.cancel)

            case .load:
                guard state.isConnected else { return .none }
                state.isLoading = true
                state.errorMessage = nil
                return .run { send in
                    do {
                        await send(.loaded(.success(try await adbClient.listPackages(true))))
                    } catch {
                        await send(.loaded(.failure(error)))
                    }
                }
                .cancellable(id: CancelID.request, cancelInFlight: true)

            case .loaded(.success(let packages)):
                state.isLoading = false
                state.apps = Set(packages).sorted().map { AppInfo(packageName: $0) }
                clearFinishedInstall(&state)
                return .none

            case .loaded(.failure(let error)):
                state.isLoading = false
                state.errorMessage = error.localizedDescription
                clearFinishedInstall(&state)
                return .none

            case .uninstall(let package):
                return mutate(&state, package: package, removesPackage: true) {
                    _ = try await adbClient.uninstallPackage(package, false)
                }

            case .forceStop(let package):
                return mutate(&state, package: package, removesPackage: false) {
                    try await adbClient.forceStopApp(package)
                }

            case .clearData(let package):
                return mutate(&state, package: package, removesPackage: false) {
                    _ = try await adbClient.clearAppData(package)
                }

            case .launch(let package):
                return mutate(&state, package: package, removesPackage: false) {
                    _ = try await adbClient.shell("monkey -p \(adbShellQuote(package)) 1")
                }

            case .mutationFinished(let package, let removesPackage, .success):
                state.isMutating = false
                if removesPackage {
                    state.apps.removeAll { $0.packageName == package }
                }
                return .none

            case .mutationFinished(_, _, .failure(let error)):
                state.isMutating = false
                state.errorMessage = error.localizedDescription
                return .none

            case .install(let url):
                guard state.isConnected, !state.isInstalling else { return .none }
                let totalUnits = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                    .map { Int64($0) }
                state.isInstalling = true
                state.errorMessage = nil
                state.installProgress = InstallProgress(
                    fileName: url.lastPathComponent,
                    phase: .uploading,
                    totalUnits: totalUnits
                )
                let grantsPermissions = state.grantsPermissions
                return .run { send in
                    let remotePath = "/data/local/tmp/iadb-install.apk"
                    let flags = grantsPermissions ? "-r -g" : "-r"
                    // The staged copy exists only for this transfer; an APK can
                    // be hundreds of megabytes, so drop it on every exit path.
                    defer { try? FileManager.default.removeItem(at: url) }
                    // The SYNC service reports every 64 KiB chunk; the throttle
                    // keeps that flood from rebuilding the banner thousands of
                    // times for a large package.
                    let throttle = LockIsolated(InstallProgressThrottle())
                    let reporter = TransferProgressReporter { progress in
                        guard throttle.withValue({ $0.shouldReport(progress) }) else { return }
                        await send(.installProgressed(progress))
                    }
                    do {
                        try await adbClient.pushFileWithProgress(url, remotePath, 0o644, reporter)
                        await send(.installUploadFinished)
                        _ = try await adbClient.shell("pm install \(flags) \(adbShellQuote(remotePath))")
                        _ = try? await adbClient.shell("rm -f \(adbShellQuote(remotePath))")
                        await send(.installFinished(.success(())))
                    } catch {
                        _ = try? await adbClient.shell("rm -f \(adbShellQuote(remotePath))")
                        await send(.installFinished(.failure(error)))
                    }
                }
                .cancellable(id: CancelID.request, cancelInFlight: true)

            case .installProgressed(let progress):
                guard var current = state.installProgress else { return .none }
                current.completedUnits = progress.completedUnits
                if let totalUnits = progress.totalUnits {
                    current.totalUnits = totalUnits
                }
                state.installProgress = current
                return .none

            case .installUploadFinished:
                state.installProgress?.phase = .installing
                return .none

            case .setGrantsPermissions(let value):
                state.grantsPermissions = value
                return .none

            case .installRemote(let path):
                guard state.isConnected, !state.isInstalling else { return .none }
                guard path.hasPrefix("/") else {
                    state.errorMessage = "Destination must be absolute"
                    return .none
                }
                state.isInstalling = true
                state.errorMessage = nil
                state.installProgress = InstallProgress(
                    fileName: (path as NSString).lastPathComponent,
                    phase: .installing
                )
                let grantsPermissions = state.grantsPermissions
                return .run { send in
                    let flags = grantsPermissions ? "-r -g" : "-r"
                    do {
                        _ = try await adbClient.shell("pm install \(flags) \(adbShellQuote(path))")
                        await send(.installFinished(.success(())))
                    } catch {
                        await send(.installFinished(.failure(error)))
                    }
                }
                .cancellable(id: CancelID.request, cancelInFlight: true)

            case .installFinished(.success):
                state.isInstalling = false
                // Keep the banner on screen with a completed state; the reload
                // that follows clears it once the fresh list is in.
                state.installProgress?.phase = .installed
                return .send(.load)

            case .installFinished(.failure(let error)):
                state.isInstalling = false
                state.installProgress = nil
                state.errorMessage = error.localizedDescription
                return .none

            case .cancel:
                state.isLoading = false
                state.isMutating = false
                state.isInstalling = false
                state.installProgress = nil
                return .cancel(id: CancelID.request)
            }
        }
    }

    /// Drops the success banner once the refreshed list is back, so it does
    /// not linger after it has already told the user what happened.
    private func clearFinishedInstall(_ state: inout State) {
        guard state.installProgress?.phase == .installed else { return }
        state.installProgress = nil
    }

    private func mutate(
        _ state: inout State,
        package: String,
        removesPackage: Bool,
        operation: @escaping @Sendable () async throws -> Void
    ) -> Effect<Action> {
        guard state.isConnected, !state.isMutating, !state.isInstalling else { return .none }
        state.isMutating = true
        state.errorMessage = nil
        return .run { send in
            do {
                try await operation()
                await send(.mutationFinished(package: package, removesPackage: removesPackage, .success(())))
            } catch {
                await send(.mutationFinished(package: package, removesPackage: removesPackage, .failure(error)))
            }
        }
        .cancellable(id: CancelID.request, cancelInFlight: true)
    }
}
