//
//  MediaCardPanelManager.swift
//  leanring-buddy
//
//  A small clickable card the buddy holds up next to itself: a paper (title,
//  source, link), an image preview, or a video thumbnail. The main overlay is
//  click-through, so the card is its own non-activating panel positioned near
//  the pointer. Clicking opens the link; it fades after a while or on the next
//  hotkey press.
//

import AppKit
import Combine
import SwiftUI

struct MediaCard: Identifiable, Equatable {
    enum Kind: String {
        case paper
        case image
        case video
        case link
    }
    let id = UUID()
    let kind: Kind
    let title: String
    let subtitle: String
    let url: URL
    let imageURL: URL?

    /// YouTube links get a thumbnail for free.
    static func youtubeThumbnail(for url: URL) -> URL? {
        let host = url.host ?? ""
        var videoID: String?
        if host.contains("youtu.be") {
            videoID = url.pathComponents.dropFirst().first
        } else if host.contains("youtube.com"),
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            videoID = items.first { $0.name == "v" }?.value
        }
        guard let videoID else { return nil }
        return URL(string: "https://img.youtube.com/vi/\(videoID)/hqdefault.jpg")
    }
}

private final class MediaCardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class MediaCardModel: ObservableObject {
    @Published var card: MediaCard?
}

@MainActor
final class MediaCardPanelManager {
    private let model = MediaCardModel()
    private var panel: MediaCardPanel?
    private var hideTask: Task<Void, Never>?
    private static let cardWidth: CGFloat = 300

    /// Shows a card near a global AppKit point (usually the buddy's position).
    func show(_ card: MediaCard, nearGlobalPoint anchor: CGPoint, autoHideAfterSeconds: TimeInterval = 40) {
        hideTask?.cancel()
        if panel == nil { createPanel() }
        model.card = card
        guard let panel else { return }

        panel.layoutIfNeeded()
        let fittingHeight = max(panel.contentView?.fittingSize.height ?? 120, 80)
        var origin = CGPoint(x: anchor.x + 52, y: anchor.y - fittingHeight - 12)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) {
            let visible = screen.visibleFrame
            if origin.x + Self.cardWidth > visible.maxX - 12 { origin.x = anchor.x - 52 - Self.cardWidth }
            if origin.y < visible.minY + 12 { origin.y = anchor.y + 40 }
            origin.x = max(visible.minX + 12, min(origin.x, visible.maxX - Self.cardWidth - 12))
            origin.y = max(visible.minY + 12, min(origin.y, visible.maxY - fittingHeight - 12))
        }
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: Self.cardWidth, height: fittingHeight), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().alphaValue = 1
        }
        print("🖼️ media card: \(card.kind.rawValue) \"\(card.title.prefix(60))\" → \(card.url.absoluteString)")

        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(autoHideAfterSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.panel?.orderOut(nil)
                self?.model.card = nil
            }
        })
    }

    private func createPanel() {
        let hosting = NSHostingView(rootView: MediaCardView(model: model, onOpen: { [weak self] url in
            NSWorkspace.shared.open(url)
            self?.hide()
        }))
        hosting.frame = NSRect(x: 0, y: 0, width: Self.cardWidth, height: 120)
        let cardPanel = MediaCardPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        cardPanel.level = .statusBar
        cardPanel.isOpaque = false
        cardPanel.backgroundColor = .clear
        cardPanel.hasShadow = true
        cardPanel.hidesOnDeactivate = false
        cardPanel.isExcludedFromWindowsMenu = true
        cardPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        cardPanel.contentView = hosting
        panel = cardPanel
    }
}

private struct MediaCardView: View {
    @ObservedObject private var octoAppearance = OctoAppearance.shared
    @ObservedObject var model: MediaCardModel
    let onOpen: (URL) -> Void
    @State private var isHovering = false

    var body: some View {
        if let card = model.card {
            Button(action: { onOpen(card.url) }) {
                VStack(alignment: .leading, spacing: 0) {
                    if let imageURL = card.imageURL ?? (card.kind == .video ? MediaCard.youtubeThumbnail(for: card.url) : nil) {
                        ZStack {
                            AsyncImage(url: imageURL) { phase in
                                if let image = phase.image {
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Color.white.opacity(0.06)
                                }
                            }
                            .frame(width: 300, height: 150)
                            .clipped()
                            if card.kind == .video {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 34))
                                    .foregroundColor(.white.opacity(0.9))
                                    .shadow(radius: 6)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Image(systemName: iconName(for: card.kind))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(DS.Colors.overlayCursorBlue)
                            Text(card.kind.rawValue.uppercased())
                                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                .foregroundColor(DS.Colors.overlayCursorBlue)
                                .tracking(0.6)
                            Spacer()
                            Text(isHovering ? "open ↗" : (card.url.host ?? ""))
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.45))
                                .lineLimit(1)
                        }
                        Text(card.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        if !card.subtitle.isEmpty {
                            Text(card.subtitle)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.6))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(12)
                }
                .frame(width: 300, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.9))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DS.Colors.overlayCursorBlue.opacity(isHovering ? 0.9 : 0.5), lineWidth: 1))
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .scaleEffect(isHovering ? 1.02 : 1)
                .animation(.easeOut(duration: 0.15), value: isHovering)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .onHover { isHovering = $0 }
        }
    }

    private func iconName(for kind: MediaCard.Kind) -> String {
        switch kind {
        case .paper: return "doc.text"
        case .image: return "photo"
        case .video: return "play.rectangle"
        case .link: return "link"
        }
    }
}
