import ComposableArchitecture
import Foundation
import XCTest
@testable import iADB

@MainActor
final class IdentityTests: XCTestCase {
    func testRefreshingTheIdentityReadsTheFingerprint() async {
        let store = TestStore(initialState: ConnectionFeature.State()) { ConnectionFeature() }
            withDependencies: {
                $0.adbClient.identityFingerprint = { "abc123" }
            }

        await store.send(.refreshIdentity) {
            $0.identityFingerprint = "abc123"
        }
    }

    func testCopyingThePublicKeyHandsTextToTheView() async {
        let store = TestStore(initialState: ConnectionFeature.State()) { ConnectionFeature() }
            withDependencies: {
                $0.adbClient.publicKeyText = { "AAAA iADB@iOS" }
            }

        await store.send(.copyPublicKey)
        await store.receive(\.identityTextReady) {
            $0.identityClipboard = "AAAA iADB@iOS"
        }
        await store.send(.identityClipboardCopied) {
            $0.identityClipboard = nil
        }
    }

    func testExportingThePrivateKeySurfacesThePEMAndReportsSuccess() async {
        let pem = "-----BEGIN PRIVATE KEY-----\nAA\n-----END PRIVATE KEY-----\n"
        let store = TestStore(initialState: ConnectionFeature.State()) { ConnectionFeature() }
            withDependencies: {
                $0.adbClient.exportPrivateKeyPEM = { pem }
            }

        await store.send(.exportIdentityKey)
        await store.receive(\.identityTextReady) {
            $0.identityClipboard = pem
        }
        await store.receive(\.identityNote) {
            $0.identityNote = .privateKeyCopied
        }
    }

    func testImportingAKeyRefreshesTheFingerprint() async {
        var state = ConnectionFeature.State()
        state.identityFingerprint = "old"
        let store = TestStore(initialState: state) { ConnectionFeature() } withDependencies: {
            $0.adbClient.importPrivateKeyPEM = { _ in }
            $0.adbClient.identityFingerprint = { "new" }
        }

        await store.send(.importIdentityKey("PEM BODY"))
        await store.receive(\.refreshIdentity) {
            $0.identityFingerprint = "new"
        }
        await store.receive(\.identityNote) {
            $0.identityNote = .keyImported
        }
    }

    func testAFailedImportLeavesTheIdentityAlone() async {
        var state = ConnectionFeature.State()
        state.identityFingerprint = "unchanged"
        let store = TestStore(initialState: state) { ConnectionFeature() } withDependencies: {
            $0.adbClient.importPrivateKeyPEM = { _ in
                throw ADBError.cryptoError("bad key")
            }
        }

        await store.send(.importIdentityKey("garbage"))
        await store.receive(\.identityNote) {
            $0.identityNote = .failed(.cryptoError("bad key"))
        }
        XCTAssertEqual(store.state.identityFingerprint, "unchanged")
        XCTAssertNil(store.state.identityClipboard)
    }
}
