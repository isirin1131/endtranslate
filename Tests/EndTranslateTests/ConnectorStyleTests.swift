import CoreGraphics
import Testing
@testable import EndTranslate

struct ConnectorStyleTests {
    @Test func idleLinesFadeOutAsTheViewportGetsCrowded() {
        #expect(ConnectorStyle.quietAlpha(for: 0) == 0)
        #expect(ConnectorStyle.quietAlpha(for: 1) == 0.16)
        #expect(ConnectorStyle.quietAlpha(for: 4) == 0.16)
        #expect(ConnectorStyle.quietAlpha(for: 5) == 0.09)
        #expect(ConnectorStyle.quietAlpha(for: 7) == 0.09)
        #expect(ConnectorStyle.quietAlpha(for: 8) == 0)
        #expect(ConnectorStyle.quietAlpha(for: 30) == 0)
    }

    @Test func hoveringAlwaysSuppressesTheQuietBundle() {
        #expect(!ConnectorStyle.shouldDrawQuiet(count: 4, hovering: true))
        #expect(!ConnectorStyle.shouldDrawQuiet(count: 8, hovering: false))
        #expect(ConnectorStyle.shouldDrawQuiet(count: 4, hovering: false))
        #expect(ConnectorStyle.shouldDrawQuiet(count: 7, hovering: false))
    }

    @Test func connectorStartsAtSourceCenterAndEntersTheCardNearIt() {
        let source = CGRect(x: 100, y: 300, width: 120, height: 40)
        let card = CGRect(x: 700, y: 500, width: 200, height: 30)
        let connector = CardConnector(sourceRect: source, cardRect: card)
        #expect(connector.start == CGPoint(x: source.maxX, y: source.midY))
        #expect(connector.end.x == card.minX)
        #expect(connector.end.y >= card.minY)
        #expect(connector.end.y <= card.maxY)
        #expect(connector.control1.x > connector.start.x)
        #expect(connector.control2.x < connector.end.x)
    }

    @Test func connectorRejectsEmptyOrInfiniteRects() {
        for rect in [CGRect.zero, CGRect(x: 0, y: 0, width: CGFloat.nan, height: 10),
                     CGRect(x: 0, y: 0, width: 10, height: CGFloat.infinity)] {
            let connector = CardConnector(sourceRect: rect, cardRect: CGRect(x: 100, y: 100, width: 50, height: 20))
            #expect(connector.start == .zero)
            #expect(connector.end == .zero)
        }
    }
}
