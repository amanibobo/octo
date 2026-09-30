//
//  NotchStyle.swift
//  leanring-buddy
//
//  Shared pieces for the island's inner pages (settings, context): a page
//  header with a back button, section cards, toggle and info rows, pill
//  buttons. Keeps the pages visually consistent with the main card.
//

import SwiftUI

struct NotchPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let onBack: () -> Void
    @ViewBuilder let trailing: () -> Trailing

    init(title: String, subtitle: String? = nil, onBack: @escaping () -> Void, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.onBack = onBack
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))
                    .frame(width: 26, height: 26)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                            .overlay(Circle().stroke(Color.white.opacity(0.06), lineWidth: 1))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Back")
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
            Spacer()
            trailing()
        }
    }
}

/// A titled group with a subtle card background.
struct NotchSectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.overlayCursorBlue)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.45))
                    .tracking(0.8)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
        )
    }
}

struct NotchToggleRow: View {
    let title: String
    let detail: String
    let isOn: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.42))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { isOn }, set: onChange))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DS.Colors.overlayCursorBlue)
                .scaleEffect(0.78)
                .pointerCursor()
        }
    }
}

struct NotchInfoRow: View {
    let title: String
    let value: String
    var isBad: Bool = false
    var showsStatusDot: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(.white.opacity(0.92))
            Spacer()
            if showsStatusDot {
                Circle()
                    .fill(isBad ? Color(red: 0.95, green: 0.35, blue: 0.3) : DS.Colors.overlayCursorBlue)
                    .frame(width: 6, height: 6)
                    .shadow(color: (isBad ? Color.red : DS.Colors.overlayCursorBlue).opacity(0.7), radius: 3)
            }
            Text(value)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(isBad ? Color(red: 0.95, green: 0.45, blue: 0.4) : .white.opacity(0.55))
                .lineLimit(1)
        }
    }
}

/// Small capsule button; `isProminent` fills it green.
struct NotchPillButton: View {
    let title: String
    var systemImage: String? = nil
    var isProminent: Bool = false
    var isSelected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 10.5, weight: .semibold))
                }
                Text(title).font(.system(size: 11.5, weight: isSelected || isProminent ? .semibold : .medium, design: .rounded))
            }
            .foregroundColor(isSelected || isProminent ? .black : .white.opacity(0.8))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected || isProminent ? AnyShapeStyle(LinearGradient(colors: [DS.Colors.green400, DS.Colors.green500], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color.white.opacity(0.08)))
                    .overlay(Capsule().stroke(Color.white.opacity(isSelected || isProminent ? 0 : 0.07), lineWidth: 1))
            )
            .shadow(color: isSelected || isProminent ? DS.Colors.overlayCursorBlue.opacity(0.35) : .clear, radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

// MARK: - Card width (compact vs. large island)

private struct NotchCardWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 440
}

extension EnvironmentValues {
    /// Width of the island's card; pages size themselves to it.
    var notchCardWidth: CGFloat {
        get { self[NotchCardWidthKey.self] }
        set { self[NotchCardWidthKey.self] = newValue }
    }
}

// MARK: - Info tip

/// A small "i" that opens a short explanation while hovered.
struct NotchInfoTip: View {
    let text: String
    var width: CGFloat = 230
    @State private var isHovering = false

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white.opacity(isHovering ? 0.95 : 0.4))
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .overlay(alignment: .topLeading) {
                if isHovering {
                    Text(text)
                        .font(.system(size: 11.5))
                        .foregroundColor(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: width, alignment: .leading)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(white: 0.12))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
                                .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                        )
                        .offset(x: -6, y: 22)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
                        .zIndex(100)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .zIndex(isHovering ? 100 : 0)
    }
}

/// Square icon button used in the card's header and footer.
struct NotchIconButton: View {
    let systemImage: String
    var isActive: Bool = false
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isActive ? DS.Colors.overlayCursorBlue : .white.opacity(0.65))
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(isActive ? 0.12 : 0.08))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(help)
    }
}
