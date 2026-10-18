import AppKit
import Testing
@testable import EndTranslate

/// Visual tuning harness: renders representative sidebar layouts to `.build/snapshots`
/// so layout and chrome constants can be compared against a picture instead of guesses.
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
        var hoverIndex: Int? = nil
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
        let typicalCards: [CardInput] = [
            CardInput(text: "Transformer 编码器", source: CGRect(x: 120, y: 130, width: 150, height: 20)),
            CardInput(text: "图块 + 位置嵌入\n* 额外可学习的 [class] 嵌入", source: CGRect(x: 110, y: 220, width: 150, height: 40)),
            CardInput(text: "范数", source: CGRect(x: 420, y: 226, width: 50, height: 16)),
            CardInput(text: "图 1：模型概览。我们将图像分割为固定大小的图像块，对每个图像块进行线性嵌入，添加位置嵌入，并将得到的向量序列输入标准 Transformer 编码器。",
                      source: CGRect(x: 80, y: 330, width: 500, height: 70)),
            CardInput(text: "多头注意力", source: CGRect(x: 420, y: 470, width: 80, height: 18)),
            CardInput(text: "展平图像块的线性投影", source: CGRect(x: 150, y: 480, width: 160, height: 18))
        ]
        let scenarios = [
            Scenario(name: "sparse", cards: [
                CardInput(text: "图 1：Vision Transformer 架构总览。图像被分割为固定大小的图块，线性嵌入后加入位置编码，再输入标准 Transformer 编码器。",
                          source: CGRect(x: 90, y: 180, width: 480, height: 70)),
                CardInput(text: "多层感知机", source: CGRect(x: 120, y: 330, width: 90, height: 18)),
                CardInput(text: "Layer Norm", source: CGRect(x: 360, y: 336, width: 100, height: 18)),
                CardInput(text: "多头自注意力", source: CGRect(x: 120, y: 430, width: 110, height: 18))
            ]),
            Scenario(name: "typical", cards: typicalCards),
            Scenario(name: "typical-hover", cards: typicalCards, hoverIndex: 3),
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

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: appearanceName))
            let suffix = appearanceName == .darkAqua ? "dark" : "light"
            for scenario in scenarios {
                let data = try await render(scenario, appearance: appearance)
                try data.write(to: outputDirectory.appendingPathComponent("\(scenario.name)-\(suffix).png"))
            }
        }
    }

    private func render(_ scenario: Scenario, appearance: NSAppearance) async throws -> Data {
        let width = Int(pdfWidth + sidebarWidth)
        let height = Int(canvasHeight)
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))

        // Build specs using the same natural card sizing as the app.
        let cardX = pdfWidth + CardSidebarLayout.cardHorizontalInset
        let cardWidth = sidebarWidth - CardSidebarLayout.cardHorizontalInset * 2
        var notes: [UUID: TranslationAnnotation] = [:]
        var specs: [SidebarCardSpec] = []
        var ids: [UUID] = []
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
            ids.append(model.id)
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
        let hoveredID = scenario.hoverIndex.flatMap { index in
            ids.indices.contains(index) ? ids[index] : nil
        }

        var png: Data?
        appearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            guard let gc = NSGraphicsContext(bitmapImageRep: rep) else { return }
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
            let sidebarRect = CGRect(x: pdfWidth, y: 0, width: sidebarWidth, height: canvasHeight)
            let sidebarColors = [ReaderTheme.sidebarTop.cgColor, ReaderTheme.sidebarBottom.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: sidebarColors, locations: [0, 1]) {
                ctx.saveGState()
                ctx.clip(to: sidebarRect)
                ctx.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: sidebarRect.midX, y: 0),
                    end: CGPoint(x: sidebarRect.midX, y: canvasHeight),
                    options: []
                )
                ctx.restoreGState()
            }
            ctx.setFillColor(ReaderTheme.sidebarDivider.cgColor)
            ctx.fill(CGRect(x: sidebarRect.minX, y: 0, width: 1, height: canvasHeight))

            // Source highlights + anchor dots.
            for (index, input) in scenario.cards.enumerated() {
                let isHovered = ids[index] == hoveredID
                let color = ReaderTheme.inkAccent
                let path = CGPath(roundedRect: input.source, cornerWidth: 3, cornerHeight: 3, transform: nil)
                ctx.setFillColor((isHovered ? ReaderTheme.sourceFillHover : ReaderTheme.sourceFill).cgColor)
                ctx.addPath(path)
                ctx.fillPath()
                ctx.setStrokeColor((isHovered ? ReaderTheme.sourceStrokeHover : ReaderTheme.sourceStroke).cgColor)
                ctx.setLineWidth(isHovered ? 1.6 : 1.1)
                ctx.addPath(path)
                ctx.strokePath()
                let radius = isHovered ? ConnectorStyle.sourceAnchorHoverRadius : ConnectorStyle.sourceAnchorRadius
                let dot = CGPoint(x: input.source.maxX, y: input.source.midY)
                ctx.setFillColor(color.withAlphaComponent(isHovered ? 0.95 : 0.55).cgColor)
                ctx.fillEllipse(in: CGRect(x: dot.x - radius, y: dot.y - radius,
                                           width: radius * 2, height: radius * 2))
            }

            // Idle connectors follow the production visibility policy.
            let quietAlpha = ConnectorStyle.quietAlpha(for: scenario.cards.count)
            if hoveredID == nil, quietAlpha > 0 {
                let path = CGMutablePath()
                for spec in specs {
                    guard let frame = byID[spec.id]?.frame else { continue }
                    CardConnector(sourceRect: spec.sourceRect, cardRect: frame,
                                  minSourceX: 46, maxSourceX: pdfWidth - 46).addPath(to: path)
                }
                ctx.saveGState()
                ctx.setLineWidth(ConnectorStyle.quietLineWidth)
                ctx.setLineCap(.round)
                ctx.saveGState()
                ctx.clip(to: CGRect(x: 0, y: 0, width: pdfWidth, height: canvasHeight))
                ctx.setStrokeColor(ReaderTheme.inkAccent.withAlphaComponent(quietAlpha).cgColor)
                ctx.addPath(path)
                ctx.strokePath()
                ctx.restoreGState()
                ctx.saveGState()
                ctx.clip(to: sidebarRect)
                ctx.setStrokeColor(ReaderTheme.chromeAccent.withAlphaComponent(quietAlpha).cgColor)
                ctx.addPath(path)
                ctx.strokePath()
                ctx.restoreGState()
                ctx.restoreGState()
            }

            // Cards.
            let orderedCards = placed.sorted {
                ($0.id == hoveredID ? 1 : 0, $0.frame.minY) < ($1.id == hoveredID ? 1 : 0, $1.frame.minY)
            }
            for placedCard in orderedCards {
                guard let note = notes[placedCard.id] else { continue }
                drawCard(note, frame: placedCard.frame,
                         isHovered: placedCard.id == hoveredID,
                         isDimmed: hoveredID != nil && placedCard.id != hoveredID,
                         in: ctx)
            }

            if let hoveredID, let frame = byID[hoveredID]?.frame,
               let inputIndex = ids.firstIndex(of: hoveredID) {
                let source = scenario.cards[inputIndex].source
                let connector = CardConnector(sourceRect: source, cardRect: frame,
                                              minSourceX: 46, maxSourceX: pdfWidth - 46)
                ctx.saveGState()
                ctx.setLineCap(.round)
                ctx.setStrokeColor(ReaderTheme.inkAccent.withAlphaComponent(0.14).cgColor)
                ctx.setLineWidth(ConnectorStyle.activeHaloWidth)
                connector.addPath(to: ctx)
                ctx.strokePath()
                ctx.setStrokeColor(ReaderTheme.inkAccent.withAlphaComponent(0.92).cgColor)
                ctx.setLineWidth(ConnectorStyle.activeLineWidth)
                connector.addPath(to: ctx)
                ctx.strokePath()
                ctx.restoreGState()

                let radius = ConnectorStyle.cardEndpointRadius
                let center = connector.end
                ctx.setFillColor(ReaderTheme.inkAccent.cgColor)
                ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                           width: radius * 2, height: radius * 2))
            }

            png = rep.representation(using: .png, properties: [:])
        }
        return try #require(png)
    }

    private func drawCard(_ note: TranslationAnnotation, frame: CGRect,
                          isHovered: Bool, isDimmed: Bool, in ctx: CGContext) {
        let radius = min(SidebarCardStyle.cornerRadius, min(frame.width, frame.height) * 0.35)
        let path = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)

        if isHovered {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 10, color: ReaderTheme.cardHoverGlow.cgColor)
            ctx.setStrokeColor(ReaderTheme.chromeAccent.withAlphaComponent(0.62).cgColor)
            ctx.setLineWidth(2)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: isHovered ? 3 : 2),
                      blur: isHovered ? 12 : 8, color: ReaderTheme.cardShadow.cgColor)
        ctx.setFillColor(ReaderTheme.cardPaper.cgColor)
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
        ctx.setFillColor(ReaderTheme.inkAccent
            .withAlphaComponent(isHovered ? 0.98 : isDimmed ? 0.42 : 0.65).cgColor)
        ctx.addPath(CGPath(roundedRect: accentBar, cornerWidth: accentRadius,
                           cornerHeight: accentRadius, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.setStrokeColor(ReaderTheme.inkAccent
            .withAlphaComponent(isHovered ? 0.85 : isDimmed ? 0.12 : 0.22).cgColor)
        ctx.setLineWidth(isHovered ? 1.25 : 0.8)
        ctx.addPath(path)
        ctx.strokePath()
    }
}
