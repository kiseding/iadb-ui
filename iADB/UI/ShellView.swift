import ComposableArchitecture
import SwiftUI

struct ShellView: View {
    @Bindable var store: StoreOf<AppFeature>
    @State private var showHistory = false

    private let suggestions = ["getprop ro.product.model", "wm size", "dumpsys battery", "ip route", "df -h"]

    var body: some View {
        VStack(spacing: 0) {
            terminal
            composer
        }
        .navigationTitle("Shell")
        .labScreen()
        .connectionToolbar(store)
        .sheet(isPresented: $showHistory) { historySheet }
    }

    private var terminal: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Circle().fill(Theme.danger).frame(width: 8, height: 8)
                    Circle().fill(Theme.warning).frame(width: 8, height: 8)
                    Circle().fill(Theme.accent).frame(width: 8, height: 8)
                    Text("shell,v2")
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.tertiary)
                    Spacer()
                    if let code = store.shell.exitCode {
                        Text("exit \(Int(code))")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(code == 0 ? Theme.accent : Theme.danger)
                    } else if store.shell.isExecuting {
                        ProgressView().controlSize(.small).tint(Theme.accent)
                    }
                }
                ErrorBanner(message: store.shell.errorMessage)
                if !store.shell.command.isEmpty && (store.shell.isExecuting || store.shell.exitCode != nil || !store.shell.stdout.isEmpty) {
                    Text("$ \(store.shell.command)")
                        .font(.callout.monospaced().weight(.semibold))
                        .foregroundStyle(Theme.sky)
                        .textSelection(.enabled)
                }
                if store.shell.stdout.isEmpty && store.shell.stderr.isEmpty && !store.shell.isExecuting {
                    Text("Output streams here. History is kept on this iPhone, per command.")
                        .font(.footnote)
                        .foregroundStyle(Theme.tertiary)
                }
                if !store.shell.stdout.isEmpty {
                    Text(tailText(store.shell.stdout, maxCharacters: 80_000))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.cream)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !store.shell.stderr.isEmpty {
                    Text(tailText(store.shell.stderr, maxCharacters: 40_000))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.danger)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
        .background(Theme.ink.opacity(0.45))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) { store.send(.shell(.setCommand(suggestion))) }
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.sky)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Theme.raised, in: Capsule())
                    }
                }
            }
            HStack(spacing: 8) {
                Text("$")
                    .font(.body.monospaced().bold())
                    .foregroundStyle(Theme.accent)
                TextField("command", text: commandBinding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .foregroundStyle(Theme.cream)
                    .submitLabel(.send)
                    .onSubmit(execute)
                if store.shell.isExecuting {
                    Button("Stop", systemImage: "stop.fill") { store.send(.shell(.cancel)) }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Theme.danger)
                } else {
                    Button("Run", systemImage: "return") { execute() }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(canRun ? Theme.accent : Theme.tertiary)
                        .disabled(!canRun)
                }
                Button("History", systemImage: "clock.arrow.circlepath") { showHistory = true }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Theme.sky)
            }
            .padding(12)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1)
            }
        }
        .padding(12)
        .background(Theme.ink.opacity(0.92))
    }

    private var historySheet: some View {
        NavigationStack {
            Group {
                if store.shell.history.isEmpty {
                    LabEmpty(symbol: "clock", title: "No commands yet", message: "Finished commands are stored on this iPhone.")
                } else {
                    List {
                        ForEach(store.shell.history) { entry in
                            Button {
                                store.send(.shell(.setCommand(entry.command)))
                                showHistory = false
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(entry.command)
                                            .font(.subheadline.monospaced().weight(.semibold))
                                            .foregroundStyle(Theme.cream)
                                            .lineLimit(2)
                                        Spacer()
                                        if let code = entry.exitCode {
                                            Text("\(code)")
                                                .font(.caption.monospacedDigit().bold())
                                                .foregroundStyle(entry.isError ? Theme.danger : Theme.accent)
                                        }
                                    }
                                    Text(entry.timestamp, style: .relative)
                                        .font(.caption2)
                                        .foregroundStyle(Theme.tertiary)
                                }
                            }
                            .listRowBackground(Theme.panel)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(LabBackground().ignoresSafeArea())
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { showHistory = false } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Clear", role: .destructive) { store.send(.shell(.clearHistory)) }
                        .disabled(store.shell.history.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var canRun: Bool {
        store.shell.isConnected && !store.shell.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var commandBinding: Binding<String> {
        Binding(get: { store.shell.command }, set: { store.send(.shell(.setCommand($0))) })
    }

    private func execute() {
        guard canRun else { return }
        store.send(.shell(.execute))
    }
}
