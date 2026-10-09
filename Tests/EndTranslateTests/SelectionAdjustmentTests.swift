import Testing
import Foundation
import CoreGraphics
@testable import EndTranslate

@Suite(.serialized)
struct SelectionAdjustmentTests {
    private let selection = CGRect(x: 100, y: 200, width: 120, height: 80)
    private let page = CGRect(x: 10, y: 20, width: 400, height: 500)

    struct ResizeCase: Sendable {
        let handle: SelectionHandle
        let delta: CGPoint
        let expected: CGRect
    }

    static let resizeCases: [ResizeCase] = [
        .init(handle: .topLeft, delta: CGPoint(x: -20, y: 30), expected: CGRect(x: 80, y: 200, width: 140, height: 110)),
        .init(handle: .topRight, delta: CGPoint(x: 20, y: 30), expected: CGRect(x: 100, y: 200, width: 140, height: 110)),
        .init(handle: .bottomLeft, delta: CGPoint(x: -20, y: -30), expected: CGRect(x: 80, y: 170, width: 140, height: 110)),
        .init(handle: .bottomRight, delta: CGPoint(x: 20, y: -30), expected: CGRect(x: 100, y: 170, width: 140, height: 110)),
        .init(handle: .top, delta: CGPoint(x: 0, y: 30), expected: CGRect(x: 100, y: 200, width: 120, height: 110)),
        .init(handle: .bottom, delta: CGPoint(x: 0, y: -30), expected: CGRect(x: 100, y: 170, width: 120, height: 110)),
        .init(handle: .left, delta: CGPoint(x: -20, y: 0), expected: CGRect(x: 80, y: 200, width: 140, height: 80)),
        .init(handle: .right, delta: CGPoint(x: 20, y: 0), expected: CGRect(x: 100, y: 200, width: 140, height: 80))
    ]

    @Test(arguments: resizeCases)
    func everyHandleResizesWithoutMovingTheOppositeEdge(_ sample: ResizeCase) {
        // Start slightly off the corner: grabbing its hit area must not snap the box.
        let start = sample.handle.point(in: selection).applying(CGAffineTransform(translationX: 1, y: 2))
        let drag = SelectionAdjustment(kind: .resize(sample.handle), startPoint: start, startRect: selection)
        #expect(drag.rect(at: start, within: page) == selection)
        let moved = CGPoint(x: start.x + sample.delta.x, y: start.y + sample.delta.y)
        #expect(drag.rect(at: moved, within: page) == sample.expected)
    }

    @Test func movingKeepsTheWholeSelectionInsideAnOffsetPage() {
        let drag = SelectionAdjustment(kind: .move, startPoint: CGPoint(x: 130, y: 240), startRect: selection)
        #expect(drag.rect(at: CGPoint(x: 140, y: 255), within: page) == CGRect(x: 110, y: 215, width: 120, height: 80))
        #expect(drag.rect(at: CGPoint(x: -500, y: -500), within: page) == CGRect(x: 10, y: 20, width: 120, height: 80))
        #expect(drag.rect(at: CGPoint(x: 900, y: 999), within: page) == CGRect(x: 290, y: 440, width: 120, height: 80))
    }

    @Test func crossingTheOppositeCornerCannotInvertOrEraseTheSelection() {
        let topLeft = SelectionAdjustment(kind: .resize(.topLeft), startPoint: CGPoint(x: 100, y: 280), startRect: selection)
        let bottomRight = SelectionAdjustment(kind: .resize(.bottomRight), startPoint: CGPoint(x: 220, y: 200), startRect: selection)
        #expect(topLeft.rect(at: CGPoint(x: 900, y: -900), within: page) == CGRect(x: 217, y: 200, width: 3, height: 3))
        #expect(bottomRight.rect(at: CGPoint(x: -900, y: 900), within: page) == CGRect(x: 100, y: 277, width: 3, height: 3))
    }

    @Test func resizingStopsAtTheOriginalPageBoundary() {
        let topRight = SelectionAdjustment(kind: .resize(.topRight), startPoint: CGPoint(x: 220, y: 280), startRect: selection)
        let bottomLeft = SelectionAdjustment(kind: .resize(.bottomLeft), startPoint: CGPoint(x: 100, y: 200), startRect: selection)
        #expect(topRight.rect(at: CGPoint(x: 900, y: 900), within: page) == CGRect(x: 100, y: 200, width: 310, height: 320))
        #expect(bottomLeft.rect(at: CGPoint(x: -900, y: -900), within: page) == CGRect(x: 10, y: 20, width: 210, height: 260))
    }

    @Test func draggingBackToTheStartRestoresTheExactRectangle() {
        let start = CGPoint(x: 123.5, y: 245.25)
        let drag = SelectionAdjustment(kind: .move, startPoint: start, startRect: selection)
        _ = drag.rect(at: CGPoint(x: 10000, y: -10000), within: page)
        _ = drag.rect(at: CGPoint(x: -10000, y: 10000), within: page)
        #expect(drag.rect(at: start, within: page) == selection)
    }
}
