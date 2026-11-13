import AppKit

/// Semantic colors for the reader chrome.
///
/// Translation cards adopt paper tones (pure white in light mode, soft off-white in dark mode).
/// Chrome around the paper (sidebar, dividers, selection, connectors on the sidebar side)
/// uses adaptive system tones for a quiet, refined appearance.
enum ReaderTheme {
    // MARK: - Paper surfaces

    /// Fixed ink accent for anything drawn on paper: source highlights, card borders,
    /// accent bars and the PDF-side half of a connector.
    static let inkAccent = color(0x4A63C8)
    static let inkAccentStrong = color(0x3B52B0)
    static let inkError = color(0xC43D3D)

    static let cardPaper = dynamic(light: .white, dark: color(0xEDEEF0))

    // MARK: - Semantic accents

    static let success = dynamic(light: color(0x2E9E5B), dark: color(0x5BD08A))
    static let warning = dynamic(light: color(0xC7811A), dark: color(0xF0B456))

    // MARK: - Chrome surfaces

    /// Accent for controls and the sidebar side of connectors. Lighter in dark mode so it
    /// stays legible against the dark backdrop.
    static let chromeAccent = dynamic(light: color(0x4A63C8), dark: color(0x9BB0FF))
    static let chromeError = dynamic(light: color(0xC43D3D), dark: color(0xFF8A80))

    static let sidebarSurface = dynamic(light: color(0xF5F6F8), dark: color(0x1A1C20))
    static let sidebarTop = sidebarSurface
    static let sidebarBottom = sidebarSurface
    static let sidebarDivider = dynamic(light: color(0xE1E4EA), dark: color(0x282B32))
    static let sidebarInnerShadow = dynamic(
        light: NSColor.black.withAlphaComponent(0.035),
        dark: NSColor.black.withAlphaComponent(0.24)
    )

    static let cardStroke = dynamic(
        light: NSColor.black.withAlphaComponent(0.07),
        dark: NSColor.black.withAlphaComponent(0.18)
    )
    static let cardBorder = dynamic(light: color(0xD8DEE9), dark: color(0x5B6270))
    static let cardShadow = dynamic(
        light: NSColor.black.withAlphaComponent(0.08),
        dark: NSColor.black.withAlphaComponent(0.40)
    )
    static let cardHoverGlow = dynamic(
        light: color(0x4A63C8).withAlphaComponent(0.20),
        dark: color(0x9BB0FF).withAlphaComponent(0.30)
    )

    static let chipSurface = dynamic(light: NSColor.white, dark: color(0x2A2D33))
    static let chipBorder = dynamic(
        light: NSColor.black.withAlphaComponent(0.10),
        dark: NSColor.white.withAlphaComponent(0.12)
    )
    static let hintBorder = dynamic(light: color(0xD8DEE8), dark: color(0x353A44))

    // MARK: - Print palette (export always uses the light paper look)

    static let printSidebar = color(0xF6F7F9)
    static let printDivider = color(0xE0E3E8)
    static let printCardBorder = NSColor.black.withAlphaComponent(0.08)
    static let printConnector = inkAccent.withAlphaComponent(0.35)

    // MARK: - Source highlights (always on white paper)

    static let sourceFill = inkAccent.withAlphaComponent(0.04)
    static let sourceFillHover = inkAccent.withAlphaComponent(0.08)
    static let sourceStroke = NSColor.clear
    static let sourceStrokeHover = inkAccent.withAlphaComponent(0.85)
    static let sourceDimmedStroke = NSColor.clear

    static let errorFill = inkError.withAlphaComponent(0.05)
    static let errorStroke = NSColor.clear
    static let errorStrokeHover = inkError.withAlphaComponent(0.85)

    // MARK: - Selection

    static let selectionFill = inkAccent.withAlphaComponent(0.08)
    static let selectionStroke = inkAccent.withAlphaComponent(0.85)
    static let handleFill = NSColor.white
    static let skeleton = dynamic(
        light: NSColor.black.withAlphaComponent(0.07),
        dark: NSColor.white.withAlphaComponent(0.10)
    )

    // MARK: - Helpers

    static func isDark(_ appearance: NSAppearance) -> Bool {
        let name = appearance.bestMatch(from: [.darkAqua, .aqua])
        return name?.rawValue.contains("Dark") == true
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            isDark(appearance) ? dark : light
        }
    }

    private static func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
