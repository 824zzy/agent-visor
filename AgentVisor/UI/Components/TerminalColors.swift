//
//  TerminalColors.swift
//  AgentVisor
//
//  Color palette for the chat surface. Hosts the Catppuccin flavor
//  switch (Mocha for dark mode, Latte for light mode), the semantic
//  ChatTheme tokens that views actually consume, and the small
//  BrandColors namespace for non-Catppuccin brand color (the Claude
//  orange used in the spinner, header icon, and processing indicator).
//

import AgentVisorCore
import SwiftUI

extension Color {
    init(accessible components: SRGBColorComponents) {
        self.init(
            .sRGB,
            red: components.red,
            green: components.green,
            blue: components.blue,
            opacity: 1
        )
    }
}

// MARK: - Brand

/// Color values that don't belong to either Catppuccin flavor and stay
/// constant across themes.
enum BrandColors {
    /// The Claude brand orange. Three different RGB literals were
    /// previously scattered across NotchSideContent, SessionStatusDot,
    /// ProcessingSpinner, NotchHeaderView, ClaudeInstancesView, and
    /// `TerminalColors.prompt`. Consolidated to the most common variant.
    static let claudeOrange = Color(.sRGB, red: 0.8510, green: 0.4706, blue: 0.3412, opacity: 1)  // #d97857

    /// Status-yellow specifically for the SessionStatusDot's
    /// `.waitingForApproval` state. Catppuccin Latte's canonical
    /// `yellow` is `#df8e1d` — a dark amber that on an 8pt status
    /// dot reads identically to claudeOrange `#d97857`, defeating
    /// the visual cue that distinguishes "approval pending" (yellow)
    /// from "running" (orange). This token is brighter, more
    /// chromatic-yellow, and clearly distinct in both light and
    /// dark modes. Tuned against #facc15 (Tailwind yellow-400)
    /// with a slight desaturation so it doesn't vibrate on white.
    static let statusYellow = Color(.sRGB, red: 0.9569, green: 0.7569, blue: 0.0784, opacity: 1)
}

// MARK: - Catppuccin Palette (struct)

/// 22 Catppuccin tokens packaged as a value-type so we can switch
/// between Mocha (dark) and Latte (light) flavors at runtime.
///
/// All values are explicitly tagged `.sRGB`. Without the colorspace
/// argument, SwiftUI's `Color(red:green:blue:)` is interpreted as the
/// display's native gamut on Display P3 monitors (M-series Macs),
/// which renders the same component values noticeably more saturated
/// than the canonical sRGB hex. Pinning the colorspace keeps the
/// rendered output matching catppuccin.com and other sRGB references
/// exactly. Components are byte/255 rounded to four decimals, enough
/// precision to round-trip back to the canonical hex.
struct CatppuccinPalette {
    let green, teal, yellow, peach: Color
    let blue, sky, sapphire: Color
    let mauve, lavender, pink, flamingo, rosewater, red: Color
    let text, subtext: Color
    /// `overlay` is the "Subtle text / line numbers" role from the
    /// style guide (Overlay 1). `overlay2` is the "Comments / selection
    /// background / braces" role. Kept as separate fields because the
    /// two have meaningfully different luminance in Latte.
    let overlay, overlay2: Color
    let surface2, surface1, surface0: Color
    let base, mantle, crust: Color

    /// Catppuccin Mocha — the dark flavor. The original agent-visor design.
    static let mocha = CatppuccinPalette(
        green:    Color(.sRGB, red: 0.6510, green: 0.8902, blue: 0.6314, opacity: 1),  // #a6e3a1
        teal:     Color(.sRGB, red: 0.5804, green: 0.8863, blue: 0.8353, opacity: 1),  // #94e2d5
        yellow:   Color(.sRGB, red: 0.9765, green: 0.8863, blue: 0.6863, opacity: 1),  // #f9e2af
        peach:    Color(.sRGB, red: 0.9804, green: 0.7020, blue: 0.5294, opacity: 1),  // #fab387
        blue:     Color(.sRGB, red: 0.5373, green: 0.7059, blue: 0.9804, opacity: 1),  // #89b4fa
        sky:      Color(.sRGB, red: 0.5373, green: 0.8627, blue: 0.9216, opacity: 1),  // #89dceb
        sapphire: Color(.sRGB, red: 0.4549, green: 0.7804, blue: 0.9255, opacity: 1),  // #74c7ec
        mauve:    Color(.sRGB, red: 0.7961, green: 0.6510, blue: 0.9686, opacity: 1),  // #cba6f7
        lavender: Color(.sRGB, red: 0.7059, green: 0.7451, blue: 0.9961, opacity: 1),  // #b4befe
        pink:     Color(.sRGB, red: 0.9608, green: 0.7608, blue: 0.9059, opacity: 1),  // #f5c2e7
        flamingo: Color(.sRGB, red: 0.9490, green: 0.8039, blue: 0.8039, opacity: 1),  // #f2cdcd
        rosewater: Color(.sRGB, red: 0.9608, green: 0.8784, blue: 0.8627, opacity: 1), // #f5e0dc
        red:      Color(.sRGB, red: 0.9529, green: 0.5451, blue: 0.6588, opacity: 1),  // #f38ba8
        text:     Color(.sRGB, red: 0.8039, green: 0.8392, blue: 0.9569, opacity: 1),  // #cdd6f4
        subtext:  Color(.sRGB, red: 0.6510, green: 0.6784, blue: 0.7843, opacity: 1),  // #a6adc8 (subtext1)
        overlay:  Color(.sRGB, red: 0.4980, green: 0.5176, blue: 0.6118, opacity: 1),  // #7f849c (overlay1)
        overlay2: Color(.sRGB, red: 0.5765, green: 0.6000, blue: 0.6980, opacity: 1),  // #9399b2
        surface2: Color(.sRGB, red: 0.3451, green: 0.3569, blue: 0.4392, opacity: 1),  // #585b70
        surface1: Color(.sRGB, red: 0.2706, green: 0.2784, blue: 0.3529, opacity: 1),  // #45475a
        surface0: Color(.sRGB, red: 0.1922, green: 0.1961, blue: 0.2667, opacity: 1),  // #313244
        base:     Color(.sRGB, red: 0.1176, green: 0.1176, blue: 0.1804, opacity: 1),  // #1e1e2e
        mantle:   Color(.sRGB, red: 0.0941, green: 0.0941, blue: 0.1451, opacity: 1),  // #181825
        crust:    Color(.sRGB, red: 0.0667, green: 0.0667, blue: 0.1059, opacity: 1)   // #11111b
    )

    /// Catppuccin Latte — the light flavor. Tuned for contrast on light
    /// backgrounds: deeper saturation and lower luminance on accents
    /// (red, green, peach) so semantic status colors stay readable on
    /// the near-white base. Hex values sourced from catppuccin/catppuccin.
    static let latte = CatppuccinPalette(
        green:    Color(.sRGB, red: 0.2510, green: 0.6275, blue: 0.1686, opacity: 1),  // #40a02b
        teal:     Color(.sRGB, red: 0.0902, green: 0.5725, blue: 0.6000, opacity: 1),  // #179299
        yellow:   Color(.sRGB, red: 0.8745, green: 0.5569, blue: 0.1137, opacity: 1),  // #df8e1d
        peach:    Color(.sRGB, red: 0.9961, green: 0.3922, blue: 0.0431, opacity: 1),  // #fe640b
        blue:     Color(.sRGB, red: 0.1176, green: 0.4000, blue: 0.9608, opacity: 1),  // #1e66f5
        sky:      Color(.sRGB, red: 0.0157, green: 0.6471, blue: 0.8980, opacity: 1),  // #04a5e5
        sapphire: Color(.sRGB, red: 0.1255, green: 0.6235, blue: 0.7098, opacity: 1),  // #209fb5
        mauve:    Color(.sRGB, red: 0.5333, green: 0.2235, blue: 0.9373, opacity: 1),  // #8839ef
        lavender: Color(.sRGB, red: 0.4471, green: 0.5294, blue: 0.9922, opacity: 1),  // #7287fd
        pink:     Color(.sRGB, red: 0.9176, green: 0.4627, blue: 0.7961, opacity: 1),  // #ea76cb
        flamingo: Color(.sRGB, red: 0.8667, green: 0.4706, blue: 0.4706, opacity: 1),  // #dd7878
        rosewater: Color(.sRGB, red: 0.8627, green: 0.5412, blue: 0.4706, opacity: 1), // #dc8a78
        red:      Color(.sRGB, red: 0.8235, green: 0.0588, blue: 0.2235, opacity: 1),  // #d20f39
        text:     Color(.sRGB, red: 0.2980, green: 0.3098, blue: 0.4118, opacity: 1),  // #4c4f69
        subtext:  Color(.sRGB, red: 0.4235, green: 0.4353, blue: 0.5216, opacity: 1),  // #6c6f85 (subtext1)
        overlay:  Color(.sRGB, red: 0.5490, green: 0.5608, blue: 0.6314, opacity: 1),  // #8c8fa1 (overlay1) — was overlay0 #9ca0b0, too light for "subtle" role on Latte bg
        overlay2: Color(.sRGB, red: 0.4863, green: 0.4980, blue: 0.5765, opacity: 1),  // #7c7f93
        surface2: Color(.sRGB, red: 0.6745, green: 0.6902, blue: 0.7451, opacity: 1),  // #acb0be
        surface1: Color(.sRGB, red: 0.7373, green: 0.7529, blue: 0.8000, opacity: 1),  // #bcc0cc
        surface0: Color(.sRGB, red: 0.8000, green: 0.8157, blue: 0.8549, opacity: 1),  // #ccd0da
        base:     Color(.sRGB, red: 0.9373, green: 0.9451, blue: 0.9608, opacity: 1),  // #eff1f5
        mantle:   Color(.sRGB, red: 0.9020, green: 0.9137, blue: 0.9373, opacity: 1),  // #e6e9ef
        crust:    Color(.sRGB, red: 0.8627, green: 0.8784, blue: 0.9098, opacity: 1)   // #dce0e8
    )

    /// The flavor matching the user's currently-selected appearance,
    /// resolved through `.system` if the user picked "follow OS".
    /// Reads `AppSettings.appearance.resolved` so this works on any
    /// thread, including off-main callers like
    /// `SelectionColorOverride`'s NSColor swizzle and
    /// `SyntaxHighlighterCache`'s post-highlight remap.
    static var active: CatppuccinPalette {
        switch AppSettings.appearance.resolved {
        case .light: return .latte
        case .dark:  return .mocha
        }
    }
}

// MARK: - Catppuccin token namespace (palette-aware)

/// Catppuccin token accessor. Each token returns the value from the
/// currently-active flavor (Mocha or Latte). Existing call sites that
/// read `Catppuccin.green` etc. continue to work unchanged; they
/// switch automatically when the user toggles Light Mode. Safe on any
/// thread because the underlying read goes through
/// `CatppuccinPalette.active` → `AppSettings.appearance` → UserDefaults.
///
/// ⚠️ WARNING — DO NOT capture `Catppuccin.*` tokens (or anything they
/// resolve to: `ChatTheme.*`, `CatppuccinPalette.active`, etc.) inside a
/// `static let`, `let` at file scope, or any other lazily-initialized
/// stored property. Stored properties evaluate **once at first access**
/// and freeze the palette for the rest of the process — the user can
/// toggle Light Mode all day and the captured value never updates.
///
/// This bit us once: `bashHeaderPatterns` in `ChatView.swift` stored
/// `[(regex, Color)]` and froze Mocha-or-Latte at whatever was active
/// the first time a bash row rendered. Symptom was Mocha colors in
/// Light mode (or Latte colors in Dark) depending on which flavor was
/// active at app launch. The fix was to store roles, not Colors, and
/// resolve `role.color` at iteration time.
///
/// Safe patterns:
/// - `var color: Color { Catppuccin.X }` (computed, re-evaluated each call)
/// - `private let color = Catppuccin.X` inside a `struct: View` (SwiftUI
///   re-instantiates the struct per render, so each instance reads fresh)
/// - Reading `Catppuccin.X` directly inside `body` or a function
///
/// Unsafe patterns:
/// - `static let palette: [...Color...] = [Catppuccin.X, ...]`
/// - `static let table: [(Foo, Color)] = { ... Catppuccin.X ... }()`
/// - Any closure-initialized static that captures a Color value
enum Catppuccin {
    static var green: Color    { CatppuccinPalette.active.green }
    static var teal: Color     { CatppuccinPalette.active.teal }
    static var yellow: Color   { CatppuccinPalette.active.yellow }
    static var peach: Color    { CatppuccinPalette.active.peach }
    static var blue: Color     { CatppuccinPalette.active.blue }
    static var sky: Color      { CatppuccinPalette.active.sky }
    static var sapphire: Color { CatppuccinPalette.active.sapphire }
    static var mauve: Color    { CatppuccinPalette.active.mauve }
    static var lavender: Color { CatppuccinPalette.active.lavender }
    static var pink: Color     { CatppuccinPalette.active.pink }
    static var flamingo: Color { CatppuccinPalette.active.flamingo }
    static var rosewater: Color { CatppuccinPalette.active.rosewater }
    static var red: Color      { CatppuccinPalette.active.red }
    static var text: Color     { CatppuccinPalette.active.text }
    static var subtext: Color  { CatppuccinPalette.active.subtext }
    static var overlay: Color  { CatppuccinPalette.active.overlay }
    static var overlay2: Color { CatppuccinPalette.active.overlay2 }
    static var surface2: Color { CatppuccinPalette.active.surface2 }
    static var surface1: Color { CatppuccinPalette.active.surface1 }
    static var surface0: Color { CatppuccinPalette.active.surface0 }
    static var base: Color     { CatppuccinPalette.active.base }
    static var mantle: Color   { CatppuccinPalette.active.mantle }
    static var crust: Color    { CatppuccinPalette.active.crust }
}

// MARK: - Terminal-style accent palette

/// Minor secondary palette used by terminal-style UI bits (status icons,
/// picker selection circles, etc.). Maps to Catppuccin tokens so the
/// flavor switch carries through. `prompt` is the brand orange, not a
/// palette token.
enum TerminalColors {
    static var green: Color   { Catppuccin.green }
    static var amber: Color   { Catppuccin.yellow }
    static var red: Color     { Catppuccin.red }
    static var cyan: Color    { Catppuccin.sky }
    static var blue: Color    { Catppuccin.blue }
    static var magenta: Color { Catppuccin.mauve }

    /// Dim helpers that previously hardcoded `.white.opacity(...)`.
    /// In Latte they need to darken instead of lightening, so route
    /// through the palette overlay (which is mid-gray in both flavors).
    static var dim: Color    { Catppuccin.overlay }
    static var dimmer: Color { Catppuccin.overlay.opacity(0.5) }

    static var prompt: Color {
        AppSettings.appearance.resolved == .light
            ? Color(accessible: AccessibleLightPalette.statusRunning)
            : BrandColors.claudeOrange
    }

    static var background: Color      { Catppuccin.surface0.opacity(0.5) }
    static var backgroundHover: Color { Catppuccin.surface0 }
}

// MARK: - ChatTheme

/// Semantic color roles for the chat surface. Centralizing here so the
/// notch chat view, tool rows, tool results, and approval UI all share
/// the same Catppuccin tokens. Tokens go through `Catppuccin.*` which
/// switches flavors on `AppSettings.appearance`, so views re-render
/// with new colors when `AppearanceSelector` publishes a mode change.
enum ChatTheme {
    private static var usesAccessibleLightPalette: Bool {
        AppSettings.appearance.resolved == .light
    }

    // Text tiers: bright -> dimmest
    static var primary: Color   { Catppuccin.text }       // body text
    static var secondary: Color {
        usesAccessibleLightPalette
            ? Color(accessible: AccessibleLightPalette.secondaryText)
            : Catppuccin.subtext
    }
    static var tertiary: Color {
        usesAccessibleLightPalette
            ? Color(accessible: AccessibleLightPalette.tertiaryText)
            : Catppuccin.overlay
    }
    static var muted: Color     { Catppuccin.surface2 }   // separators

    // Status (tool calls, approvals)
    static var statusRunning: Color {
        usesAccessibleLightPalette
            ? Color(accessible: AccessibleLightPalette.statusRunning)
            : Catppuccin.peach
    }
    static var statusPending: Color {
        usesAccessibleLightPalette
            ? Color(accessible: AccessibleLightPalette.statusPending)
            : Catppuccin.yellow
    }
    static var statusSuccess: Color {
        usesAccessibleLightPalette
            ? Color(accessible: AccessibleLightPalette.statusSuccess)
            : Catppuccin.green
    }
    static var statusError: Color    { Catppuccin.red }

    // Accents
    static var link: Color {
        usesAccessibleLightPalette
            ? Color(accessible: AccessibleLightPalette.link)
            : Catppuccin.blue
    }
    static var inlineCode: Color { statusRunning }
    static var heading: Color {
        usesAccessibleLightPalette
            ? Color(accessible: AccessibleLightPalette.heading)
            : Catppuccin.lavender
    }
    static var bullet: Color    { tertiary }
    static var quoteBar: Color  { Catppuccin.surface2 }

    static func chipForeground(_ tint: Color) -> Color {
        usesAccessibleLightPalette ? primary : tint
    }

    // Surfaces
    static var bubbleUser: Color   { Catppuccin.surface0 }
    static var inputBg: Color      { Catppuccin.surface0 }
    static var inputBorder: Color  { Catppuccin.surface1 }
    static var codeBlockBg: Color  { Catppuccin.mantle }
    static var cardBg: Color       { Catppuccin.surface0 }
    static var cardBorder: Color   { Catppuccin.surface1 }
    static var planBg: Color       { Catppuccin.blue.opacity(0.10) }
    static var planBorder: Color   { Catppuccin.blue.opacity(0.30) }

    // Affordances
    /// Chat body canvas — `Catppuccin.base` in both flavors (brightest
    /// editor tier per canonical Catppuccin spec).
    /// Mocha base = #1e1e2e (Ghostty's TUI body)
    /// Latte base = #eff1f5 (canonical light editor body)
    /// Code blocks / cards use `mantle` in both flavors so they read
    /// as one tonal step deeper.
    static var headerBg: Color     { Catppuccin.base }
    static var headerHover: Color  { Catppuccin.surface0.opacity(0.6) }
}
