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

    private let horizontalPadding: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 14)
                .padding(.bottom, 12)

            if userContextStore.items.isEmpty {
                Text("Pin what you're working on: a note, a link, or an image. Octo keeps it in mind for every answer.")
                    .font(.system(size: 12.5))
                    .foregroundColor(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.bottom, 14)
            } else {
                itemList
                    .padding(.horizontal, horizontalPadding - 8)
                    .padding(.bottom, 10)
            }

            inputRow
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, 10)

            actionRow
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, 16)
        }
        .frame(width: NotchIslandState.expandedWidth)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(DS.Colors.overlayCursorBlue.opacity(isDropTargeted ? 0.9 : 0), lineWidth: 2)
                .padding(6)
        )
        .onDrop(of: [.fileURL, .url, .image, .plainText], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            Text("Context")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            if !userContextStore.items.isEmpty {
                Text("\(userContextStore.items.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.black)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(DS.Colors.overlayCursorBlue))
            }
            Spacer()
            if !userContextStore.items.isEmpty {
                Button("Clear all") { userContextStore.clear() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .pointerCursor()
            }
        }
    }

    private var itemList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                ForEach(userContextStore.items) { item in
                    contextRow(item)
                }
            }
        }
        .frame(maxHeight: 190)
    }

    private func contextRow(_ item: UserContextItem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            thumbnail(for: item)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                Text(subtitle(for: item))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action: { userContextStore.remove(item) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Remove")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
    }

    @ViewBuilder
    private func thumbnail(for item: UserContextItem) -> some View {
        if item.kind == .image, let data = userContextStore.imageData(for: item), let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: item.kind == .link ? "link" : "text.alignleft")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.overlayCursorBlue)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.06)))
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
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
            Button(action: submitDraft) {
                Text("Add")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(draftInput.isEmpty ? .white.opacity(0.35) : .black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(draftInput.isEmpty ? Color.white.opacity(0.08) : DS.Colors.overlayCursorBlue))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(draftInput.isEmpty)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            actionButton(icon: "doc.on.clipboard", label: "Paste") {
                if !userContextStore.addFromPasteboard() { NSSound.beep() }
            }
            actionButton(icon: "photo", label: "Image…") { chooseImageFiles() }
            if userContextStore.isFetchingLink {
                ProgressView().controlSize(.small).padding(.leading, 4)
                Text("fetching link…")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
            Spacer()
            Text("or drop files here")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.35))
        }
    }

    private func actionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .medium))
                Text(label).font(.system(size: 11.5, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.8))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Actions

    private func submitDraft() {
        let input = draftInput
        draftInput = ""
        userContextStore.add(fromInput: input)
    }

    /// The island is a non-activating panel, so the app is activated for the
    /// duration of the file dialog; the island stays open because the settings
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
