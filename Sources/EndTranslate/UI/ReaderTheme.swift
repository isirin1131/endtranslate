import AppKit

/// Semantic colors for the reader chrome.
///
/// Translation cards stay paper-white in both appearances: the typeset PDF produced by
/// WebKit fills its page with white, so tinting the card behind it would only show through
/// the margins. Chrome around the paper (sidebar, dividers, selection, connectors on the
/// sidebar side) is dynamic instead.
enum ReaderTheme {
    // MARK: - Paper surfaces

    /// Fixed ink accent for anything drawn on white paper: source highlights, card borders,
    /// accent bars and the PDF-side half of a connector.
    static let inkAccent = color(0x3E63DD)
    static let inkAccentStrong = color(0x2F4FCC)
    static let inkError = color(0xC43D3D)

    static let cardPaper = NSColor.white

    // MARK: - Chrome surfaces

    /// Accent for controls and the sidebar side of connectors. Lighter in dark mode so it
    /// stays legible against the dark backdrop.
    static let chromeAccent = dynamic(light: color(0x3E63DD), dark: color(0x9BB0FF))
    static let chromeError = dynamic(light: color(0xC43D3D), dark: color(0xFF8A80))

    static let sidebarTop = dynamic(light: color(0xF8F9FC), dark: color(0x1C1E23))
    static let sidebarBottom = dynamic(light: color(0xF0F3F8), dark: color(0x15171A))
    static let sidebarDivider = dynamic(light: color(0xDCE1E9), dark: color(0x2E323A))
    static let sidebarInnerShadow = dynamic(
        light: NSColor.black.withAlphaComponent(0.055),
        dark: NSColor.black.withAlphaComponent(0.34)
    )

    static let cardBorder = dynamic(light: color(0xD8DEE9), dark: color(0x5B6270))
    static let cardShadow = dynamic(
        light: NSColor.black.withAlphaComponent(0.10),
        dark: NSColor.black.withAlphaComponent(0.46)
    )
    static let cardHoverGlow = dynamic(
        light: color(0x3E63DD).withAlphaComponent(0.30),
        dark: color(0x9BB0FF).withAlphaComponent(0.40)
    )

    static let chipSurface = dynamic(light: NSColor.white, dark: color(0x2A2D33))
    static let chipBorder = dynamic(
        light: NSColor.black.withAlphaComponent(0.12),
        dark: NSColor.white.withAlphaComponent(0.14)
    )
    static let hintBorder = dynamic(light: color(0xD5DBE5), dark: color(0x3B404A))

    // MARK: - Print palette (export always uses the light paper look)

    static let printSidebar = color(0xF7F8FA)
    static let printDivider = color(0xDDE1E8)
    static let printCardBorder = inkAccent.withAlphaComponent(0.20)
    static let printConnector = inkAccent.withAlphaComponent(0.30)

    // MARK: - Source highlights (always on white paper)

    static let sourceFill = inkAccent.withAlphaComponent(0.05)
    static let sourceFillHover = inkAccent.withAlphaComponent(0.11)
    static let sourceStroke = inkAccent.withAlphaComponent(0.38)
    static let sourceStrokeHover = inkAccent.withAlphaComponent(0.95)
    static let sourceDimmedStroke = inkAccent.withAlphaComponent(0.24)

    static let errorFill = inkError.withAlphaComponent(0.07)
    static let errorStroke = inkError.withAlphaComponent(0.55)
    static let errorStrokeHover = inkError.withAlphaComponent(0.95)

    // MARK: - Selection

    static let selectionFill = inkAccent.withAlphaComponent(0.12)
    static let selectionStroke = inkAccent.withAlphaComponent(0.85)
    static let handleFill = NSColor.white
    static let skeleton = inkAccent

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
