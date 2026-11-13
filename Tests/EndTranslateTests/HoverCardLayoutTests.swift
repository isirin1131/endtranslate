import CoreGraphics
import Testing
@testable import EndTranslate

struct HoverCardLayoutTests {
    private let viewport = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let sidebar = CGRect(x: 900, y: 0, width: 300, height: 800)

    @Test func loadingCardsNeverExpand() {
        let base = CGRect(x: 914, y: 200, width: 272, height: 64)
        let layout = SidebarCardPainter.hoverLayout(
            contentSize: CGSize(width: 254, height: 50),
            fallbackText: nil,
            isLoading: true,
            baseRect: base,
            baseScale: 0.9,
            sidebarRect: sidebar,
            viewportBounds: viewport
        )
        #expect(layout.frame == base)
        #expect(layout.scale == 0.9)
    }

    @Test func compressedCardExpandsBeyondBaseScaleAndFloatsAcrossDivider() {
        // Simulates a dense viewport where a 280x140 paragraph was squeezed into a narrow card.
        let narrowSidebar = CGRect(x: 960, y: 0, width: 240, height: 800)
        let base = CGRect(x: 974, y: 340, width: 212, height: 96)
        let layout = SidebarCardPainter.hoverLayout(
            contentSize: CGSize(width: 280, height: 140),
            fallbackText: nil,
            isLoading: false,
            baseRect: base,
            baseScale: 0.55,
            sidebarRect: narrowSidebar,
            viewportBounds: viewport
        )
        #expect(layout.scale >= 1.18)
        #expect(layout.frame.width > base.width)
        #expect(layout.frame.height > base.height)
        // Floated slightly left of the divider rather than clipping out the right window edge.
        #expect(layout.frame.minX < narrowSidebar.minX)
        #expect(layout.frame.maxX <= viewport.maxX - 12)
    }

    @Test func narrowChipGrowsRightwardFromLeftEdgeToStayConnected() {
        let base = CGRect(x: 914, y: 260, width: 110, height: 32)
        let layout = SidebarCardPainter.hoverLayout(
            contentSize: CGSize(width: 92, height: 18),
            fallbackText: nil,
            isLoading: false,
            baseRect: base,
            baseScale: 1.0,
            sidebarRect: sidebar,
            viewportBounds: viewport
        )
        #expect(layout.frame.minX == base.minX)
        #expect(layout.frame.width > base.width)
        #expect(layout.scale > 1.0)
    }

    @Test func edgeCardsStayClampedInsideSafeViewport() {
        let topClipped = CGRect(x: 914, y: -12, width: 272, height: 80)
        let topLayout = SidebarCardPainter.hoverLayout(
            contentSize: CGSize(width: 254, height: 120),
            fallbackText: nil,
            isLoading: false,
            baseRect: topClipped,
            baseScale: 0.85,
            sidebarRect: sidebar,
            viewportBounds: viewport
        )
        #expect(topLayout.frame.minY >= 12)
        #expect(topLayout.frame.maxY <= viewport.maxY - 12)

        let bottomClipped = CGRect(x: 914, y: 740, width: 272, height: 80)
        let bottomLayout = SidebarCardPainter.hoverLayout(
            contentSize: CGSize(width: 254, height: 120),
            fallbackText: nil,
            isLoading: false,
            baseRect: bottomClipped,
            baseScale: 0.85,
            sidebarRect: sidebar,
            viewportBounds: viewport
        )
        #expect(bottomLayout.frame.maxY <= viewport.maxY - 12)
        #expect(bottomLayout.frame.minY >= 12)
    }

    @Test func failedFallbackCardExpandsTextReadably() {
        let base = CGRect(x: 914, y: 300, width: 140, height: 30)
        let layout = SidebarCardPainter.hoverLayout(
            contentSize: nil,
            fallbackText: "翻译请求超时，点击卡片或高亮区域可以重试。",
            isLoading: false,
            baseRect: base,
            baseScale: 0.8,
            sidebarRect: sidebar,
            viewportBounds: viewport
        )
        #expect(layout.scale > 1.0)
        #expect(layout.frame.width >= base.width)
        #expect(layout.frame.height >= base.height)
    }

    @Test func zeroProgressReturnsBaseRectAndInterpolatesSmoothly() {
        let base = CGRect(x: 914, y: 300, width: 272, height: 100)
        let zero = SidebarCardPainter.hoverLayout(
            contentSize: CGSize(width: 254, height: 86),
            fallbackText: nil,
            isLoading: false,
            baseRect: base,
            baseScale: 0.9,
            sidebarRect: sidebar,
            viewportBounds: viewport,
            progress: 0
        )
        let mid = SidebarCardPainter.hoverLayout(
            contentSize: CGSize(width: 254, height: 86),
            fallbackText: nil,
            isLoading: false,
            baseRect: base,
            baseScale: 0.9,
            sidebarRect: sidebar,
            viewportBounds: viewport,
            progress: 0.5
        )
        let full = SidebarCardPainter.hoverLayout(
            contentSize: CGSize(width: 254, height: 86),
            fallbackText: nil,
            isLoading: false,
            baseRect: base,
            baseScale: 0.9,
            sidebarRect: sidebar,
            viewportBounds: viewport,
            progress: 1.0
        )
        #expect(zero.frame == base)
        #expect(zero.scale == 0.9)
        #expect(mid.scale > zero.scale && mid.scale < full.scale)
        #expect(mid.frame.width > zero.frame.width && mid.frame.width < full.frame.width)
    }
}
