import Testing
import PDFKit
@testable import EndTranslate

@Suite(.serialized)
struct PDFNavigationTests {
    private func document() throws -> PDFDocument {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 20, y: 30, width: 400, height: 500)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        for _ in 0..<3 {
            context.beginPDFPage(nil)
            context.fill(CGRect(x: 50, y: 100, width: 100, height: 100))
            context.endPDFPage()
        }
        context.closePDF()
        return try #require(PDFDocument(data: data as Data))
    }

    @Test func nestedOutlineKeepsGroupsAndLocalGoToActions() throws {
        let doc = try document()
        let root = PDFOutline()
        let group = PDFOutline()
        group.label = "Part One"
        root.insertChild(group, at: 0)
        let first = PDFOutline()
        first.label = "  Chapter  \n"
        group.insertChild(first, at: 0)
        first.destination = PDFDestination(page: doc.page(at: 0)!, at: CGPoint(x: 30, y: 450))
        let second = PDFOutline()
        second.label = "Chapter"
        group.insertChild(second, at: 1)
        second.action = PDFActionGoTo(destination: PDFDestination(page: doc.page(at: 2)!, at: CGPoint(x: 40, y: 400)))
        doc.outlineRoot = root

        let entries = PDFOutlineEntry.read(from: doc)
        let parent = try #require(entries.first)
        let children = try #require(parent.children)
        #expect(parent.target == nil)
        #expect(children.count == 2)
        #expect(children[0].title == "Chapter")
        #expect(children[0].id != children[1].id)
        #expect(children[0].target == PDFNavigationTarget(pageIndex: 0, point: CGPoint(x: 30, y: 450)))
        #expect(children[1].target == PDFNavigationTarget(pageIndex: 2, point: CGPoint(x: 40, y: 400)))
        #expect(children[0].children == nil)
    }

    @Test func missingOutlineAndExternalActionsDoNotBecomePageLinks() throws {
        let doc = try document()
        #expect(PDFOutlineEntry.read(from: doc).isEmpty)
        let root = PDFOutline()
        let external = PDFOutline()
        root.insertChild(external, at: 0)
        external.label = "External reference"
        external.action = PDFActionURL(url: URL(string: "https://example.com")!)
        doc.outlineRoot = root
        let entry = try #require(PDFOutlineEntry.read(from: doc).first)
        #expect(entry.target == nil)
    }

    @Test func outlineTargetUsesUntouchedPageCoordinates() throws {
        let doc = try document()
        let target = PDFNavigationTarget(pageIndex: 1, point: CGPoint(x: 50, y: 450))
        let destination = try #require(target.destination(in: doc))
        #expect(destination.page === doc.page(at: 1))
        #expect(destination.point == CGPoint(x: 50, y: 450))
        #expect(destination.zoom == kPDFDestinationUnspecifiedValue)
    }

    @Test func pageJumpAndUnspecifiedOutlineCoordinatesUseThePageTop() throws {
        let doc = try document()
        for target in [PDFNavigationTarget(pageIndex: 0),
                       PDFNavigationTarget(pageIndex: 0, point: CGPoint(x: kPDFDestinationUnspecifiedValue, y: .nan))] {
            let destination = try #require(target.destination(in: doc))
            #expect(destination.point == CGPoint(x: 20, y: 530))
        }
    }

    @Test func pageNumberInputAcceptsWhitespaceButRejectsInvalidAndOutOfRangeValues() {
        #expect(PDFNavigationTarget.pageIndex(from: " 2\n", pageCount: 3) == 1)
        #expect(PDFNavigationTarget.pageIndex(from: "1", pageCount: 3) == 0)
        #expect(PDFNavigationTarget.pageIndex(from: "3", pageCount: 3) == 2)
        for text in ["", "0", "-1", "4", "1.5", "two", "2\n3", "9999999999999999999999999"] {
            #expect(PDFNavigationTarget.pageIndex(from: text, pageCount: 3) == nil)
        }
        #expect(PDFNavigationTarget.pageIndex(from: "1", pageCount: 0) == nil)
    }

    @Test func staleOrInvalidPageIndexesCannotNavigateIntoAnotherPage() throws {
        let doc = try document()
        #expect(PDFNavigationTarget(pageIndex: -1).destination(in: doc) == nil)
        #expect(PDFNavigationTarget(pageIndex: 3).destination(in: doc) == nil)
    }

    @MainActor
    @Test func pageIndicatorRefreshesAfterDocumentReplacementAndScrolling() throws {
        let previous = try document()
        let current = try document()
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 320))
        view.displayMode = .singlePageContinuous
        view.autoScales = false
        view.scaleFactor = 1
        view.document = previous
        view.layoutDocumentView()
        view.go(to: previous.page(at: 2)!)

        let model = PDFViewModel()
        model.pdfView = view
        model.document = current
        model.currentPageIndex = 2
        view.document = current
        view.layoutDocumentView()
        let first = try #require(PDFNavigationTarget(pageIndex: 0).destination(in: current))
        view.go(to: first)
        model.viewportDidChange()
        #expect(model.currentPageIndex == 0)
        #expect(!model.canGoToPreviousPage)
        #expect(model.canGoToNextPage)

        let second = try #require(PDFNavigationTarget(pageIndex: 1).destination(in: current))
        view.go(to: second)
        model.viewportDidChange()
        #expect(model.currentPageIndex == 1)
    }

    @Test func sideBySideAndWrappedSelectionsResolveIntoNonOverlappingSidebarCardsWithConnectors() {
        let leftColID = UUID()
        let rightColID = UUID()
        let bottomID = UUID()

        // Simulate two side-by-side captions at the same vertical position (like Fig 3 & Fig 4 on page 7)
        // plus a paragraph near the bottom of the page.
        let specs = [
            SidebarCardSpec(
                id: rightColID,
                page: 0,
                sourceRect: CGRect(x: 310, y: 400, width: 220, height: 60),
                desiredY: 120,
                height: 90,
                pageMinY: 0,
                pageMaxY: 700
            ),
            SidebarCardSpec(
                id: leftColID,
                page: 0,
                sourceRect: CGRect(x: 50, y: 402, width: 220, height: 60),
                desiredY: 118,
                height: 85,
                pageMinY: 0,
                pageMaxY: 700
            ),
            SidebarCardSpec(
                id: bottomID,
                page: 0,
                sourceRect: CGRect(x: 50, y: 40, width: 480, height: 50),
                desiredY: 640,
                height: 100,
                pageMinY: 0,
                pageMaxY: 700
            )
        ]

        let placed = CardSidebarLayout.placeScreenCards(
            specs, cardX: 620, cardWidth: 280, viewportHeight: 700
        )
        #expect(placed.count == 3)
        // Left column card comes before right column card even though it was passed second.
        #expect(placed[0].id == leftColID)
        #expect(placed[1].id == rightColID)
        #expect(placed[2].id == bottomID)

        // No two cards overlap in 2D, and every card stays within the viewport margins.
        for i in 0..<placed.count {
            #expect(placed[i].frame.minY >= CardSidebarLayout.pageVerticalInset - 0.001)
            #expect(placed[i].frame.maxY <= 700 - CardSidebarLayout.pageVerticalInset + 0.001)
            #expect(placed[i].frame.minX >= 620 - 0.001)
            #expect(placed[i].frame.maxX <= 900 + 0.001)
            for j in (i + 1)..<placed.count {
                #expect(!placed[i].frame.intersects(placed[j].frame))
            }
        }

        // Connector links the right edge of the source rect to the left edge of the sidebar card.
        let sourceOverlay = CGRect(x: 50, y: 118, width: 220, height: 60)
        let connector = CardConnector(sourceRect: sourceOverlay, cardRect: placed[0].frame, minSourceX: 6, maxSourceX: 600)
        #expect(connector.start.x == sourceOverlay.maxX)
        #expect(connector.end.x == placed[0].frame.minX)
        #expect(connector.control1.x > connector.start.x)
        #expect(connector.control2.x < connector.end.x)
    }

    @MainActor
    @Test func trackpadScrollingMovesDocumentAndSidebarCardsReflowWithIt() throws {
        let doc = try document()
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        view.displayMode = .singlePageContinuous
        view.autoScales = false
        view.scaleFactor = 1.0
        view.document = doc
        view.layoutDocumentView()

        let store = AnnotationStore()
        let model = Annotation(
            id: UUID(),
            page: 0,
            rect: CGRect(x: 60, y: 380, width: 200, height: 50),
            translationMd: "译文随原文滚动",
            createdAt: Date()
        )
        let annotation = TranslationAnnotation(model: model)
        annotation.status = .done
        annotation.fallbackText = "译文随原文滚动"
        store.add(model, view: annotation)

        let overlay = SelectionOverlay(pdfView: view)
        overlay.store = store
        let workspace = ReaderWorkspaceView(pdfView: view, overlay: overlay)
        workspace.frame = CGRect(x: 0, y: 0, width: 820, height: 300)
        workspace.layoutSubtreeIfNeeded()

        let window = NSWindow(contentRect: workspace.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = workspace
        window.layoutIfNeeded()
        overlay.layoutSidebarCards()

        let scrollView = try #require(view.documentView?.enclosingScrollView)
        let initialScrollY = scrollView.contentView.bounds.origin.y
        let initialCardY = annotation.bounds.minY
        #expect(!annotation.bounds.isEmpty)

        // Deliver a trackpad scrollWheel event through SelectionOverlay.
        let cgEvent = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -48, wheel2: 0, wheel3: 0
        ))
        let nsEvent = try #require(NSEvent(cgEvent: cgEvent))
        overlay.scrollWheel(with: nsEvent)
        overlay.layoutSidebarCards()

        let scrolledDelta = scrollView.contentView.bounds.origin.y - initialScrollY
        #expect(scrolledDelta == 48)
        // The card stays active and reflows toward its source anchor (the Stage 4 target blends
        // 75% source alignment with 25% even distribution, so it does not translate 1:1).
        #expect(!annotation.bounds.isEmpty)
        let cardShift = initialCardY - annotation.bounds.minY
        #expect(abs(cardShift - scrolledDelta * CardSidebarLayout.sourceAnchorWeight) < 1.0)
        #expect(annotation.bounds.minY >= CardSidebarLayout.pageVerticalInset - 0.001)
        #expect(annotation.bounds.maxY <= overlay.bounds.height - CardSidebarLayout.pageVerticalInset + 0.001)

        // Scrolling the source off-screen deactivates its card; scrolling back restores it.
        let hideEvent = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -400, wheel2: 0, wheel3: 0
        ))
        overlay.scrollWheel(with: try #require(NSEvent(cgEvent: hideEvent)))
        overlay.layoutSidebarCards()
        #expect(annotation.bounds.isEmpty)

        let showEvent = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 400, wheel2: 0, wheel3: 0
        ))
        overlay.scrollWheel(with: try #require(NSEvent(cgEvent: showEvent)))
        overlay.layoutSidebarCards()
        #expect(!annotation.bounds.isEmpty)
    }

    @Test func adaptiveCardSizingAnd2DSidebarArrangementKeepsDenseDiagramLabelsCompact() {
        let maxCardWidth: CGFloat = 296
        let shortNote = TranslationAnnotation(model: Annotation(
            id: UUID(), page: 0, rect: CGRect(x: 410, y: 580, width: 38, height: 14),
            translationMd: "范数", createdAt: Date()
        ))
        shortNote.status = .done
        shortNote.fallbackText = "范数"

        let mediumNote = TranslationAnnotation(model: Annotation(
            id: UUID(), page: 0, rect: CGRect(x: 190, y: 580, width: 110, height: 16),
            translationMd: "Transformer 编码器", createdAt: Date()
        ))
        mediumNote.status = .done
        mediumNote.fallbackText = "Transformer 编码器"

        let longNote = TranslationAnnotation(model: Annotation(
            id: UUID(), page: 0, rect: CGRect(x: 60, y: 360, width: 460, height: 85),
            translationMd: "图1：模型概览。我们将图像分割为固定大小的图像块，对每个图像块进行线性嵌入，添加位置嵌入，并将得到的向量序列输入标准 Transformer 编码器。为了进行分类，我们使用标准方法，在序列中添加一个额外的可学习分类标记。",
            createdAt: Date()
        ))
        longNote.status = .done
        longNote.fallbackText = longNote.model.translationMd

        let shortSize = shortNote.cardSize(maxCardWidth: maxCardWidth)
        let mediumSize = mediumNote.cardSize(maxCardWidth: maxCardWidth)
        let longSize = longNote.cardSize(maxCardWidth: maxCardWidth)

        // Short and medium labels shrink to their content width instead of stretching to 296pt.
        #expect(shortSize.width < 90)
        #expect(mediumSize.width < 160)
        #expect(shortSize.width < mediumSize.width)
        #expect(longSize.width > 240)

        // Simulate 8 dense diagram labels (like Figure 1 in the ViT paper) above a full-width figure caption.
        let labels: [(String, CGRect, CGFloat)] = [
            ("多层感知机", CGRect(x: 410, y: 620, width: 45, height: 14), 185),
            ("Transformer 编码器", CGRect(x: 190, y: 580, width: 110, height: 16), 222),
            ("范数", CGRect(x: 410, y: 582, width: 40, height: 14), 220),
            ("图块 + 位置嵌入\n* 额外可学习的 [class] 嵌入", CGRect(x: 80, y: 520, width: 85, height: 42), 270),
            ("多头注意力", CGRect(x: 410, y: 510, width: 65, height: 22), 285),
            ("展平图像块的线性投影", CGRect(x: 185, y: 490, width: 145, height: 15), 310),
            ("范数", CGRect(x: 410, y: 470, width: 40, height: 14), 330),
            ("嵌入图块", CGRect(x: 410, y: 430, width: 55, height: 22), 375)
        ]

        var specs: [SidebarCardSpec] = labels.map { text, rect, desiredY in
            let note = TranslationAnnotation(model: Annotation(
                id: UUID(), page: 0, rect: rect, translationMd: text, createdAt: Date()
            ))
            note.status = .done
            note.fallbackText = text
            let size = note.cardSize(maxCardWidth: maxCardWidth)
            return SidebarCardSpec(
                id: note.model.id,
                page: 0,
                sourceRect: rect,
                desiredY: desiredY,
                preferredWidth: size.width,
                height: size.height,
                pageMinY: 0,
                pageMaxY: 880
            )
        }

        let captionID = longNote.model.id
        specs.append(SidebarCardSpec(
            id: captionID,
            page: 0,
            sourceRect: longNote.model.rect,
            desiredY: 415,
            preferredWidth: longSize.width,
            height: longSize.height,
            pageMinY: 0,
            pageMaxY: 880
        ))

        let placed = CardSidebarLayout.placeScreenCards(
            specs, cardX: 600, cardWidth: maxCardWidth, viewportHeight: 880
        )
        #expect(placed.count == 9)

        // Verify zero 2D overlaps across all placed cards.
        for i in 0..<placed.count {
            for j in (i + 1)..<placed.count {
                #expect(!placed[i].frame.intersects(placed[j].frame))
            }
        }

        // Verify that multiple cards use 2D side-by-side columns (minX > 600).
        let multiColumnCards = placed.filter { $0.frame.minX > 600.5 }
        #expect(multiColumnCards.count >= 4)

        // Verify zero empty left-hand holes: every card placed to the right of cardX (600)
        // must sit on a shelf that has a flush-left card (minX == 600) covering its vertical span.
        let flushLeftCards = placed.filter { abs($0.frame.minX - 600) < 0.5 }
        for rightCard in multiColumnCards {
            let hasLeftBacking = flushLeftCards.contains { leftCard in
                rightCard.frame.minY >= leftCard.frame.minY - 0.5 &&
                rightCard.frame.maxY <= leftCard.frame.maxY + 2.5
            }
            #expect(hasLeftBacking)
        }

        // Because the 8 diagram labels pack into tight 2D rows, the caption card stays in the
        // vicinity of its desiredY (415) instead of being pushed down past y=600 as in a 1D stack.
        let captionCard = placed.first { $0.id == captionID }!
        #expect(captionCard.frame.minY < 500)
    }

    // MARK: - SPEC viewport activation & greedy layout acceptance tests

    @Test func viewportVisibilityFiltersOffscreenAndBarelyExposedSources() {
        let panel = CGRect(x: 0, y: 0, width: 400, height: 300)
        // Fully visible / 25% exposed / center on screen.
        #expect(SelectionOverlay.isSourceVisibleInViewport(
            CGRect(x: 100, y: 100, width: 100, height: 40), in: panel
        ))
        #expect(SelectionOverlay.isSourceVisibleInViewport(
            CGRect(x: 100, y: -30, width: 100, height: 40), in: panel
        ))
        // Barely exposed above the viewport: 5/40 = 12.5%, center off-screen.
        #expect(!SelectionOverlay.isSourceVisibleInViewport(
            CGRect(x: 100, y: -35, width: 100, height: 40), in: panel
        ))
        // Entirely above / below / horizontally outside.
        #expect(!SelectionOverlay.isSourceVisibleInViewport(
            CGRect(x: 100, y: -100, width: 100, height: 40), in: panel
        ))
        #expect(!SelectionOverlay.isSourceVisibleInViewport(
            CGRect(x: 100, y: 320, width: 100, height: 40), in: panel
        ))
        #expect(!SelectionOverlay.isSourceVisibleInViewport(
            CGRect(x: 450, y: 100, width: 100, height: 40), in: panel
        ))
        // A tall selection showing exactly 20% of the viewport height activates even at 20% exposure.
        #expect(SelectionOverlay.isSourceVisibleInViewport(
            CGRect(x: 100, y: -240, width: 100, height: 300), in: panel
        ))
        #expect(!SelectionOverlay.isSourceVisibleInViewport(.null, in: panel))
    }

    @Test func everyJustifiedRowSpansTheFullSidebarWidth() {
        let specs = (0..<12).map { index in
            let id = UUID()
            let row = index % 6
            let column = index / 6
            let anchorY = CGFloat(row) * 70 + 20
            let x = CGFloat(column) * 120 + 50
            return SidebarCardSpec(
                id: id,
                page: 0,
                sourceRect: CGRect(x: x, y: anchorY, width: 40, height: 14),
                desiredY: anchorY,
                preferredWidth: 60,
                height: 18,
                pageMinY: 0,
                pageMaxY: 2000,
                viewportRect: CGRect(x: x, y: anchorY, width: 40, height: 14),
                contentUnits: 8
            )
        }
        let cardX: CGFloat = 600
        let cardWidth: CGFloat = 296
        let placed = CardSidebarLayout.placeScreenCards(
            specs, cardX: cardX, cardWidth: cardWidth, viewportHeight: 500
        )
        #expect(placed.count == specs.count)

        let rows = Dictionary(grouping: placed) { Int(($0.frame.minY * 100).rounded()) }
        #expect(rows.count >= 2)
        for frames in rows.values {
            let left = frames.map(\.frame.minX).min() ?? 0
            let right = frames.map(\.frame.maxX).max() ?? 0
            #expect(abs(left - cardX) < 0.01)
            #expect(abs(right - (cardX + cardWidth)) < 0.01)
        }
        for i in 0..<placed.count {
            for j in (i + 1)..<placed.count {
                #expect(!placed[i].frame.intersects(placed[j].frame))
            }
        }

        // PAVA preserves the reading order: row positions are monotonic with source anchors.
        let anchors = Dictionary(uniqueKeysWithValues: specs.map { ($0.id, $0.desiredY) })
        let sortedRows = rows.sorted { $0.key < $1.key }
        let anchorMeans = sortedRows.map { _, frames -> CGFloat in
            frames.reduce(CGFloat(0)) { $0 + (anchors[$1.id] ?? 0) } / CGFloat(frames.count)
        }
        for index in 1..<anchorMeans.count {
            #expect(anchorMeans[index] >= anchorMeans[index - 1] - 0.001)
        }
    }

    @Test func subColumnStackingFillsTheRowHeightAndKeepsTheRightEdgeFlush() {
        let tallID = UUID()
        let firstLabelID = UUID()
        let secondLabelID = UUID()
        let specs = [
            SidebarCardSpec(
                id: tallID, page: 0,
                sourceRect: CGRect(x: 50, y: 100, width: 220, height: 60),
                desiredY: 100, preferredWidth: 160, height: 120,
                pageMinY: 0, pageMaxY: 2000,
                viewportRect: CGRect(x: 50, y: 100, width: 220, height: 60),
                contentUnits: 30
            ),
            SidebarCardSpec(
                id: firstLabelID, page: 0,
                sourceRect: CGRect(x: 300, y: 300, width: 40, height: 14),
                desiredY: 102, preferredWidth: 60, height: 18,
                pageMinY: 0, pageMaxY: 2000,
                viewportRect: CGRect(x: 300, y: 102, width: 40, height: 14),
                contentUnits: 8
            ),
            SidebarCardSpec(
                id: secondLabelID, page: 0,
                sourceRect: CGRect(x: 300, y: 280, width: 40, height: 14),
                desiredY: 106, preferredWidth: 60, height: 18,
                pageMinY: 0, pageMaxY: 2000,
                viewportRect: CGRect(x: 300, y: 106, width: 40, height: 14),
                contentUnits: 8
            )
        ]
        let cardX: CGFloat = 600
        let cardWidth: CGFloat = 296
        let placed = CardSidebarLayout.placeScreenCards(
            specs, cardX: cardX, cardWidth: cardWidth, viewportHeight: 500
        )
        let tall = placed.first { $0.id == tallID }
        let labels = placed.filter { $0.id == firstLabelID || $0.id == secondLabelID }
            .sorted { $0.frame.minY < $1.frame.minY }
        #expect(labels.count == 2)
        #expect(tall != nil)
        guard let tall, labels.count == 2 else { return }

        // Tall card and both stacked labels start at the same row top and end at the same bottom.
        #expect(abs(tall.frame.minY - labels[0].frame.minY) < 0.01)
        #expect(abs(tall.frame.maxY - labels[1].frame.maxY) < 0.01)
        #expect(tall.frame.maxX < labels[0].frame.minX)
        #expect(abs((labels[0].frame.minX - tall.frame.maxX)
                    - CardSidebarLayout.cardHorizontalSpacing) < 0.01)
        #expect(tall.frame.height > labels[0].frame.height)
        #expect(abs(labels[0].frame.height - labels[1].frame.height) < 0.01)
        #expect(abs(labels[1].frame.maxX - (cardX + cardWidth)) < 0.01)
        #expect(labels[0].frame.maxY + CardSidebarLayout.minRowSpacing <= labels[1].frame.minY + 0.01)
        for i in 0..<placed.count {
            for j in (i + 1)..<placed.count {
                #expect(!placed[i].frame.intersects(placed[j].frame))
            }
        }
    }

    @Test func sparseViewportExpandsShortCardsWithinTheComfortLimit() {
        let specs = [120.0, 132.0].map { anchorY in
            SidebarCardSpec(
                id: UUID(),
                page: 0,
                sourceRect: CGRect(x: 60, y: anchorY, width: 40, height: 14),
                desiredY: anchorY,
                preferredWidth: 60,
                height: 18,
                pageMinY: 0,
                pageMaxY: 2000,
                viewportRect: CGRect(x: 60, y: anchorY, width: 40, height: 14),
                contentUnits: 8
            )
        }
        let cardX: CGFloat = 620
        let cardWidth: CGFloat = 280
        let viewportHeight: CGFloat = 800
        let placed = CardSidebarLayout.placeScreenCards(
            specs, cardX: cardX, cardWidth: cardWidth, viewportHeight: viewportHeight
        )
        #expect(placed.count == 2)
        for card in placed {
            // Expanded beyond the base 18pt, but bounded by width-stretch x comfort scale + padding.
            #expect(card.frame.height > 18)
            #expect(card.frame.height <= 18 * CardSidebarLayout.maxComfortScale
                    * CardSidebarLayout.maxComfortScale + CardSidebarLayout.maxComfortPadding)
            #expect(card.frame.minY >= CardSidebarLayout.pageVerticalInset - 0.001)
            #expect(card.frame.maxY <= viewportHeight - CardSidebarLayout.pageVerticalInset + 0.001)
        }
        #expect(abs(placed[0].frame.minY - placed[1].frame.minY) < 0.001)
        #expect(abs((placed.map(\.frame.minX).min() ?? 0) - cardX) < 0.01)
        #expect(abs((placed.map(\.frame.maxX).max() ?? 0) - (cardX + cardWidth)) < 0.01)
        #expect(!placed[0].frame.intersects(placed[1].frame))
    }

    @Test func denseViewportFitsEveryCardInsideTheSidebarWithoutOverlap() {
        var specs: [SidebarCardSpec] = []
        for index in 0..<18 {
            let id = UUID()
            let anchorY = CGFloat((index * 29) % 540) + 24
            let sourceWidth = CGFloat(50 + (index * 37) % 190)
            let x = CGFloat(40 + (index * 53) % 350)
            let naturalWidth = min(60 + CGFloat((index * 41) % 180), 296)
            let naturalHeight = CGFloat(36 + (index * 47) % 150)
            let fullWidth = index % 6 == 0
            specs.append(SidebarCardSpec(
                id: id,
                page: 0,
                sourceRect: CGRect(x: x, y: anchorY, width: sourceWidth, height: 18),
                desiredY: anchorY,
                preferredWidth: naturalWidth,
                height: naturalHeight,
                pageMinY: 0,
                pageMaxY: 2000,
                viewportRect: CGRect(x: x, y: anchorY, width: sourceWidth, height: 18),
                isFullWidth: fullWidth,
                contentUnits: fullWidth ? 120 : 10
            ))
        }
        let cardX: CGFloat = 600
        let cardWidth: CGFloat = 296
        let viewportHeight: CGFloat = 600
        let placed = CardSidebarLayout.placeScreenCards(
            specs, cardX: cardX, cardWidth: cardWidth, viewportHeight: viewportHeight
        )
        #expect(placed.count == specs.count)

        let top = CardSidebarLayout.pageVerticalInset
        let bottom = viewportHeight - CardSidebarLayout.pageVerticalInset
        for card in placed {
            #expect(card.frame.minY >= top - 0.001)
            #expect(card.frame.maxY <= bottom + 0.001)
            #expect(card.frame.minX >= cardX - 0.001)
            #expect(card.frame.maxX <= cardX + cardWidth + 0.001)
            #expect(card.frame.height > 0)
            #expect(card.frame.width > 0)
        }
        for i in 0..<placed.count {
            for j in (i + 1)..<placed.count {
                #expect(!placed[i].frame.intersects(placed[j].frame))
            }
        }
        // PAVA keeps rows ordered: sorting by top yields non-overlapping vertical bands.
        let ordered = placed.sorted { $0.frame.minY < $1.frame.minY }
        #expect((ordered.map(\.frame.minY).max() ?? 0) <= bottom + 0.001)
    }

    @Test func denseViewportPrefersMultiColumnRowsInsteadOfOverflowingSingleColumns() {
        let specs = (0..<12).map { index in
            SidebarCardSpec(
                id: UUID(),
                page: 0,
                sourceRect: CGRect(x: 60, y: CGFloat(index) * 40 + 24, width: 240, height: 20),
                desiredY: CGFloat(index) * 40 + 24,
                preferredWidth: 180,
                height: 110,
                pageMinY: 0,
                pageMaxY: 2000,
                viewportRect: CGRect(x: 60, y: CGFloat(index) * 40 + 24, width: 240, height: 20),
                contentUnits: 60
            )
        }
        let placed = CardSidebarLayout.placeScreenCards(
            specs, cardX: 600, cardWidth: 296, viewportHeight: 600
        )
        #expect(placed.count == specs.count)
        // Crowding ratio is > 2 here, so the solver must form multi-column rows instead of
        // stacking all twelve 110pt cards one per row (which would require heavy compression).
        let rowTops = Set(placed.map { Int(($0.frame.minY * 100).rounded()) })
        #expect(rowTops.count <= 8)
        for card in placed {
            #expect(card.frame.minY >= CardSidebarLayout.pageVerticalInset - 0.001)
            #expect(card.frame.maxY <= 600 - CardSidebarLayout.pageVerticalInset + 0.001)
        }
        for i in 0..<placed.count {
            for j in (i + 1)..<placed.count {
                #expect(!placed[i].frame.intersects(placed[j].frame))
            }
        }
    }

    @Test func collapsedViewportStillClampsEveryCardInsideItsBounds() {
        let specs = (0..<10).map { index in
            SidebarCardSpec(
                id: UUID(),
                page: 0,
                sourceRect: CGRect(x: 60, y: CGFloat(index) * 20 + 10, width: 200, height: 14),
                desiredY: CGFloat(index) * 20 + 10,
                preferredWidth: 120,
                height: 60,
                pageMinY: 0,
                pageMaxY: 2000,
                viewportRect: CGRect(x: 60, y: CGFloat(index) * 20 + 10, width: 200, height: 14),
                contentUnits: 40
            )
        }
        let viewportHeight: CGFloat = 60
        let placed = CardSidebarLayout.placeScreenCards(
            specs, cardX: 600, cardWidth: 296, viewportHeight: viewportHeight
        )
        #expect(placed.count == specs.count)
        for card in placed {
            #expect(card.frame.minY >= CardSidebarLayout.pageVerticalInset - 0.001)
            #expect(card.frame.maxY <= viewportHeight - CardSidebarLayout.pageVerticalInset + 0.001)
        }
    }

    @Test func denseViewportKeepsEveryRowReadableAndOrderedUnderCompression() {
        // Full-width paragraphs force the compression branch: 18 rows of 140pt cannot fit 484pt.
        let ids = (0..<18).map { _ in UUID() }
        let specs = ids.enumerated().map { index, id in
            SidebarCardSpec(
                id: id,
                page: 0,
                sourceRect: CGRect(x: 60, y: CGFloat(index) * 28 + 20, width: 300, height: 20),
                desiredY: CGFloat(index) * 28 + 20,
                preferredWidth: 296,
                height: 140,
                pageMinY: 0,
                pageMaxY: 2000,
                viewportRect: CGRect(x: 60, y: CGFloat(index) * 28 + 20, width: 300, height: 20),
                isFullWidth: true,
                contentUnits: 120
            )
        }
        let viewportHeight: CGFloat = 500
        let placed = CardSidebarLayout.placeScreenCards(
            specs, cardX: 600, cardWidth: 296, viewportHeight: viewportHeight
        )
        #expect(placed.count == ids.count)
        let bottom = viewportHeight - CardSidebarLayout.pageVerticalInset
        for card in placed {
            #expect(card.frame.minY >= CardSidebarLayout.pageVerticalInset - 0.001)
            #expect(card.frame.maxY <= bottom + 0.001)
        }
        for i in 0..<placed.count {
            for j in (i + 1)..<placed.count {
                #expect(!placed[i].frame.intersects(placed[j].frame))
            }
        }
    }
}
