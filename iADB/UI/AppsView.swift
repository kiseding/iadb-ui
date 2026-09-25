import ComposableArchitecture
import SwiftUI
import UniformTypeIdentifiers

struct AppsView: View {
    @Bindable var store: StoreOf<AppFeature>
    @State private var query = ""
    @State private var showSystem = false
    @State private var importAPK = false
    @State private var localError: String?
    @State private var pending: AppAction?

    var body: some View {
        VStack(spacing: 0) {
            controls
            if visibleApps.isEmpty {
                LabEmpty(
                    symbol: "square.grid.2x2",
                    title: store.apps.apps.isEmpty ? "No packages yet" : "Nothing matches",
                    message: isConnected
                        ? "Install an APK or pull to refresh the package list."
                        : "Connect a device to list, launch, and install packages."
                )
            } else {
                List {
                    ForEach(visibleApps) { app in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(app.packageName)
                                .font(.subheadline.monospaced())
                                .foregroundStyle(Theme.cream)
                                .textSelection(.enabled)
                            HStack(spacing: 8) {
                                mini("Launch", "play.fill") { store.send(.apps(.launch(app.packageName))) }
                                mini("Stop", "stop.fill") { store.send(.apps(.forceStop(app.packageName))) }
                                mini("Clear", "eraser") { pending = AppAction(kind: .clear, package: app.packageName) }
                                mini("Remove", "trash", danger: true) {
                                    pending = AppAction(kind: .uninstall, package: app.packageName)
                                }
                            }
                            .disabled(!isConnected || store.apps.isMutating)
                        }
                        .padding(.vertical, 6)
                        .listRowBackground(Theme.panel)
                        .listRowSeparatorTint(Theme.line)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Apps")
        .labScreen()
        .connectionToolbar(store)
        .refreshable {
            guard isConnected else { return }
            store.send(.apps(.load))
        }
        .fileImporter(isPresented: $importAPK, allowedContentTypes: [.data, .item]) { result in
            importPackage(result)
        }
        .confirmationDialog(
            pending?.title ?? "Confirm",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { action in
            Button(action.confirm, role: .destructive) {
                switch action.kind {
                case .uninstall: store.send(.apps(.uninstall(action.package)))
                case .clear: store.send(.apps(.clearData(action.package)))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action.package)
        }
    }

    private var isConnected: Bool { store.connection.connectionState == .connected }

    private var controls: some View {
        VStack(spacing: 10) {
            ErrorBanner(message: localError ?? store.apps.errorMessage)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.tertiary)
                TextField("Filter packages", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(Theme.cream)
            }
            .padding(12)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack {
                Toggle("System packages", isOn: $showSystem)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.secondary)
                    .tint(Theme.accent)
                Spacer()
                Text("\(visibleApps.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }
            PillButton(
                title: "Install APK",
                systemImage: "square.and.arrow.down",
                isLoading: store.apps.isInstalling || store.apps.isLoading,
                disabled: !isConnected,
                expands: true
            ) {
                localError = nil
                importAPK = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var visibleApps: [AppInfo] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.apps.apps.filter { app in
            let matchesQuery = needle.isEmpty || app.packageName.localizedCaseInsensitiveContains(needle)
            let isSystem = app.packageName == "android"
                || app.packageName.hasPrefix("android.")
                || app.packageName.hasPrefix("com.android.")
            return matchesQuery && (showSystem || !isSystem)
        }
    }

    private func mini(_ title: String, _ symbol: String, danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(danger ? Theme.danger : Theme.cream)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Theme.raised, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func importPackage(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            localError = error.localizedDescription
        case .success(let url):
            guard url.pathExtension.lowercased() == "apk" else {
                localError = "Choose an .apk file."
                return
            }
            do {
                let staged = try ImportStaging.copySecurityScopedFile(url)
                localError = nil
                store.send(.apps(.install(staged)))
            } catch {
                localError = error.localizedDescription
            }
        }
    }
}

private struct AppAction: Identifiable {
    enum Kind { case uninstall, clear }
    let id = UUID()
    let kind: Kind
    let package: String

    var title: String {
        switch kind {
        case .uninstall: "Uninstall this package?"
        case .clear: "Clear app data?"
        }
    }

    var confirm: String {
        switch kind {
        case .uninstall: "Uninstall"
        case .clear: "Clear data"
        }
    }
}
