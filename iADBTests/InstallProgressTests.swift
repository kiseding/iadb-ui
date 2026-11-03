import ComposableArchitecture
import Foundation
import XCTest
@testable import iADB

@MainActor
final class InstallProgressTests: XCTestCase {
    func testFractionAndPercentClampToThePackageSize() {
        var progress = InstallProgress(fileName: "demo.apk", totalUnits: 1_000)
        XCTAssertEqual(progress.fraction, 0)
        XCTAssertEqual(progress.percent, 0)

        progress.completedUnits = 330
        XCTAssertEqual(progress.fraction, 0.33)
        XCTAssertEqual(progress.percent, 33)

        // adbd can report a chunk that overshoots a stale size.
        progress.completedUnits = 1_200
        XCTAssertEqual(progress.fraction, 1)
        XCTAssertEqual(progress.percent, 100)
    }

    func testUnknownSizeHasNoPercentage() {
        let progress = InstallProgress(fileName: "demo.apk", completedUnits: 4_096)
        XCTAssertNil(progress.fraction)
        XCTAssertNil(progress.percent)
        XCTAssertEqual(progress.uploadDetail, "4 KB")
    }

    func testByteTextUsesMebibyteSteps() {
        XCTAssertEqual(InstallProgress.byteText(0), "0 B")
        XCTAssertEqual(InstallProgress.byteText(-12), "0 B")
        XCTAssertEqual(InstallProgress.byteText(512), "512 B")
        XCTAssertEqual(InstallProgress.byteText(1_024), "1 KB")
        XCTAssertEqual(InstallProgress.byteText(1_048_576), "1.0 MB")
        XCTAssertEqual(InstallProgress.byteText(1_500_000), "1.4 MB")
    }

    func testUploadDetailDisappearsWhileTheDeviceInstalls() {
        var progress = InstallProgress(fileName: "demo.apk", completedUnits: 66, totalUnits: 100)
        XCTAssertEqual(progress.uploadDetail, "66 B / 100 B")

        progress.phase = .installing
        XCTAssertNil(progress.uploadDetail)
        XCTAssertEqual(progress.phase.title, "Installing on device")
    }

    func testThrottleReportsOnlyWhenThePercentageMoves() {
        var throttle = InstallProgressThrottle()
        XCTAssertTrue(throttle.shouldReport(sample(0, of: 1_000)))
        XCTAssertFalse(throttle.shouldReport(sample(2, of: 1_000)))
        XCTAssertTrue(throttle.shouldReport(sample(10, of: 1_000)))
        XCTAssertFalse(throttle.shouldReport(sample(12, of: 1_000)))
        XCTAssertTrue(throttle.shouldReport(sample(999, of: 1_000)))
    }

    func testThrottleFallsBackToMebibytesWhenSizeIsUnknown() {
        var throttle = InstallProgressThrottle()
        XCTAssertTrue(throttle.shouldReport(sample(0, of: nil)))
        XCTAssertFalse(throttle.shouldReport(sample(524_288, of: nil)))
        XCTAssertTrue(throttle.shouldReport(sample(1_048_576, of: nil)))
        XCTAssertFalse(throttle.shouldReport(sample(1_500_000, of: nil)))
    }

    func testReducersTrackUploadThenDeviceInstall() async {
        var state = AppsFeature.State()
        state.isInstalling = true
        state.installProgress = InstallProgress(fileName: "demo.apk", totalUnits: 1_000)
        let store = TestStore(initialState: state) { AppsFeature() }

        await store.send(.installProgressed(sample(250, of: 1_000))) {
            $0.installProgress?.completedUnits = 250
        }
        await store.send(.installUploadFinished) {
            $0.installProgress?.phase = .installing
        }
    }

    func testSamplesWithoutAnActiveInstallAreIgnored() async {
        let store = TestStore(initialState: AppsFeature.State()) { AppsFeature() }

        await store.send(.installProgressed(sample(250, of: 1_000)))
    }

    func testFinishedInstallKeepsTheBannerUntilTheListReloads() async {
        var state = AppsFeature.State()
        // `.load` bails out while the device is disconnected, and the reload is
        // what clears the banner, so the connection has to be live here.
        state.isConnected = true
        state.isInstalling = true
        state.installProgress = InstallProgress(fileName: "demo.apk", phase: .installing)
        let store = TestStore(initialState: state) { AppsFeature() } withDependencies: {
            $0.adbClient.listPackages = { _ in [] }
        }

        await store.send(.installFinished(.success(()))) {
            $0.isInstalling = false
            $0.installProgress?.phase = .installed
        }
        // `Action` carries a `Result`, so it cannot be `Equatable`; the case
        // key paths are the only form `receive` accepts here.
        await store.receive(\.load) {
            $0.isLoading = true
            $0.errorMessage = nil
        }
        await store.receive(\.loaded) {
            $0.isLoading = false
            $0.apps = []
            $0.installProgress = nil
        }
    }

    private func sample(_ completed: Int64, of total: Int64?) -> TransferProgress {
        TransferProgress(completedUnits: completed, totalUnits: total)
    }
}
