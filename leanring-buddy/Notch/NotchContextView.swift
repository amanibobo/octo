//
//  NotchContextView.swift
//  leanring-buddy
//
//  Context page inside the island: what the user has pinned (notes, links,
//  images), a field to add more, paste and file buttons, and drag-and-drop.
//

import SwiftUI
import UniformTypeIdentifiers

struct NotchContextView: View {
    @ObservedObject var userContextStore: UserContextStore
    let onBack: () -> Void

    @State private var draftInput = ""
    @State private var isDropTargeted = false
    @FocusState private var isInputFocused: Bool

    private let horizontalPadding: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NotchPageHeader(title: "Context", subtitle: "What Octo keeps in mind for every answer", onBack: onBack) {
                if !userContextStore.items.isEmpty {
                    NotchPillButton(title: "Clear all", systemImage: "trash") { userContextStore.clear() }
                }
            }
            .padding(.top, 14)

            if userContextStore.items.isEmpty {
                emptyState
            } else {
                itemList
            }

            NotchSectionCard(title: "Add", systemImage: "plus") {
                VStack(alignment: .leading, spacing: 10) {
                    inputRow
                    HStack(spacing: 8) {
                        NotchPillButton(title: "Paste", systemImage: "doc.on.clipboard") {
                            if !userContextStore.addFromPasteboard() { NSSound.beep() }
                        }
                        NotchPillButton(title: "Image…", systemImage: "photo") { chooseImageFiles() }
                        if userContextStore.isFetchingLink {
                            ProgressView().controlSize(.small).padding(.leading, 2)
                            Text("fetching link…")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.4))
                        }
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.doc")
                                .font(.system(size: 10, weight: .medium))
                            Text("or drop files here")
                                .font(.system(size: 11))
                        }
                        .foregroundColor(isDropTargeted ? DS.Colors.overlayCursorBlue : .white.opacity(0.35))
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, horizontalPadding)
        .frame(width: NotchIslandState.expandedWidth)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(DS.Colors.overlayCursorBlue.opacity(isDropTargeted ? 0.9 : 0), lineWidth: 2)
                .padding(8)
        )
        .onDrop(of: [.fileURL, .url, .image, .plainText], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Pieces

    private var emptyState: some View {
        HStack(spacing: 12) {
            Image(systemName: "paperclip.circle.fill")
                .font(.system(size: 26))
                .foregroundColor(DS.Colors.overlayCursorBlue.opacity(0.85))
            VStack(alignment: .leading, spacing: 2) {
                Text("Nothing pinned yet")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                Text("Pin a note, a link or an image about what you're working on. Octo folds it into every answer.")
                    .font(.system(size: 11.5))
                    .foregroundColor(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4])).foregroundColor(.white.opacity(0.14)))
        )
    }

    private var itemList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 4) {
                ForEach(userContextStore.items) { item in
                    contextRow(item)
                }
            }
        }
        .frame(maxHeight: 196)
    }

    private func contextRow(_ item: UserContextItem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            thumbnail(for: item)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)
                Text(subtitle(for: item))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.42))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(item.kind.rawValue)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.overlayCursorBlue)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(DS.Colors.overlayCursorBlue.opacity(0.14)))
            Button(action: { userContextStore.remove(item) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.55))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Remove")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
        )
    }

    @ViewBuilder
    private func thumbnail(for item: UserContextItem) -> some View {
        if item.kind == .image, let data = userContextStore.imageData(for: item), let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            Image(systemName: item.kind == .link ? "link" : "text.alignleft")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.overlayCursorBlue)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(DS.Colors.overlayCursorBlue.opacity(0.12)))
        }
    }

    private func subtitle(for item: UserContextItem) -> String {
        switch item.kind {
        case .text: return item.body == item.title ? "note" : String(item.body.prefix(80))
        case .link: return item.urlString ?? "link"
        case .image: return "image"
        }
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField("Add a note or paste a link…", text: $draftInput)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundColor(.white)
                .focused($isInputFocused)
                .onSubmit { submitDraft() }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.white.opacity(isInputFocused ? 0.18 : 0.08), lineWidth: 1))
                )
            NotchPillButton(title: "Add", isProminent: !draftInput.isEmpty) { submitDraft() }
                .disabled(draftInput.isEmpty)
                .opacity(draftInput.isEmpty ? 0.6 : 1)
        }
    }

    // MARK: - Actions

    private func submitDraft() {
        let input = draftInput
        draftInput = ""
        userContextStore.add(fromInput: input)
    }

    /// The island is a non-activating panel, so the app is activated for the
    /// duration of the file dialog; the island stays open because the inner
    /// pages do not collapse on hover-out.
    private func chooseImageFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.image]
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        openPanel.level = .floating
        openPanel.begin { response in
            guard response == .OK else { return }
            for fileURL in openPanel.urls {
                userContextStore.addImageFile(at: fileURL)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let fileURL = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        if UTType(filenameExtension: fileURL.pathExtension)?.conforms(to: .image) == true {
                            userContextStore.addImageFile(at: fileURL)
                        } else if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
                            userContextStore.addText("\(fileURL.lastPathComponent):\n\(text.prefix(4000))")
                        }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.url.identifier) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in await userContextStore.addLink(url) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let image = NSImage(data: data) else { return }
                    Task { @MainActor in userContextStore.addImage(image, title: "Dropped image") }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
                    guard let data, let text = String(data: data, encoding: .utf8) else { return }
                    Task { @MainActor in userContextStore.add(fromInput: text) }
                }
            }
        }
        return handled
    }
}
