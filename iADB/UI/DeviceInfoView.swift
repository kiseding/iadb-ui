import ComposableArchitecture
import SwiftUI

struct DeviceInfoView: View {
    @Bindable var store: StoreOf<AppFeature>
    @State private var rebootChoice: RebootChoice?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ConnectionStrip(
                    state: store.connection.connectionState,
                    device: store.connection.connectedDevice
                )
                ErrorBanner(message: store.deviceInfo.errorMessage)
                if hasDetails {
                    hero
                    infoCard
                    rebootCard
                } else if !isConnected {
                    LabEmpty(
                        symbol: "iphone.gen3",
                        title: "No device session",
                        message: "Connect from Devices. iADB will read model, Android version, battery, and the build fingerprint."
                    )
                    .frame(minHeight: 320)
                } else if store.deviceInfo.isLoading {
                    ProgressView("Reading device properties")
                        .tint(Theme.accent)
                        .foregroundStyle(Theme.secondary)
                        .padding(.top, 48)
                }
            }
            .padding(16)
            .readableWidth()
        }
        .navigationTitle("Device")
        .labScreen()
        .connectionToolbar(store)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    store.send(.deviceInfo(.fetch))
                }
                .disabled(!isConnected || store.deviceInfo.isLoading)
            }
        }
        .refreshable {
            guard isConnected else { return }
            store.send(.deviceInfo(.fetch))
        }
        .confirmationDialog(
            "Reboot the Android device?",
            isPresented: Binding(
                get: { rebootChoice != nil },
                set: { if !$0 { rebootChoice = nil } }
            ),
            titleVisibility: .visible,
            presenting: rebootChoice
        ) { choice in
            Button(choice.confirmTitle, role: choice == .system ? nil : .destructive) {
                store.send(.deviceInfo(.reboot(choice.mode)))
            }
            Button("Cancel", role: .cancel) {}
        } message: { choice in
            Text(choice.message)
        }
    }

    private var isConnected: Bool {
        store.connection.connectionState == .connected
    }

    private var details: DeviceDetails {
        store.deviceInfo.details
    }

    private var hasDetails: Bool {
        [details.model, details.manufacturer, details.androidVersion, details.serialNumber, details.deviceName]
            .contains { !$0.isEmpty }
    }

    private var hero: some View {
        LabCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(details.manufacturer.isEmpty ? "Android" : details.manufacturer)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.sky)
                            .textCase(.uppercase)
                        Text(displayName)
                            .font(.system(.title, design: .rounded, weight: .bold))
                            .foregroundStyle(Theme.cream)
                        Text(details.deviceName.isEmpty ? " " : details.deviceName)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Label(batteryText, systemImage: batterySymbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                        if store.deviceInfo.isLoading || store.deviceInfo.isRebooting {
                            ProgressView().controlSize(.small).tint(Theme.accent)
                        }
                    }
                }
                HStack(spacing: 8) {
                    metric("Android", details.androidVersion.isEmpty ? "—" : details.androidVersion)
                    metric("SDK", details.sdkVersion.isEmpty ? "—" : details.sdkVersion)
                    metric("ABI", details.cpuAbi.isEmpty ? "—" : details.cpuAbi)
                }
            }
        }
    }

    private var infoCard: some View {
        LabCard {
            VStack(alignment: .leading, spacing: 0) {
                infoRow("Serial", details.serialNumber)
                infoRow("Model property", details.model)
                infoRow("Fingerprint", details.buildFingerprint)
            }
        }
    }

    private var rebootCard: some View {
        LabCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Power")
                    .font(.headline)
                    .foregroundStyle(Theme.cream)
                Text("The connection drops when Android shuts adbd down. That is expected.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                VStack(spacing: 8) {
                    ForEach(RebootChoice.allCases) { choice in
                        PillButton(
                            title: choice.label,
                            systemImage: choice.symbol,
                            role: choice == .system ? .primary : .danger,
                            isLoading: store.deviceInfo.isRebooting,
                            disabled: !isConnected,
                            expands: true
                        ) {
                            rebootChoice = choice
                        }
                    }
                }
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.tertiary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.cream)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.tertiary)
            Text(value.isEmpty ? "—" : value)
                .font(.footnote.monospaced())
                .foregroundStyle(Theme.cream)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
    }

    private var displayName: String {
        if !details.model.isEmpty { return details.model }
        if let name = store.connection.connectedDevice?.name, !name.isEmpty { return name }
        return "Android device"
    }

    private var batteryText: String {
        let raw = details.batteryLevel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "Battery —" }
        if raw.contains("%") { return raw }
        if let value = firstInteger(in: raw), raw.count < 8 { return "\(value)%" }
        return raw
    }

    private var batterySymbol: String {
        guard let value = firstInteger(in: details.batteryLevel) else { return "battery.100percent" }
        switch value {
        case ..<15: return "battery.0percent"
        case ..<40: return "battery.25percent"
        case ..<65: return "battery.50percent"
        case ..<90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func firstInteger(in raw: String) -> Int? {
        guard let range = raw.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(raw[range])
    }
}

private enum RebootChoice: String, CaseIterable, Identifiable {
    case system
    case recovery
    case bootloader

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "Reboot"
        case .recovery: "Recovery"
        case .bootloader: "Bootloader"
        }
    }

    var symbol: String {
        switch self {
        case .system: "arrow.clockwise"
        case .recovery: "wrench.and.screwdriver"
        case .bootloader: "terminal"
        }
    }

    var mode: String {
        switch self {
        case .system: ""
        case .recovery: "recovery"
        case .bootloader: "bootloader"
        }
    }

    var confirmTitle: String {
        switch self {
        case .system: "Reboot"
        case .recovery: "Reboot to recovery"
        case .bootloader: "Reboot to bootloader"
        }
    }

    var message: String {
        switch self {
        case .system: "The device will restart into Android."
        case .recovery: "The device will restart into recovery."
        case .bootloader: "The device will restart into the bootloader."
        }
    }
}
