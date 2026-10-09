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

    @Test func outlineTargetSurvivesAddingAndRemovingTranslationSlots() throws {
        let original = try document()
        let data = try #require(original.dataRepresentation())
        let displayed = try #require(PDFDocument(data: data))
        let target = PDFNavigationTarget(pageIndex: 1, point: CGPoint(x: 50, y: 450))
        let stalePage = try #require(displayed.page(at: 1))
        let layout = GapLayout([PageGap(id: UUID(), y: 300, height: 75)])
        let built = try #require(PageGapper.build(from: original.page(at: 1)!, layout: layout, box: .mediaBox))
        displayed.removePage(at: 1)
        displayed.insert(built.page, at: 1)
        let expanded = try #require(target.destination(in: displayed, layout: layout))
        #expect(expanded.page === displayed.page(at: 1))
        #expect(expanded.page !== stalePage)
        #expect(expanded.point == CGPoint(x: 50, y: 525))
        #expect(expanded.zoom == kPDFDestinationUnspecifiedValue)

        displayed.removePage(at: 1)
        displayed.insert(original.page(at: 1)!.copy() as! PDFPage, at: 1)
        let restored = try #require(target.destination(in: displayed, layout: .empty))
        #expect(restored.page === displayed.page(at: 1))
        #expect(restored.point == CGPoint(x: 50, y: 450))
    }

    @Test func pageJumpAndUnspecifiedOutlineCoordinatesUseTheExpandedPageTop() throws {
        let doc = try document()
        let layout = GapLayout([PageGap(id: UUID(), y: 300, height: 75)])
        let built = try #require(PageGapper.build(from: doc.page(at: 0)!, layout: layout, box: .mediaBox))
        doc.removePage(at: 0)
        doc.insert(built.page, at: 0)
        for target in [PDFNavigationTarget(pageIndex: 0),
                       PDFNavigationTarget(pageIndex: 0, point: CGPoint(x: kPDFDestinationUnspecifiedValue, y: .nan))] {
            let destination = try #require(target.destination(in: doc, layout: layout))
            #expect(destination.point == CGPoint(x: 20, y: 605))
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
        #expect(PDFNavigationTarget(pageIndex: -1).destination(in: doc, layout: .empty) == nil)
        #expect(PDFNavigationTarget(pageIndex: 3).destination(in: doc, layout: .empty) == nil)
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
        let first = try #require(PDFNavigationTarget(pageIndex: 0).destination(in: current, layout: .empty))
        view.go(to: first)
        model.viewportDidChange()
        #expect(model.currentPageIndex == 0)
        #expect(!model.canGoToPreviousPage)
        #expect(model.canGoToNextPage)

        let second = try #require(PDFNavigationTarget(pageIndex: 1).destination(in: current, layout: .empty))
        view.go(to: second)
        model.viewportDidChange()
        #expect(model.currentPageIndex == 1)
    }
}
