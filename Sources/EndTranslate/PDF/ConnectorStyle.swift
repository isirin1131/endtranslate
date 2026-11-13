import CoreGraphics

/// Visibility and weight policy for source-to-card leader lines.
///
/// A screen full of individually stroked Bezier curves reads as noise. Sparse viewports get
/// one combined, very low-contrast path; dense viewports draw no idle connectors at all.
/// Hovering a source box or a card always reveals exactly one emphasized pair with a crisp,
/// clean stroke.
enum ConnectorStyle {
    static let quietLineWidth: CGFloat = 0.8
    static let activeLineWidth: CGFloat = 1.25
    static let activeHaloWidth: CGFloat = 0
    static let sourceAnchorRadius: CGFloat = 2
    static let sourceAnchorHoverRadius: CGFloat = 2.5
    static let cardEndpointRadius: CGFloat = 2.0

    /// Opacity for the single combined idle path. Returns 0 when it should not be drawn.
    static func quietAlpha(for visiblePairCount: Int) -> CGFloat {
        guard visiblePairCount > 0 else { return 0 }
        if visiblePairCount <= 4 { return 0.16 }
        if visiblePairCount <= 7 { return 0.09 }
        return 0
    }

    static func shouldDrawQuiet(count: Int, hovering: Bool) -> Bool {
        !hovering && quietAlpha(for: count) > 0
    }
}
