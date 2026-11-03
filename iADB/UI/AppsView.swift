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
                            .disabled(!isConnected || store.apps.isMutating || store.apps.isInstalling)
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
            // The ADB transport is serialized; a refresh queued behind an
            // upload would just spin until the transfer finished.
            guard isConnected, !store.apps.isInstalling else { return }
            store.send(.apps(.load))
        }
        .fileImporter(isPresented: $importAPK, allowedContentTypes: apkTypes) { result in
            importPackage(result)
        }
        .confirmationDialog(
            Text((pending?.title ?? "Confirm").ui),
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { action in
            Button(action.confirm.ui, role: .destructive) {
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
        VStack(spacing: 12) {
            ErrorBanner(message: localError ?? store.apps.errorMessage)
            if let progress = store.apps.installProgress {
                InstallProgressCard(progress: progress) {
                    store.send(.apps(.cancel))
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
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
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1)
            }
            VStack(spacing: 6) {
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
                HStack {
                    // Nested state is read-only through `@Bindable`, so the
                    // toggle routes its writes back as an action.
                    Toggle(
                        "Grant runtime permissions",
                        isOn: Binding(
                            get: { store.apps.grantsPermissions },
                            set: { store.send(.apps(.setGrantsPermissions($0))) }
                        )
                    )
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.secondary)
                    .tint(Theme.accent)
                    Spacer()
                }
            }
            PillButton(
                title: "Install APK",
                systemImage: "square.and.arrow.down",
                isLoading: store.apps.isLoading,
                disabled: !isConnected || store.apps.isInstalling,
                expands: true
            ) {
                localError = nil
                importAPK = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .animation(.snappy(duration: 0.28), value: store.apps.installProgress != nil)
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

    private var apkTypes: [UTType] {
        var types: [UTType] = [.item, .data, .archive, .zip]
        if let apk = UTType(filenameExtension: "apk") {
            types.insert(apk, at: 0)
        }
        return types
    }

    private func importPackage(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error) where (error as? CocoaError)?.code == .userCancelled:
            // Dismissing the picker is not a failure worth a red banner.
            break
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
