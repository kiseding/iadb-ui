import ComposableArchitecture
import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
    @Bindable var store: StoreOf<AppFeature>
    @State private var query = ""
    @State private var localError: String?
    @State private var showImporter = false
    @State private var showNewFolder = false
    @State private var folderName = ""
    @State private var showNewFile = false
    @State private var newFileName = ""
    @State private var newFileBody = ""
    @State private var renameDraft: RenameDraft?
    @State private var moveDraft: MoveDraft?
    @State private var pendingDelete: FileEntry?
    @State private var pendingDownload: URL?
    @State private var shareFile: SharedFile?

    private let shortcuts = ["/sdcard", "/sdcard/Download", "/sdcard/DCIM", "/data/local/tmp"]

    var body: some View {
        VStack(spacing: 0) {
            header
            if visibleEntries.isEmpty && !store.files.isLoading {
                LabEmpty(
                    symbol: "folder",
                    title: isConnected ? "Empty directory" : "No file session",
                    message: isConnected
                        ? "This folder has nothing you can see, or the filter hid every name."
                        : "Connect a device to browse, upload, and pull files."
                )
            } else {
                List {
                    ForEach(visibleEntries) { entry in
                        Button {
                            if entry.isNavigableDirectory {
                                store.send(.files(.open(entry)))
                            }
                        } label: {
                            fileRow(entry)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.panel)
                        .listRowSeparatorTint(Theme.line)
                        .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) { pendingDelete = entry }
                                .disabled(!isConnected)
                            Button("Rename") { renameDraft = RenameDraft(entry: entry, name: entry.name) }
                                .tint(Theme.sky)
                                .disabled(!isConnected)
                        }
                        .swipeActions(edge: .leading) {
                            if entry.isAPK {
                                Button("Install") { store.send(.apps(.installRemote(entry.fullPath))) }
                                    .tint(Theme.accent)
                                    .disabled(!isConnected || store.apps.isInstalling)
                            } else if !entry.isDirectory {
                                Button("Save") { download(entry) }
                                    .tint(Theme.accent)
                                    .disabled(!isConnected || store.files.isWorking)
                            }
                            Button("Move") {
                                moveDraft = MoveDraft(entry: entry, destination: entry.fullPath)
                            }
                            .tint(Theme.warning)
                            .disabled(!isConnected)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Files")
        .labScreen()
        .connectionToolbar(store)
        .refreshable {
            guard isConnected else { return }
            store.send(.files(.load()))
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            upload(result)
        }
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Name", text: $folderName)
            Button("Create") {
                store.send(.files(.createDirectory(folderName)))
                folderName = ""
            }
            Button("Cancel", role: .cancel) { folderName = "" }
        }
        .sheet(isPresented: $showNewFile) { newFileSheet }
        .sheet(item: $renameDraft) { draft in
            nameSheet(title: "Rename", name: draft.name, confirm: "Rename") { name in
                store.send(.files(.rename(draft.entry, name)))
            }
        }
        .sheet(item: $moveDraft) { draft in
            nameSheet(title: "Move to", name: draft.destination, confirm: "Move") { destination in
                store.send(.files(.move(draft.entry, destination)))
            }
        }
        .sheet(item: $shareFile) { file in
            ShareLink(item: file.url) {
                Label("Share \(file.url.lastPathComponent)", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .presentationDetents([.medium])
        }
        .confirmationDialog(
            Text("Delete \(pendingDelete?.name ?? String(localized: "this item"))?"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { entry in
            Button("Delete", role: .destructive) { store.send(.files(.delete(entry))) }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text(entry.fullPath)
        }
        .onChange(of: store.files.isWorking) { wasWorking, isWorking in
            guard wasWorking, !isWorking, let url = pendingDownload else { return }
            pendingDownload = nil
            if store.files.errorMessage == nil {
                shareFile = SharedFile(url: url)
            }
        }
    }

    private var isConnected: Bool { store.connection.connectionState == .connected }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            ErrorBanner(message: localError ?? store.files.errorMessage)
            HStack(spacing: 8) {
                Button {
                    store.send(.files(.up))
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(store.files.currentPath == "/" ? Theme.tertiary : Theme.cream)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .disabled(!isConnected || store.files.currentPath == "/")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        pathButton("/", path: "/")
                        ForEach(breadcrumbs, id: \.path) { crumb in
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Theme.tertiary)
                            pathButton(crumb.name, path: crumb.path)
                        }
                    }
                }

                Menu {
                    ForEach(shortcuts, id: \.self) { path in
                        Button(path) { store.send(.files(.load(path))) }
                    }
                } label: {
                    Image(systemName: "bookmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .foregroundStyle(Theme.cream)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .disabled(!isConnected)
            }

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary)
                    TextField("Filter names", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(Theme.cream)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                fileAction("folder.badge.plus", disabled: !isConnected || store.files.isWorking) { showNewFolder = true }
                fileAction("doc.badge.plus", disabled: !isConnected || store.files.isWorking) { showNewFile = true }
                fileAction("square.and.arrow.up", disabled: !isConnected || store.files.isWorking) { showImporter = true }
            }

            if store.files.isLoading || store.files.isWorking {
                ProgressView(store.files.isLoading ? "Reading directory" : "Working")
                    .controlSize(.small)
                    .tint(Theme.accent)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private func fileAction(_ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 32, height: 32)
                .foregroundStyle(disabled ? Theme.tertiary : Theme.accentInk)
                .background(disabled ? Theme.panel : Theme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private var breadcrumbs: [(name: String, path: String)] {
        let parts = store.files.currentPath.split(separator: "/").map(String.init)
        var path = ""
        return parts.map { part in
            path += "/\(part)"
            return (part, path)
        }
    }

    private var visibleEntries: [FileEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return store.files.entries }
        return store.files.entries.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    private func pathButton(_ title: String, path: String) -> some View {
        Button(title) { store.send(.files(.load(path))) }
            .font(.subheadline.weight(path == store.files.currentPath ? .semibold : .regular))
            .foregroundStyle(path == store.files.currentPath ? Theme.cream : Theme.secondary)
            .lineLimit(1)
            .disabled(!isConnected)
    }

    private func fileRow(_ entry: FileEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isSymlink ? "link" : (entry.isDirectory ? "folder.fill" : "doc"))
                .font(.body)
                .foregroundStyle(entry.isDirectory ? Theme.sky : Theme.secondary)
                .frame(width: 28, height: 28)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.body)
                    .foregroundStyle(Theme.cream)
                    .lineLimit(1)
                Text(meta(entry))
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if entry.isAPK {
                Button {
                    store.send(.apps(.installRemote(entry.fullPath)))
                } label: {
                    if store.apps.isInstalling {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Install")
                            .font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(!isConnected || store.apps.isInstalling)
            } else if entry.isNavigableDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }

    private func meta(_ entry: FileEntry) -> String {
        if let target = entry.symlinkTarget, !target.isEmpty {
            return "→ \(target)"
        }
        if entry.isDirectory {
            return entry.date
        }
        return [entry.size, entry.date].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var newFileSheet: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextField("File name", text: $newFileName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                TextEditor(text: $newFileBody)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(16)
            .background(LabBackground().ignoresSafeArea())
            .navigationTitle("New file")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showNewFile = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let data = Data(newFileBody.utf8)
                        store.send(.files(.createFile(name: newFileName, data: data)))
                        newFileName = ""
                        newFileBody = ""
                        showNewFile = false
                    }
                    .disabled(newFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func nameSheet(title: String, name: String, confirm: String, onConfirm: @escaping (String) -> Void) -> some View {
        NamePrompt(title: title, initial: name, confirm: confirm, onConfirm: onConfirm)
    }

    private func upload(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            localError = error.localizedDescription
        case .success(let url):
            do {
                let staged = try ImportStaging.copySecurityScopedFile(url)
                localError = nil
                let name = url.lastPathComponent.isEmpty ? "upload.bin" : url.lastPathComponent
                store.send(.files(.upload(localURL: staged, remoteName: name)))
            } catch {
                localError = error.localizedDescription
            }
        }
    }

    private func download(_ entry: FileEntry) {
        do {
            let destination = try ImportStaging.downloadDestination(named: entry.name)
            localError = nil
            pendingDownload = destination
            store.send(.files(.download(entry, destination)))
        } catch {
            localError = error.localizedDescription
        }
    }
}

private struct RenameDraft: Identifiable {
    let entry: FileEntry
    var name: String
    var id: UUID { entry.id }
}

private struct MoveDraft: Identifiable {
    let entry: FileEntry
    var destination: String
    var id: UUID { entry.id }
}

private struct NamePrompt: View {
    let title: String
    let confirm: String
    let onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value: String

    init(title: String, initial: String, confirm: String, onConfirm: @escaping (String) -> Void) {
        self.title = title
        self.confirm = confirm
        self.onConfirm = onConfirm
        _value = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            VStack {
                TextField(title.ui, text: $value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .foregroundStyle(Theme.cream)
                    .padding(14)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Spacer()
            }
            .padding(16)
            .background(LabBackground().ignoresSafeArea())
            .navigationTitle(Text(title.ui))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirm.ui) {
                        onConfirm(value)
                        dismiss()
                    }
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.height(220)])
    }
}

#Preview("Files") {
    NavigationStack {
        FilesView(store: Store(initialState: AppFeature.State()) {
            AppFeature()
        })
    }
}
