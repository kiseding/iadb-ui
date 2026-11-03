import ComposableArchitecture
import ConcurrencyExtras
import Foundation
import XCTest
@testable import iADB

@MainActor
final class AppsInstallTests: XCTestCase {
    private func makeStore(
        grants: Bool,
        command: LockIsolated<String?>
    ) -> TestStore<AppsFeature.State, AppsFeature.Action> {
        var state = AppsFeature.State()
        state.isConnected = true
        state.grantsPermissions = grants
        return TestStore(initialState: state) { AppsFeature() } withDependencies: {
            $0.adbClient.shell = { value in
                command.withValue { $0 = value }
                return ""
            }
            $0.adbClient.listPackages = { _ in [] }
        }
    }

    private func driveInstall(
        _ store: TestStore<AppsFeature.State, AppsFeature.Action>,
        path: String,
        fileName: String
    ) async {
        await store.send(.installRemote(path)) {
            $0.isInstalling = true
            $0.installProgress = InstallProgress(fileName: fileName, phase: .installing)
        }
        await store.receive(\.installFinished) {
            $0.isInstalling = false
            $0.installProgress?.phase = .installed
        }
        await store.receive(\.load) {
            $0.isLoading = true
        }
        await store.receive(\.loaded) {
            $0.isLoading = false
            $0.apps = []
            $0.installProgress = nil
        }
    }

    func testInstallGrantsRuntimePermissionsByDefault() async {
        let command = LockIsolated<String?>(nil)
        let store = makeStore(grants: true, command: command)

        await driveInstall(store, path: "/data/local/tmp/demo.apk", fileName: "demo.apk")

        XCTAssertEqual(command.value, "pm install -r -g '/data/local/tmp/demo.apk'")
    }

    func testInstallSkipsTheGrantFlagWhenTheToggleIsOff() async {
        let command = LockIsolated<String?>(nil)
        let store = makeStore(grants: false, command: command)

        await driveInstall(store, path: "/data/local/tmp/demo.apk", fileName: "demo.apk")

        XCTAssertEqual(command.value, "pm install -r '/data/local/tmp/demo.apk'")
    }

    func testInstallKeepsAPathWithSpacesInOneArgument() async {
        let command = LockIsolated<String?>(nil)
        let store = makeStore(grants: true, command: command)

        await driveInstall(
            store,
            path: "/data/local/tmp/my app.apk",
            fileName: "my app.apk"
        )

        XCTAssertEqual(command.value, "pm install -r -g '/data/local/tmp/my app.apk'")
    }
}
