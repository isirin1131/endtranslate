import AppKit
import Testing
@testable import EndTranslate

/// Visual tuning harness: renders representative sidebar layouts to `.build/snapshots`
/// so layout constants can be compared against a picture instead of guesses.
/// Skipped in normal test runs; enable with `LAYOUT_SNAPSHOTS=1 zsh scripts/test.sh ...`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LAYOUT_SNAPSHOTS"] == "1"))
@MainActor
final class LayoutSnapshotTests {
    private struct CardInput {
        let text: String
        let source: CGRect
    }

    private struct Scenario {
        let name: String
        let cards: [CardInput]
    }

    private let pdfWidth: CGFloat = 760
    private let sidebarWidth: CGFloat = 320
    private let canvasHeight: CGFloat = 860

    private var outputDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/snapshots", isDirectory: true)
    }

    @Test func renderLayoutSnapshots() async throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let scenarios = [
            Scenario(name: "sparse", cards: [
                CardInput(text: "图 1：Vision Transformer 架构总览。图像被分割为固定大小的图块，线性嵌入后加入位置编码，再输入标准 Transformer 编码器。",
                          source: CGRect(x: 90, y: 180, width: 480, height: 70)),
                CardInput(text: "多层感知机", source: CGRect(x: 120, y: 330, width: 90, height: 18)),
                CardInput(text: "Layer Norm", source: CGRect(x: 360, y: 336, width: 100, height: 18)),
                CardInput(text: "多头自注意力", source: CGRect(x: 120, y: 430, width: 110, height: 18))
            ]),
            Scenario(name: "typical", cards: [
                CardInput(text: "Transformer 编码器", source: CGRect(x: 120, y: 130, width: 150, height: 20)),
                CardInput(text: "图块 + 位置嵌入\n* 额外可学习的 [class] 嵌入", source: CGRect(x: 110, y: 220, width: 150, height: 40)),
                CardInput(text: "范数", source: CGRect(x: 420, y: 226, width: 50, height: 16)),
                CardInput(text: "图 1：模型概览。我们将图像分割为固定大小的图像块，对每个图像块进行线性嵌入，添加位置嵌入，并将得到的向量序列输入标准 Transformer 编码器。",
                          source: CGRect(x: 80, y: 330, width: 500, height: 70)),
                CardInput(text: "多头注意力", source: CGRect(x: 420, y: 470, width: 80, height: 18)),
                CardInput(text: "展平图像块的线性投影", source: CGRect(x: 150, y: 480, width: 160, height: 18))
            ]),
            Scenario(name: "dense", cards: [
                CardInput(text: "多层感知机", source: CGRect(x: 430, y: 90, width: 80, height: 16)),
                CardInput(text: "Transformer 编码器", source: CGRect(x: 170, y: 150, width: 150, height: 18)),
                CardInput(text: "范数", source: CGRect(x: 430, y: 156, width: 50, height: 16)),
                CardInput(text: "图块 + 位置嵌入", source: CGRect(x: 90, y: 230, width: 120, height: 24)),
                CardInput(text: "多头注意力", source: CGRect(x: 430, y: 238, width: 80, height: 18)),
                CardInput(text: "图 1：模型概览。图像被分割为固定大小的图块，线性嵌入后加入位置编码，再输入标准 Transformer 编码器。为了分类，在序列中加入额外的可学习分类标记。",
                          source: CGRect(x: 90, y: 320, width: 440, height: 80)),
                CardInput(text: "展平图像块的线性投影", source: CGRect(x: 170, y: 440, width: 160, height: 18)),
                CardInput(text: "范数", source: CGRect(x: 430, y: 446, width: 50, height: 16)),
                CardInput(text: "嵌入图块", source: CGRect(x: 430, y: 500, width: 70, height: 18)),
                CardInput(text: "注意力", source: CGRect(x: 180, y: 540, width: 60, height: 16)),
                CardInput(text: "图 2：自注意力机制。查询、键和值通过线性变换得到，缩放点积注意力后再与值加权求和。",
                          source: CGRect(x: 100, y: 610, width: 420, height: 70)),
                CardInput(text: "分类标记", source: CGRect(x: 430, y: 720, width: 70, height: 16)),
                CardInput(text: "位置嵌入", source: CGRect(x: 160, y: 726, width: 70, height: 16))
            ])
        ]

        for scenario in scenarios {
            let data = try await render(scenario)
            try data.write(to: outputDirectory.appendingPathComponent("\(scenario.name).png"))
        }
    }

    private func render(_ scenario: Scenario) async throws -> Data {
        let width = Int(pdfWidth + sidebarWidth)
        let height = Int(canvasHeight)
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let gc = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.current = gc
        let ctx = gc.cgContext
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        // Canvas + PDF panel.
        NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.95, alpha: 1).setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: pdfWidth, height: canvasHeight))
        NSColor.white.setFill()
        let pageRect = CGRect(x: 40, y: 40, width: pdfWidth - 80, height: canvasHeight - 80)
        ctx.fill(pageRect)
        NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
        var lineY: CGFloat = 70
        while lineY < canvasHeight - 70 {
            ctx.fill(CGRect(x: 70, y: lineY, width: pdfWidth - 140, height: 5))
            lineY += 18
        }

        // Sidebar backdrop.
        let sidebarX = pdfWidth
        NSColor(calibratedRed: 0.965, green: 0.972, blue: 0.985, alpha: 1).setFill()
        ctx.fill(CGRect(x: sidebarX, y: 0, width: sidebarWidth, height: canvasHeight))
        NSColor(calibratedWhite: 0.82, alpha: 1).setFill()
        ctx.fill(CGRect(x: sidebarX, y: 0, width: 1, height: canvasHeight))

        // Build specs using the same natural card sizing as the app.
        let cardX = sidebarX + CardSidebarLayout.cardHorizontalInset
        let cardWidth = sidebarWidth - CardSidebarLayout.cardHorizontalInset * 2
        var notes: [UUID: TranslationAnnotation] = [:]
        var specs: [SidebarCardSpec] = []
        for input in scenario.cards {
            let model = Annotation(id: UUID(), page: 0, rect: input.source,
                                   translationMd: input.text, createdAt: Date())
            let note = TranslationAnnotation(model: model)
            note.status = .done
            let maxInner = max(cardWidth - 2 * TranslationAnnotation.cardInsetX,
                               TranslationAnnotation.minInnerWidth)
            let renderWidth = TranslationAnnotation.preferredRenderWidth(
                for: input.text, maxInnerWidth: maxInner
            )
            if let rendered = try? await MarkdownRenderer.shared.render(
                markdown: input.text,
                width: renderWidth,
                fontSize: TranslationAnnotation.renderFontSize,
                fitToContent: true
            ) {
                note.rendered = rendered
            } else {
                note.fallbackText = input.text
            }
            notes[model.id] = note
            let metrics = note.layoutMetrics(maxCardWidth: cardWidth)
            specs.append(SidebarCardSpec(
                id: model.id, page: 0, sourceRect: input.source,
                desiredY: input.source.minY, preferredWidth: metrics.naturalWidth,
                height: metrics.naturalHeight, pageMinY: 0, pageMaxY: canvasHeight,
                viewportRect: input.source, isFullWidth: metrics.isFullWidth,
                contentUnits: metrics.contentUnits
            ))
        }
        let placed = CardSidebarLayout.placeScreenCards(
            specs, cardX: cardX, cardWidth: cardWidth, viewportHeight: canvasHeight
        )
        let byID = Dictionary(uniqueKeysWithValues: placed.map { ($0.id, $0) })
        // Source highlights + connectors.
        let accent = NSColor.systemBlue
        for input in scenario.cards {
            let path = CGPath(roundedRect: input.source, cornerWidth: 3, cornerHeight: 3, transform: nil)
            ctx.setFillColor(accent.withAlphaComponent(0.08).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setStrokeColor(accent.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(1.1)
            ctx.addPath(path)
            ctx.strokePath()
        }
        for spec in specs {
            guard let frame = byID[spec.id]?.frame else { continue }
            let connector = CardConnector(sourceRect: spec.sourceRect, cardRect: frame,
                                          minSourceX: 46, maxSourceX: pdfWidth - 46)
            ctx.setStrokeColor(accent.withAlphaComponent(0.3).cgColor)
            ctx.setLineWidth(1)
            connector.addPath(to: ctx)
            ctx.strokePath()
        }

        // Cards.
        for placedCard in placed.sorted(by: { $0.frame.minY < $1.frame.minY }) {
            guard let note = notes[placedCard.id] else { continue }
            drawCard(note, frame: placedCard.frame, in: ctx)
        }

        return try #require(rep.representation(using: .png, properties: [:]))
    }

    private func drawCard(_ note: TranslationAnnotation, frame: CGRect, in ctx: CGContext) {
        let radius = min(10, min(frame.width, frame.height) * 0.35)
        let path = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2.5), blur: 9,
                      color: NSColor.black.withAlphaComponent(0.12).cgColor)
        ctx.setFillColor(NSColor(calibratedRed: 0.99, green: 0.995, blue: 1, alpha: 1).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let content = TranslationAnnotation.contentRect(for: frame)
        if let rendered = note.rendered {
            rendered.draw(in: content, context: ctx, yDown: true)
        } else {
            TranslationAnnotation.drawText(note.displayText, color: .black, in: content,
                                           context: ctx, yDown: true, scale: 1)
        }
        let accentBar = SidebarCardStyle.accentBar(in: frame)
        let accentRadius = accentBar.width * 0.5
        ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.65).cgColor)
        ctx.addPath(CGPath(roundedRect: accentBar, cornerWidth: accentRadius,
                           cornerHeight: accentRadius, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.26).cgColor)
        ctx.setLineWidth(0.9)
        ctx.addPath(path)
        ctx.strokePath()
    }
}
