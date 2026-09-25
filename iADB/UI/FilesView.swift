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
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) { pendingDelete = entry }
                                .disabled(!isConnected)
                            Button("Rename") { renameDraft = RenameDraft(entry: entry, name: entry.name) }
                                .tint(Theme.sky)
                                .disabled(!isConnected)
                        }
                        .swipeActions(edge: .leading) {
                            if !entry.isDirectory {
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
            "Delete \(pendingDelete?.name ?? "this item")?",
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
        VStack(alignment: .leading, spacing: 10) {
            ErrorBanner(message: localError ?? store.files.errorMessage)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    pathButton("/", path: "/")
                    ForEach(breadcrumbs, id: \.path) { crumb in
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiary)
                        pathButton(crumb.name, path: crumb.path)
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(shortcuts, id: \.self) { path in
                        Button(path) { store.send(.files(.load(path))) }
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.sky)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Theme.panel, in: Capsule())
                            .disabled(!isConnected)
                    }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary)
                TextField("Filter names", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(Theme.cream)
            }
            .padding(12)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack(spacing: 8) {
                PillButton(title: "Up", systemImage: "arrow.up", role: .secondary, disabled: !isConnected || store.files.currentPath == "/") {
                    store.send(.files(.up))
                }
                PillButton(title: "Folder", systemImage: "folder.badge.plus", role: .secondary, disabled: !isConnected || store.files.isWorking) {
                    showNewFolder = true
                }
                PillButton(title: "File", systemImage: "doc.badge.plus", role: .secondary, disabled: !isConnected || store.files.isWorking) {
                    showNewFile = true
                }
                PillButton(title: "Upload", systemImage: "square.and.arrow.up", disabled: !isConnected || store.files.isWorking, expands: true) {
                    showImporter = true
                }
            }
            if store.files.isLoading || store.files.isWorking {
                ProgressView(store.files.isLoading ? "Reading directory" : "Working")
                    .controlSize(.small)
                    .tint(Theme.accent)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
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
            .font(.caption.weight(.semibold).monospaced())
            .foregroundStyle(path == store.files.currentPath ? Theme.accentInk : Theme.cream)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(path == store.files.currentPath ? Theme.accent : Theme.raised, in: Capsule())
            .disabled(!isConnected)
    }

    private func fileRow(_ entry: FileEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isSymlink ? "link" : (entry.isDirectory ? "folder.fill" : "doc.fill"))
                .foregroundStyle(entry.isDirectory ? Theme.sky : Theme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.cream)
                    .lineLimit(1)
                Text(meta(entry))
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if entry.isNavigableDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private func meta(_ entry: FileEntry) -> String {
        var pieces = [entry.permissions, entry.size, entry.date, entry.time].filter { !$0.isEmpty }
        if let target = entry.symlinkTarget, !target.isEmpty {
            pieces.append("→ \(target)")
        }
        return pieces.joined(separator: "  ")
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
                TextField(title, text: $value)
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
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirm) {
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
