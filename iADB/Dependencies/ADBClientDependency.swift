import Foundation
import ComposableArchitecture

/// Carries install progress across the escaping boundary inside `withClient`.
///
/// Every call below is funneled through `withClient`, whose operation closure is
/// `@escaping`. A closure argument cannot escape with it — the compiler rejects
/// capturing a non-escaping parameter that way — so the callback is boxed in a
/// value that can be captured freely.
final class TransferProgressReporter: Sendable {
    private let handler: @Sendable (TransferProgress) async -> Void

    init(handler: @Sendable @escaping (TransferProgress) async -> Void) {
        self.handler = handler
    }

    func report(_ progress: TransferProgress) async {
        await handler(progress)
    }
}

/// TCA dependency wrapping ADBClient for testable ADB operations
struct ADBClientDependency: Sendable {
    var connect: @Sendable (_ host: String, _ port: UInt16) async throws -> String
    var disconnect: @Sendable () -> Void
    var resetIdentity: @Sendable () async throws -> Void
    var completeIdentityReset: @Sendable () throws -> Void
    /// SHA-256 of the stored public key, or `nil` before an identity exists.
    var identityFingerprint: @Sendable () -> String?
    /// Public key in `adbkey.pub` format.
    var publicKeyText: @Sendable () throws -> String
    /// Private key as a PKCS#8 PEM, so it can move to or from a desktop.
    var exportPrivateKeyPEM: @Sendable () throws -> String
    /// Replaces the stored identity with the key in the given PEM.
    var importPrivateKeyPEM: @Sendable (String) throws -> Void
    var shell: @Sendable (_ command: String) async throws -> String
    var openShellCommand: @Sendable (
        _ command: String
    ) async throws -> AsyncThrowingStream<ShellEvent, Error>
    var getDeviceProperty: @Sendable (_ property: String) async throws -> String
    var getAndroidVersion: @Sendable () async throws -> String
    var getSDKVersion: @Sendable () async throws -> String
    var getBatteryLevel: @Sendable () async throws -> String
    var getDeviceSerial: @Sendable () async throws -> String
    var listPackages: @Sendable (_ includeSystem: Bool) async throws -> [String]
    var uninstallPackage: @Sendable (_ name: String, _ keepData: Bool) async throws -> String
    var forceStopApp: @Sendable (_ name: String) async throws -> Void
    var clearAppData: @Sendable (_ name: String) async throws -> String
    var listDirectoryEntries: @Sendable (_ path: String) async throws -> [FileEntry]
    var pushData: @Sendable (_ data: Data, _ remotePath: String, _ mode: UInt32) async throws -> Void
    var pushFile: @Sendable (_ localURL: URL, _ remotePath: String, _ mode: UInt32) async throws -> Void
    var pushFileWithProgress: @Sendable (
        _ localURL: URL,
        _ remotePath: String,
        _ mode: UInt32,
        _ reporter: TransferProgressReporter
    ) async throws -> Void
    var pullFileTo: @Sendable (_ remotePath: String, _ localURL: URL) async throws -> Void
    var takeScreenshot: @Sendable () async throws -> Data
    var openLogcatStream: @Sendable () async throws -> ADBStream
    var reboot: @Sendable (_ mode: String) async throws -> Void
}

extension ADBClientDependency: DependencyKey {
    static var liveValue: Self {
        struct RuntimeState {
            var client: ADBClient?
            var generation: UInt64 = 0
        }

        let runtime = LockIsolated(RuntimeState())
        // Сериализатор: ADB-протокол stream-based, один TCP. Параллельные shell/sync
        // команды перемешали бы send/receive и порушили буфер. Все операции
        // выполняются строго по очереди.
        let serializer = RequestSerializer()

        @Sendable func withClient<T: Sendable>(
            _ operation: @escaping @Sendable (ADBClient) async throws -> T
        ) async throws -> T {
            try await serializer.run {
                guard let activeClient = runtime.value.client else { throw ADBError.notConnected }
                return try await operation(activeClient)
            }
        }

        return Self(
            connect: { host, port in
                let reservation = runtime.withValue { state -> (UInt64, ADBClient?) in
                    state.generation &+= 1
                    let previousClient = state.client
                    state.client = nil
                    return (state.generation, previousClient)
                }
                let generation = reservation.0
                reservation.1?.disconnect()
                return try await serializer.run {
                    let newClient = try ADBClient()
                    try Task.checkCancellation()
                    let didPublish = runtime.withValue { state in
                        guard state.generation == generation else { return false }
                        state.client = newClient
                        return true
                    }
                    guard didPublish else {
                        newClient.disconnect()
                        throw CancellationError()
                    }
                    do {
                        try await newClient.connect(host: host, port: port)
                        let isCurrent = runtime.withValue { state in
                            state.generation == generation && state.client === newClient
                        }
                        guard isCurrent else {
                            throw CancellationError()
                        }
                        return newClient.deviceBanner
                    } catch {
                        newClient.disconnect()
                        runtime.withValue { state in
                            if state.generation == generation, state.client === newClient {
                                state.client = nil
                            }
                        }
                        throw error
                    }
                }
            },
            disconnect: {
                let disconnectedClient = runtime.withValue { state -> ADBClient? in
                    state.generation &+= 1
                    let disconnectedClient = state.client
                    state.client = nil
                    return disconnectedClient
                }
                disconnectedClient?.disconnect()
            },
            resetIdentity: {
                try ADBCrypto.markIdentityResetPending()
                let disconnectedClient = runtime.withValue { state -> ADBClient? in
                    state.generation &+= 1
                    let disconnectedClient = state.client
                    state.client = nil
                    return disconnectedClient
                }
                disconnectedClient?.disconnect()
                try await serializer.run {
                    try ADBCrypto.deleteStoredIdentity()
                }
            },
            completeIdentityReset: {
                try ADBCrypto.clearIdentityResetPending()
            },
            identityFingerprint: {
                ADBCrypto.storedIdentityFingerprint()
            },
            publicKeyText: {
                try ADBCrypto.publicKeyText()
            },
            exportPrivateKeyPEM: {
                try ADBCrypto.exportPrivateKeyPEM()
            },
            importPrivateKeyPEM: { pem in
                try ADBCrypto.importPrivateKeyPEM(pem)
            },
            shell: { command in
                try await withClient { try await $0.shell(command) }
            },
            openShellCommand: { command in
                AsyncThrowingStream { continuation in
                    let task = Task {
                        do {
                            try await serializer.run {
                                guard let activeClient = runtime.value.client else { throw ADBError.notConnected }
                                let events = try await activeClient.openShellCommand(command)
                                for try await event in events {
                                    try Task.checkCancellation()
                                    continuation.yield(event)
                                }
                            }
                            continuation.finish()
                        } catch is CancellationError {
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            getDeviceProperty: { property in
                try await withClient { try await $0.getDeviceProperty(property) }
            },
            getAndroidVersion: {
                try await withClient { try await $0.getAndroidVersion() }
            },
            getSDKVersion: {
                try await withClient { try await $0.getSDKVersion() }
            },
            getBatteryLevel: {
                try await withClient { try await $0.getBatteryLevel() }
            },
            getDeviceSerial: {
                try await withClient { try await $0.getDeviceSerial() }
            },
            listPackages: { includeSystem in
                try await withClient { try await $0.listPackages(includeSystem: includeSystem) }
            },
            uninstallPackage: { name, keepData in
                try await withClient { try await $0.uninstallPackage(name, keepData: keepData) }
            },
            forceStopApp: { name in
                try await withClient { try await $0.forceStopApp(name) }
            },
            clearAppData: { name in
                try await withClient { try await $0.clearAppData(name) }
            },
            listDirectoryEntries: { path in
                try await withClient { try await $0.listDirectoryEntries(path) }
            },
            pushData: { data, remotePath, mode in
                try await withClient { try await $0.pushData(data, to: remotePath, mode: mode) }
            },
            pushFile: { localURL, remotePath, mode in
                try await withClient { try await $0.pushFile(from: localURL, to: remotePath, mode: mode) }
            },
            pushFileWithProgress: { localURL, remotePath, mode, reporter in
                try await withClient { client in
                    try await client.pushFile(
                        from: localURL,
                        to: remotePath,
                        mode: mode
                    ) { progress in
                        await reporter.report(progress)
                    }
                }
            },
            pullFileTo: { remotePath, localURL in
                try await withClient { try await $0.pullFile(remotePath: remotePath, to: localURL) }
            },
            takeScreenshot: {
                try await withClient { try await $0.takeScreenshot() }
            },
            openLogcatStream: {
                try await withClient { try await $0.openLogcatStream() }
            },
            reboot: { mode in
                try await withClient { try await $0.reboot(mode: mode) }
            }
        )
    }

    static var testValue: Self {
        Self(
            connect: unimplemented("ADBClientDependency.connect"),
            disconnect: unimplemented("ADBClientDependency.disconnect"),
            resetIdentity: unimplemented("ADBClientDependency.resetIdentity"),
            completeIdentityReset: unimplemented("ADBClientDependency.completeIdentityReset"),
            identityFingerprint: { nil },
            publicKeyText: { "" },
            exportPrivateKeyPEM: { "" },
            importPrivateKeyPEM: { _ in },
            shell: unimplemented("ADBClientDependency.shell"),
            openShellCommand: unimplemented("ADBClientDependency.openShellCommand"),
            getDeviceProperty: unimplemented("ADBClientDependency.getDeviceProperty"),
            getAndroidVersion: unimplemented("ADBClientDependency.getAndroidVersion"),
            getSDKVersion: unimplemented("ADBClientDependency.getSDKVersion"),
            getBatteryLevel: unimplemented("ADBClientDependency.getBatteryLevel"),
            getDeviceSerial: unimplemented("ADBClientDependency.getDeviceSerial"),
            listPackages: unimplemented("ADBClientDependency.listPackages"),
            uninstallPackage: unimplemented("ADBClientDependency.uninstallPackage"),
            forceStopApp: unimplemented("ADBClientDependency.forceStopApp"),
            clearAppData: unimplemented("ADBClientDependency.clearAppData"),
            listDirectoryEntries: unimplemented("ADBClientDependency.listDirectoryEntries"),
            pushData: unimplemented("ADBClientDependency.pushData"),
            pushFile: unimplemented("ADBClientDependency.pushFile"),
            // `unimplemented` cannot infer a result type for this member: its
            // signature ends in a closure whose own parameter is a class, and
            // the call resolves to an overload that was retired. Throwing keeps
            // a forgotten stub visible as an unexpected error in `TestStore`.
            pushFileWithProgress: { _, _, _, _ in
                throw ADBError.fileTransferFailed("pushFileWithProgress is not stubbed")
            },
            pullFileTo: unimplemented("ADBClientDependency.pullFileTo"),
            takeScreenshot: unimplemented("ADBClientDependency.takeScreenshot"),
            openLogcatStream: unimplemented("ADBClientDependency.openLogcatStream"),
            reboot: unimplemented("ADBClientDependency.reboot")
        )
    }
}

extension DependencyValues {
    var adbClient: ADBClientDependency {
        get { self[ADBClientDependency.self] }
        set { self[ADBClientDependency.self] = newValue }
    }
}
