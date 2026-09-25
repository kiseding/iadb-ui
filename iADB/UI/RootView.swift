import ComposableArchitecture
import SwiftUI

enum WorkspaceSection: String, CaseIterable, Hashable, Identifiable {
    case devices
    case overview
    case apps
    case files
    case shell
    case logcat
    case screenshots

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .devices: "Devices"
        case .overview: "Device"
        case .apps: "Apps"
        case .files: "Files"
        case .shell: "Shell"
        case .logcat: "Logcat"
        case .screenshots: "Shots"
        }
    }

    var symbol: String {
        switch self {
        case .devices: "dot.radiowaves.left.and.right"
        case .overview: "iphone.gen3"
        case .apps: "square.grid.2x2.fill"
        case .files: "folder.fill"
        case .shell: "terminal.fill"
        case .logcat: "text.alignleft"
        case .screenshots: "camera.viewfinder"
        }
    }
}

private enum PhoneTab: String, CaseIterable, Hashable, Identifiable {
    case devices, apps, files, shell, more

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .devices: "Devices"
        case .apps: "Apps"
        case .files: "Files"
        case .shell: "Shell"
        case .more: "More"
        }
    }

    var symbol: String {
        switch self {
        case .devices: "dot.radiowaves.left.and.right"
        case .apps: "square.grid.2x2.fill"
        case .files: "folder.fill"
        case .shell: "terminal.fill"
        case .more: "square.grid.3x3.fill"
        }
    }
}

struct RootView: View {
    @Bindable var store: StoreOf<AppFeature>
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var section: WorkspaceSection? = .devices
    @State private var phoneTab: PhoneTab = .devices

    var body: some View {
        Group {
            if sizeClass == .compact {
                compactLayout
            } else {
                regularLayout
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .sensoryFeedback(.success, trigger: isConnected)
        .task { store.send(.bootstrap) }
    }

    private var isConnected: Bool {
        store.connection.connectionState == .connected
    }

    private var regularLayout: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 232, ideal: 272, max: 320)
        } detail: {
            NavigationStack {
                sectionScreen(section ?? .devices)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(LabBackground().ignoresSafeArea())
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("iADB")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.cream)
                Text("Wireless Android bench")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)

            ConnectionStrip(
                state: store.connection.connectionState,
                device: store.connection.connectedDevice
            )
            .padding(.horizontal, 14)

            List(selection: $section) {
                Section("Connect") {
                    sidebarRow(.devices)
                }
                Section("Workspace") {
                    sidebarRow(.overview)
                    sidebarRow(.apps)
                    sidebarRow(.files)
                    sidebarRow(.shell)
                    sidebarRow(.logcat)
                    sidebarRow(.screenshots)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(LabBackground().ignoresSafeArea())
    }

    private func sidebarRow(_ item: WorkspaceSection) -> some View {
        Label(item.title, systemImage: item.symbol)
            .tag(item)
            .foregroundStyle(Theme.cream)
    }

    private var compactLayout: some View {
        VStack(spacing: 0) {
            NavigationStack {
                phoneScreen
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            phoneBar
        }
        .background(Theme.ink.ignoresSafeArea())
        .sensoryFeedback(.selection, trigger: phoneTab)
    }

    @ViewBuilder
    private var phoneScreen: some View {
        switch phoneTab {
        case .devices:
            DevicesView(store: store)
        case .apps:
            AppsView(store: store)
        case .files:
            FilesView(store: store)
        case .shell:
            ShellView(store: store)
        case .more:
            MoreMenuView(store: store)
        }
    }

    private var phoneBar: some View {
        HStack(spacing: 0) {
            ForEach(PhoneTab.allCases) { tab in
                Button {
                    phoneTab = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 24, weight: .semibold))
                        Text(tab.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(phoneTab == tab ? Theme.accent : Theme.tertiary)
                    .padding(.top, 6)
                    .padding(.bottom, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .background {
            Theme.panel
                .ignoresSafeArea(edges: [.bottom, .horizontal])
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    @ViewBuilder
    private func sectionScreen(_ section: WorkspaceSection) -> some View {
        switch section {
        case .devices: DevicesView(store: store)
        case .overview: DeviceInfoView(store: store)
        case .apps: AppsView(store: store)
        case .files: FilesView(store: store)
        case .shell: ShellView(store: store)
        case .logcat: LogcatView(store: store)
        case .screenshots: ScreenshotsView(store: store)
        }
    }
}

private struct MoreMenuView: View {
    @Bindable var store: StoreOf<AppFeature>

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ConnectionStrip(
                    state: store.connection.connectionState,
                    device: store.connection.connectedDevice
                )
                menuLink(
                    title: "Device",
                    message: "Model, battery, build, and reboot",
                    symbol: WorkspaceSection.overview.symbol
                ) {
                    DeviceInfoView(store: store)
                }
                menuLink(
                    title: "Logcat",
                    message: "Live threadtime log with filters",
                    symbol: WorkspaceSection.logcat.symbol
                ) {
                    LogcatView(store: store)
                }
                menuLink(
                    title: "Screenshots",
                    message: "Capture the panel and keep a gallery",
                    symbol: WorkspaceSection.screenshots.symbol
                ) {
                    ScreenshotsView(store: store)
                }
            }
            .padding(16)
            .readableWidth()
        }
        .navigationTitle("More")
        .labScreen()
    }

    private func menuLink<Destination: View>(
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        symbol: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(Theme.accentInk)
                    .frame(width: 46, height: 46)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Theme.cream)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(14)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

struct ConnectionToolbar: ViewModifier {
    @Bindable var store: StoreOf<AppFeature>

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                switch store.connection.connectionState {
                case .connected:
                    Button("Disconnect", systemImage: "bolt.slash") {
                        store.send(.connection(.disconnect))
                    }
                    .tint(Theme.danger)
                case .connecting:
                    ProgressView().controlSize(.small)
                case .disconnected, .error:
                    EmptyView()
                }
            }
        }
    }
}

extension View {
    func connectionToolbar(_ store: StoreOf<AppFeature>) -> some View {
        modifier(ConnectionToolbar(store: store))
    }
}

#Preview("Phone") {
    RootView(store: Store(initialState: AppFeature.State()) {
        AppFeature()
    })
}

#Preview("Phone · 中文") {
    RootView(store: Store(initialState: AppFeature.State()) {
        AppFeature()
    })
    .environment(\.locale, Locale(identifier: "zh-Hans"))
}
