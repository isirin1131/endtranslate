import CoreGraphics
import Foundation
import Testing
@testable import EndTranslate

@Suite struct AnnotationMetricsTests {
    private func annotation(_ text: String) -> TranslationAnnotation {
        let model = Annotation(
            id: UUID(), page: 0,
            rect: CGRect(x: 20, y: 30, width: 180, height: 40),
            translationMd: text, createdAt: Date()
        )
        let note = TranslationAnnotation(model: model)
        note.status = .done
        return note
    }

    @Test func cachedMetricsInvalidateWhenContentOrStatusChanges() {
        let note = annotation("多层感知机")
        let first = note.layoutMetrics(maxCardWidth: 296)
        #expect(first == note.layoutMetrics(maxCardWidth: 296))
        #expect(first.contentUnits > 0)
        #expect(!first.isFullWidth)

        note.model.translationMd = String(repeating: "一段足够长的译文，用来触发全宽布局。", count: 6)
        let longer = note.layoutMetrics(maxCardWidth: 296)
        #expect(longer.contentUnits > first.contentUnits)
        #expect(longer.isFullWidth)
        #expect(longer != first)

        note.status = .failed("网络未连接")
        let failed = note.layoutMetrics(maxCardWidth: 296)
        #expect(failed != longer)
    }

    @Test func cacheIsKeyedByAvailableCardWidth() {
        let note = annotation(String(repeating: "这是一段用于验证宽度缓存的较长译文。", count: 8))
        let wide = note.layoutMetrics(maxCardWidth: 360)
        let narrow = note.layoutMetrics(maxCardWidth: 120)
        #expect(wide.naturalWidth <= 360)
        #expect(narrow.naturalWidth <= 120)
        #expect(narrow.naturalWidth < wide.naturalWidth)
        #expect(note.layoutMetrics(maxCardWidth: 360) == wide)
    }
}
