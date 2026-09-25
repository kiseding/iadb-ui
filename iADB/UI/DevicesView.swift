import ComposableArchitecture
import SwiftUI
import UIKit

struct DevicesView: View {
    @Bindable var store: StoreOf<AppFeature>
    @State private var manualHost = ""
    @State private var manualPort = "5555"
    @State private var manualError: String?
    @State private var showPairing = false
    @State private var confirmReset = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ConnectionStrip(
                    state: store.connection.connectionState,
                    device: store.connection.connectedDevice
                )
                ErrorBanner(message: manualError ?? store.connection.errorMessage)
                manualCard
                nearbyCard
                savedCard
                PillButton(title: "Reset this iPhone's ADB identity", systemImage: "key.slash", role: .danger, expands: true) {
                    confirmReset = true
                }
            }
            .padding(16)
            .readableWidth()
        }
        .navigationTitle("Devices")
        .labScreen()
        .connectionToolbar(store)
        .refreshable {
            store.send(.connection(.refreshDiscovery))
        }
        .sheet(isPresented: $showPairing, onDismiss: {
            if store.pairing.isPairing {
                store.send(.pairing(.cancel))
            }
        }) {
            PairingSheet(store: store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "Forget the saved ADB identity?",
            isPresented: $confirmReset,
            titleVisibility: .visible
        ) {
            Button("Reset identity", role: .destructive) {
                store.send(.connection(.resetIdentity))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Paired Android devices will need a new pairing code. Saved names on this iPhone are cleared.")
        }
    }

    private var manualCard: some View {
        LabCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Manual endpoint", symbol: "number")
                Text("Use the IP and port shown under Wireless debugging when the device is not discovered automatically.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                HStack(spacing: 10) {
                    field("Host", text: $manualHost, keyboard: .numbersAndPunctuation)
                    field("Port", text: $manualPort, keyboard: .numberPad)
                        .frame(width: 96)
                }
                PillButton(
                    title: "Connect",
                    systemImage: "bolt.horizontal",
                    isLoading: store.connection.connectionState == .connecting,
                    expands: true
                ) {
                    connectManually()
                }
            }
        }
    }

    private var nearbyCard: some View {
        LabCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    sectionTitle("Nearby", symbol: "dot.radiowaves.left.and.right")
                    Spacer()
                    if store.connection.isScanning {
                        ProgressView().controlSize(.small).tint(Theme.sky)
                    }
                    Button(store.connection.discoveryPaused ? "Scan" : "Pause") {
                        if store.connection.discoveryPaused {
                            store.send(.connection(.startDiscovery))
                        } else {
                            store.send(.connection(.stopDiscovery))
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.sky)
                }
                Text(store.connection.discoveryPaused ? "Discovery is paused." : "Watching the local network for wireless debugging.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                if store.connection.discoveredDevices.isEmpty {
                    Text("No devices yet. Enable Wireless debugging, and keep the phone on the same network.")
                        .font(.footnote)
                        .foregroundStyle(Theme.tertiary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(store.connection.discoveredDevices) { device in
                        discoveredRow(device)
                    }
                }
            }
        }
    }

    private var savedCard: some View {
        LabCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Saved", symbol: "checkmark.seal")
                if store.connection.pairedDevices.isEmpty {
                    Text("Paired devices stay here, including the name Android reported.")
                        .font(.footnote)
                        .foregroundStyle(Theme.tertiary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(store.connection.pairedDevices) { device in
                        savedRow(device)
                    }
                }
                Button {
                    showPairing = true
                } label: {
                    Label("Pair with code", systemImage: "qrcode")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(Theme.cream)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func discoveredRow(_ device: DiscoveredDevice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name.isEmpty ? device.host : device.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.cream)
                    Text("\(device.host):\(device.port)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
                statusPill(device.isPaired ? "Paired" : "New", tint: device.isPaired ? Theme.accent : Theme.sky)
            }
            HStack(spacing: 8) {
                PillButton(title: "Connect", systemImage: "bolt.horizontal", disabled: store.connection.connectionState == .connecting) {
                    store.send(.connection(.connect(device)))
                }
                if device.pairingPort != nil || !device.isPaired {
                    PillButton(title: "Pair", systemImage: "link", role: .secondary) {
                        beginPairing(host: device.host, port: device.pairingPort ?? device.port)
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.raised.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func savedRow(_ device: PairedDevice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.cream)
                    Text(savedSubtitle(device))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
                if device.requiresPairing {
                    statusPill("Pair again", tint: Theme.warning)
                }
            }
            HStack(spacing: 8) {
                if let port = device.lastPort, !device.requiresPairing {
                    PillButton(title: "Connect", systemImage: "bolt.horizontal", disabled: store.connection.connectionState == .connecting) {
                        store.send(.connection(.connect(discovered(from: device, port: port))))
                    }
                } else {
                    PillButton(title: "Pair", systemImage: "link") {
                        beginPairing(host: device.lastHost, port: device.lastPort ?? 0)
                    }
                }
                PillButton(title: "Forget", systemImage: "trash", role: .danger) {
                    store.send(.connection(.forgetDevice(device.id)))
                }
            }
        }
        .padding(12)
        .background(Theme.raised.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func field(_ title: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.tertiary)
            TextField(title, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
                .font(.body.monospaced())
                .foregroundStyle(Theme.cream)
                .padding(12)
                .background(Theme.ink.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.headline)
            .foregroundStyle(Theme.cream)
    }

    private func statusPill(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.16), in: Capsule())
    }

    private func connectManually() {
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, let port = LocalizedDecimalInput.positiveUInt16(manualPort) else {
            manualError = "Enter a host and a port from 1 to 65535."
            return
        }
        manualError = nil
        let device = DiscoveredDevice(
            id: "manual-\(UUID().uuidString)",
            name: host,
            host: host,
            port: port,
            isPaired: false,
            pairingPort: nil
        )
        store.send(.connection(.connect(device)))
    }

    private func beginPairing(host: String, port: UInt16) {
        store.send(.pairing(.setHost(host)))
        if port > 0 {
            store.send(.pairing(.setPort(String(port))))
        }
        store.send(.pairing(.setCode("")))
        showPairing = true
    }

    private func discovered(from device: PairedDevice, port: UInt16) -> DiscoveredDevice {
        DiscoveredDevice(
            id: device.guid.isEmpty ? device.id.uuidString : device.guid,
            name: device.displayName,
            host: device.lastHost,
            port: port,
            isPaired: !device.requiresPairing,
            pairingPort: nil
        )
    }

    private func savedSubtitle(_ device: PairedDevice) -> String {
        if let port = device.lastPort {
            return "\(device.lastHost):\(port)"
        }
        return device.lastHost.isEmpty ? "No last address" : device.lastHost
    }
}

private struct PairingSheet: View {
    @Bindable var store: StoreOf<AppFeature>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("On the Android device open Developer options, Wireless debugging, then Pair device with pairing code.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                    labeledField("IP address", text: hostBinding, keyboard: .numbersAndPunctuation)
                    labeledField("Pairing port", text: portBinding, keyboard: .numberPad)
                    labeledField("6-digit code", text: codeBinding, keyboard: .numberPad)
                    ErrorBanner(message: store.pairing.errorMessage)
                    if let name = store.pairing.pairedDeviceName {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.accent)
                            Text("Paired with \(name). You can connect from Nearby or Saved.")
                                .font(.subheadline)
                                .foregroundStyle(Theme.cream)
                        }
                        .padding(12)
                        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    PillButton(
                        title: store.pairing.pairedDeviceName == nil ? "Pair" : "Pair again",
                        systemImage: "link",
                        isLoading: store.pairing.isPairing,
                        disabled: !canPair,
                        expands: true
                    ) {
                        store.send(.pairing(.pair))
                    }
                }
                .padding(20)
            }
            .background(LabBackground().ignoresSafeArea())
            .navigationTitle("Pair device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }

    private var canPair: Bool {
        !store.pairing.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && LocalizedDecimalInput.positiveUInt16(store.pairing.port) != nil
            && store.pairing.code.count == 6
    }

    private var hostBinding: Binding<String> {
        Binding(get: { store.pairing.host }, set: { store.send(.pairing(.setHost($0))) })
    }

    private var portBinding: Binding<String> {
        Binding(get: { store.pairing.port }, set: { store.send(.pairing(.setPort($0))) })
    }

    private var codeBinding: Binding<String> {
        Binding(get: { store.pairing.code }, set: { store.send(.pairing(.setCode($0))) })
    }

    private func labeledField(_ title: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.tertiary)
            TextField(title, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
                .font(.title3.monospacedDigit())
                .foregroundStyle(Theme.cream)
                .padding(14)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.line, lineWidth: 1)
                }
        }
    }
}
