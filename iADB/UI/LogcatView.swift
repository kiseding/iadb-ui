import ComposableArchitecture
import SwiftUI

struct LogcatView: View {
    @Bindable var store: StoreOf<AppFeature>
    @State private var query = ""
    @State private var levels = Set(LogEntry.LogLevel.allCases)
    @State private var follow = true

    var body: some View {
        VStack(spacing: 0) {
            controls
            if visibleEntries.isEmpty {
                LabEmpty(
                    symbol: "text.alignleft",
                    title: store.logcat.entries.isEmpty ? "Log is quiet" : "Filter hid every line",
                    message: store.logcat.isCapturing
                        ? "Lines show up as logcat writes them. Threadtime format is parsed into level, tag, and message."
                        : "Start capture after the device is connected."
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(visibleEntries) { entry in
                                logRow(entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .onChange(of: visibleEntries.last?.id) { _, id in
                        guard follow, let id else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .navigationTitle("Logcat")
        .labScreen()
        .connectionToolbar(store)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ErrorBanner(message: store.logcat.errorMessage)
            HStack(spacing: 8) {
                PillButton(
                    title: store.logcat.isCapturing ? "Stop" : "Start",
                    systemImage: store.logcat.isCapturing ? "stop.fill" : "play.fill",
                    role: store.logcat.isCapturing ? .danger : .primary,
                    disabled: !store.logcat.isConnected && !store.logcat.isCapturing
                ) {
                    store.send(store.logcat.isCapturing ? .logcat(.stop) : .logcat(.start))
                }
                PillButton(title: "Clear", systemImage: "trash", role: .secondary, disabled: store.logcat.entries.isEmpty) {
                    store.send(.logcat(.clear))
                }
                Spacer()
                Button {
                    follow.toggle()
                } label: {
                    Label(follow ? "Follow" : "Paused", systemImage: follow ? "arrow.down.to.line" : "pause")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(follow ? Theme.accent : Theme.secondary)
                }
                .buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(LogEntry.LogLevel.allCases, id: \.self) { level in
                        let on = levels.contains(level)
                        Button(level.rawValue) {
                            if on { levels.remove(level) } else { levels.insert(level) }
                        }
                        .font(.caption.weight(.bold).monospaced())
                        .foregroundStyle(on ? Theme.accentInk : levelColor(level))
                        .frame(width: 28, height: 28)
                        .background(on ? levelColor(level) : Theme.panel, in: Circle())
                    }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary)
                TextField("Filter tag or message", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(Theme.cream)
                Text("\(visibleEntries.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(10)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var visibleEntries: [LogEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.logcat.entries.filter { entry in
            guard levels.contains(entry.level) else { return false }
            guard !needle.isEmpty else { return true }
            return entry.tag.localizedCaseInsensitiveContains(needle)
                || entry.message.localizedCaseInsensitiveContains(needle)
                || entry.pid.contains(needle)
        }
    }

    private func logRow(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.level.rawValue)
                .font(.caption2.weight(.black).monospaced())
                .foregroundStyle(Theme.accentInk)
                .frame(width: 18, height: 18)
                .background(levelColor(entry.level), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.tag.isEmpty ? "log" : entry.tag)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.sky)
                        .lineLimit(1)
                    Text(entry.timestamp)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }
                Text(entry.message.isEmpty ? " " : entry.message)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.cream)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func levelColor(_ level: LogEntry.LogLevel) -> Color {
        switch level {
        case .verbose, .silent, .unknown: Theme.tertiary
        case .debug: Theme.info
        case .info: Theme.accent
        case .warning: Theme.warning
        case .error, .fatal: Theme.danger
        }
    }
}
