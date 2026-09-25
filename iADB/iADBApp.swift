import ComposableArchitecture
import SwiftUI

@main
struct iADBApp: App {
    @State private var store = Store(initialState: AppFeature.State()) {
        AppFeature()
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
        }
    }
}
