//
//  ThemePickerTiles.swift
//  AgentVisor
//
//  Modern 3-tile theme picker (System / Light / Dark) modeled on
//  Xcode 16's "Themes" preference, VS Code's Settings UI, and
//  macOS System Settings → Appearance. Each tile shows a small
//  visual preview of the actual chrome (titlebar + sidebar + chat
//  bubble) at the picked palette so the user can see what they're
//  picking before committing.
//
//  Why a tile picker (not a Toggle or segmented control):
//  the previous "Light Mode" toggle hid the System option entirely
//  and gave no visual hint of what the toggle would produce. Modern
//  editors all use a tile-based picker for theme selection because
//  a thumbnail of the rendered UI conveys more than the word "Light"
//  ever could.
//

import SwiftUI

struct ThemePickerTiles: View {
    @ObservedObject var selector: AppearanceSelector

    var body: some View {
        HStack(spacing: 12) {
            ForEach(AppearanceMode.allCases, id: \.self) { mode in
                ThemeTile(
                    mode: mode,
                    isSelected: selector.mode == mode,
                    palette: previewPalette(for: mode)
                ) {
                    selector.setMode(mode)
                }
            }
        }
    }

    /// Concrete palette to render in the tile thumbnail. `.system`
    /// resolves to whatever the OS currently is so the preview always
    /// shows what the user would actually get.
    private func previewPalette(for mode: AppearanceMode) -> CatppuccinPalette {
        switch mode {
        case .light: return .latte
        case .dark:  return .mocha
        case .system:
            switch SystemAppearance.current() {
            case .light: return .latte
            case .dark:  return .mocha
            }
        }
    }
}
private struct ThemeTile: View {
    let mode: AppearanceMode
    let isSelected: Bool
    let palette: CatppuccinPalette
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                preview
                    .frame(height: 72)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(borderColor, lineWidth: isSelected ? 2 : 1)
                    )

                HStack(spacing: 6) {
                    if mode == .system {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    }
                    Text(mode.displayLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(tileBackgroundColor)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    /// Mini chrome preview: titlebar strip + sidebar column + chat
    /// canvas with a single bubble. Uses the tile's palette directly
    /// so the picker tiles don't depend on the running app's theme.
    /// The `.system` tile gets a split background so users can tell
    /// at a glance that picking it follows the OS.
    private var preview: some View {
        ZStack {
            // Body canvas (mantle == ChatTheme.headerBg)
            palette.mantle

            HStack(spacing: 0) {
                // Sidebar column
                palette.crust
                    .frame(width: 28)
                    .overlay(
                        VStack(alignment: .leading, spacing: 4) {
                            Capsule()
                                .fill(palette.surface1)
                                .frame(height: 4)
                            Capsule()
                                .fill(palette.surface0)
                                .frame(height: 4)
                            Capsule()
                                .fill(palette.surface0)
                                .frame(height: 4)
                            Spacer()
                        }
                        .padding(6)
                    )

                // Chat detail
                VStack(alignment: .leading, spacing: 6) {
                    // Title strip
                    HStack(spacing: 4) {
                        Circle().fill(palette.red).frame(width: 4, height: 4)
                        Circle().fill(palette.yellow).frame(width: 4, height: 4)
                        Circle().fill(palette.green).frame(width: 4, height: 4)
                        Spacer()
                    }
                    // User bubble
                    HStack {
                        Spacer()
                        RoundedRectangle(cornerRadius: 4)
                            .fill(palette.surface0)
                            .frame(width: 38, height: 8)
                    }
                    // Assistant text
                    VStack(alignment: .leading, spacing: 3) {
                        Capsule().fill(palette.text.opacity(0.8)).frame(height: 3)
                        Capsule().fill(palette.text.opacity(0.5)).frame(width: 36, height: 3)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }

            // Diagonal split overlay for the .system tile so it reads
            // as "follows OS" at a glance — Apple's Appearance picker
            // uses the same trick. The split shows the OPPOSITE of
            // the resolved palette so both flavors are visible.
            if mode == .system {
                let opposite: CatppuccinPalette = (palette.text == CatppuccinPalette.mocha.text)
                    ? .latte : .mocha
                GeometryReader { geo in
                    Path { path in
                        path.move(to: CGPoint(x: geo.size.width, y: 0))
                        path.addLine(to: CGPoint(x: 0, y: geo.size.height))
                        path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(opposite.mantle)
                }
                .allowsHitTesting(false)
            }
        }
    }

    private var borderColor: Color {
        if isSelected { return Color.accentColor }
        if isHovered { return Color.secondary.opacity(0.6) }
        return Color.secondary.opacity(0.3)
    }

    private var tileBackgroundColor: Color {
        if isSelected { return Color.accentColor.opacity(0.08) }
        if isHovered { return Color.secondary.opacity(0.08) }
        return Color.clear
    }
}
