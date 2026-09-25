import SwiftUI

enum Theme {
    static let ink = Color(red: 0.055, green: 0.102, blue: 0.165)
    static let panel = Color(red: 0.094, green: 0.153, blue: 0.231)
    static let raised = Color(red: 0.133, green: 0.204, blue: 0.298)
    static let line = Color.white.opacity(0.08)
    static let accent = Color(red: 0.545, green: 0.812, blue: 0.486)
    static let accentInk = Color(red: 0.067, green: 0.145, blue: 0.102)
    static let sky = Color(red: 0.620, green: 0.784, blue: 0.902)
    static let cream = Color(red: 0.965, green: 0.945, blue: 0.910)
    static let secondary = Color(red: 0.965, green: 0.945, blue: 0.910).opacity(0.64)
    static let tertiary = Color(red: 0.965, green: 0.945, blue: 0.910).opacity(0.38)
    static let danger = Color(red: 0.945, green: 0.435, blue: 0.404)
    static let warning = Color(red: 0.965, green: 0.745, blue: 0.365)
    static let info = Color(red: 0.490, green: 0.745, blue: 0.965)
}

struct LabBackground: View {
    var body: some View {
        ZStack {
            Theme.ink
            LinearGradient(
                colors: [Theme.sky.opacity(0.18), .clear, Theme.accent.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Theme.accent.opacity(0.16), .clear],
                center: .topTrailing,
                startRadius: 12,
                endRadius: 480
            )
        }
    }
}

struct LabCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1)
            }
    }
}

struct LabEmpty: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.sky)
                .frame(width: 76, height: 76)
                .background(Theme.raised, in: Circle())
                .overlay { Circle().strokeBorder(Theme.line, lineWidth: 1) }
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.cream)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorBanner: View {
    let message: String?

    var body: some View {
        if let message, !message.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                    .padding(.top, 1)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.cream)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(12)
            .background(Theme.danger.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.danger.opacity(0.38), lineWidth: 1)
            }
        }
    }
}

struct PillButton: View {
    enum Role { case primary, secondary, danger }

    let title: String
    var systemImage: String?
    var role: Role = .primary
    var isLoading = false
    var disabled = false
    var expands = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(foreground)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: expands ? .infinity : nil)
            .background(background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(disabled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isLoading || disabled)
    }

    private var background: Color {
        switch role {
        case .primary: Theme.accent
        case .secondary: Theme.raised
        case .danger: Theme.danger.opacity(0.18)
        }
    }

    private var foreground: Color {
        switch role {
        case .primary: Theme.accentInk
        case .secondary: Theme.cream
        case .danger: Theme.danger
        }
    }
}

struct ConnectionStrip: View {
    let state: ConnectionState
    let device: DiscoveredDevice?

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .shadow(color: color.opacity(0.7), radius: state == .connected ? 6 : 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.cream)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if state == .connecting {
                ProgressView().controlSize(.small).tint(Theme.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.raised.opacity(0.9), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        }
    }

    private var color: Color {
        switch state {
        case .connected: Theme.accent
        case .connecting: Theme.warning
        case .disconnected: Theme.tertiary
        case .error: Theme.danger
        }
    }

    private var title: String {
        switch state {
        case .connected: device?.name.isEmpty == false ? device?.name ?? "Connected" : "Connected"
        case .connecting: "Connecting"
        case .disconnected: "No device"
        case .error: "Connection failed"
        }
    }

    private var subtitle: String {
        switch state {
        case .connected:
            guard let device else { return "Wireless debugging session" }
            return "\(device.host):\(device.port)"
        case .connecting:
            return "Waiting for adbd"
        case .disconnected:
            return "Pair, then connect over Wi-Fi"
        case .error(let message):
            return message
        }
    }
}

extension View {
    func labScreen() -> some View {
        background(LabBackground().ignoresSafeArea())
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(Theme.ink.opacity(0.94), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }

    func readableWidth(_ maxWidth: CGFloat = 880) -> some View {
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}

enum ImportStaging {
    static func copySecurityScopedFile(_ url: URL) throws -> URL {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("iadb-import", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let leaf = url.lastPathComponent.isEmpty ? "import.bin" : url.lastPathComponent
        let destination = folder.appendingPathComponent("\(UUID().uuidString)-\(leaf)")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    static func downloadDestination(named fileName: String) throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let cleaned = fileName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let base = cleaned.isEmpty ? "download" : cleaned
        var candidate = documents.appendingPathComponent(base)
        if FileManager.default.fileExists(atPath: candidate.path) {
            let stem = (base as NSString).deletingPathExtension
            let ext = (base as NSString).pathExtension
            let stamp = Int(Date().timeIntervalSince1970)
            let unique = ext.isEmpty ? "\(stem)-\(stamp)" : "\(stem)-\(stamp).\(ext)"
            candidate = documents.appendingPathComponent(unique)
        }
        return candidate
    }
}

func tailText(_ text: String, maxCharacters: Int) -> String {
    guard text.count > maxCharacters else { return text }
    let start = text.index(text.endIndex, offsetBy: -maxCharacters)
    return "…\n" + String(text[start...])
}

struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}
