import ComposableArchitecture
import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ScreenshotsView: View {
    @Bindable var store: StoreOf<AppFeature>
    @State private var selected: ScreenshotEntry?
    @State private var confirmClear = false

    private let columns = [GridItem(.adaptive(minimum: 148, maximum: 220), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ErrorBanner(message: store.screenshots.errorMessage)
                HStack(spacing: 8) {
                    PillButton(
                        title: "Capture",
                        systemImage: "camera.viewfinder",
                        isLoading: store.screenshots.isCapturing,
                        disabled: !store.screenshots.isConnected,
                        expands: true
                    ) {
                        store.send(.screenshots(.capture))
                    }
                    PillButton(title: "Clear", systemImage: "trash", role: .danger, disabled: store.screenshots.entries.isEmpty) {
                        confirmClear = true
                    }
                }
                if store.screenshots.isLoading && store.screenshots.entries.isEmpty {
                    ProgressView("Loading gallery")
                        .tint(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                } else if store.screenshots.entries.isEmpty {
                    LabEmpty(
                        symbol: "camera.viewfinder",
                        title: "No screenshots",
                        message: "Captures are pulled from the device and kept on this iPhone until you delete them."
                    )
                    .frame(minHeight: 280)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(store.screenshots.entries) { entry in
                            Button { selected = entry } label: {
                                thumbnail(entry)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)
            .readableWidth(1040)
        }
        .navigationTitle("Shots")
        .labScreen()
        .connectionToolbar(store)
        .refreshable { store.send(.screenshots(.load)) }
        .sheet(item: $selected) { entry in
            ScreenshotDetail(entry: entry) {
                store.send(.screenshots(.delete(entry.id)))
                selected = nil
            }
        }
        .confirmationDialog("Delete every saved screenshot?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear gallery", role: .destructive) { store.send(.screenshots(.clear)) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func thumbnailTitle(_ entry: ScreenshotEntry) -> String {
        if let name = entry.deviceName, !name.isEmpty { return name }
        return "Android"
    }

    private func thumbnail(_ entry: ScreenshotEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Theme.raised
                if let image = UIImage(data: entry.data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .frame(height: 210)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1)
            }
            Text(thumbnailTitle(entry))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.cream)
                .lineLimit(1)
            Text(entry.timestamp, style: .relative)
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
        }
    }
}

private struct ScreenshotDetail: View {
    let entry: ScreenshotEntry
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ScrollView {
                    if let image = UIImage(data: entry.data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .padding(.horizontal, 16)
                    }
                }
                HStack {
                    Text("\(entry.pixelWidth)×\(entry.pixelHeight) · \(ByteCountFormatter.string(fromByteCount: Int64(entry.data.count), countStyle: .file))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
            }
            .background(LabBackground().ignoresSafeArea())
            .navigationTitle(entry.deviceName ?? "Screenshot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: PNGPayload(data: entry.data), preview: SharePreview(entry.deviceName ?? "Screenshot")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Delete", systemImage: "trash", role: .destructive) { onDelete() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct PNGPayload: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { payload in
            payload.data
        }
    }
}
