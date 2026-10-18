import CoreGraphics
import Foundation

/// Input specification for placing a translation floating card in the right sidebar.
struct SidebarCardSpec: Equatable {
    let id: UUID
    let page: Int
    /// Original selection rectangle in PDF page coordinates (y-up).
    let sourceRect: CGRect
    /// Desired anchor Y in target coordinate space (minY when yDown is true, maxY when yDown is false).
    let desiredY: CGFloat
    /// Adaptive preferred outer width for the card (if nil, uses the full available sidebar width).
    let preferredWidth: CGFloat?
    /// Tight outer height of the card at its natural width.
    let height: CGFloat
    /// Page bounds kept for callers that still reason about the source page.
    let pageMinY: CGFloat
    let pageMaxY: CGFloat
    /// Source rectangle in layout coordinates (y-down). Screen layouts pass the overlay rect,
    /// export layouts pass `pageBounds.maxY - sourceRect.maxY`. Falls back to `desiredY`.
    let viewportRect: CGRect?
    /// A paragraph/table/display equation that gets the full row unless the viewport is crowded.
    let isFullWidth: Bool
    /// Estimated content volume (character units); small values identify compact labels.
    let contentUnits: CGFloat

    init(
        id: UUID,
        page: Int,
        sourceRect: CGRect,
        desiredY: CGFloat,
        preferredWidth: CGFloat? = nil,
        height: CGFloat,
        pageMinY: CGFloat,
        pageMaxY: CGFloat,
        viewportRect: CGRect? = nil,
        isFullWidth: Bool = false,
        contentUnits: CGFloat = 0
    ) {
        self.id = id
        self.page = page
        self.sourceRect = sourceRect
        self.desiredY = desiredY
        self.preferredWidth = preferredWidth
        self.height = height
        self.pageMinY = pageMinY
        self.pageMaxY = pageMaxY
        self.viewportRect = viewportRect
        self.isFullWidth = isFullWidth
        self.contentUnits = contentUnits
    }

    /// Source rectangle expressed in the y-down layout space used by the solver.
    var layoutSourceRect: CGRect {
        if let viewportRect, viewportRect.width.isFinite, viewportRect.height.isFinite,
           viewportRect.width > 0, viewportRect.height > 0 {
            return viewportRect
        }
        return CGRect(
            x: sourceRect.minX,
            y: desiredY,
            width: max(sourceRect.width, 1),
            height: max(sourceRect.height, 1)
        )
    }
}

/// A resolved floating card frame in the sidebar.
struct PlacedSidebarCard: Equatable {
    let id: UUID
    let page: Int
    let frame: CGRect
}

/// Cubic Bézier leader line connecting a boxed source region on the PDF to its floating card in the sidebar.
struct CardConnector: Equatable {
    let start: CGPoint
    let control1: CGPoint
    let control2: CGPoint
    let end: CGPoint

    init(sourceRect: CGRect, cardRect: CGRect, minSourceX: CGFloat = -.greatestFiniteMagnitude,
         maxSourceX: CGFloat = .greatestFiniteMagnitude) {
        let source = sourceRect.standardized
        let card = cardRect.standardized
        let valid = source.width.isFinite && source.height.isFinite
            && source.minX.isFinite && source.minY.isFinite
            && card.width.isFinite && card.height.isFinite
            && card.minX.isFinite && card.minY.isFinite
            && !source.isNull && !source.isEmpty && !card.isNull && !card.isEmpty
        guard valid else {
            self.start = .zero
            self.end = .zero
            self.control1 = .zero
            self.control2 = .zero
            return
        }

        // Leave the source at its vertical center and enter the card at the nearest point.
        // Using the card's midpoint for the start (the old behavior) made lines drift away
        // from the paragraph they belonged to and converge into a single fan.
        let sx = min(max(source.maxX, minSourceX), maxSourceX)
        let sy = source.midY
        let ex = card.minX
        let eyInset = min(12, card.height * 0.5)
        let ey = min(max(sy, card.minY + eyInset), card.maxY - eyInset)

        let span = max(ex - sx, 24)
        self.start = CGPoint(x: sx, y: sy)
        self.end = CGPoint(x: ex, y: ey)
        self.control1 = CGPoint(x: sx + span * 0.42, y: sy)
        self.control2 = CGPoint(x: ex - span * 0.42, y: ey)
    }

    func addPath(to context: CGContext) {
        context.move(to: start)
        context.addCurve(to: end, control1: control1, control2: control2)
    }

    func addPath(to path: CGMutablePath) {
        path.move(to: start)
        path.addCurve(to: end, control1: control1, control2: control2)
    }
}

/// Viewport-aware sidebar layout.
///
/// The pipeline follows the SPEC's four stages:
/// 1. viewport filtering / reading order is done by the caller (off-screen cards are removed);
/// 2. Knuth-Plass style dynamic programming forms rows, fills every row horizontally to 100%,
///    and stacks compact labels into sub-columns beside a taller card;
/// 3. a TeX-like box-and-glue pass expands rows toward a comfortable reading size or compresses
///    them so every visible card fits inside the sidebar viewport;
/// 4. a boundary-labeling PAVA isotonic regression places rows as close to their source anchors
///    as possible without overlaps or viewport overflow.
enum CardSidebarLayout {
    static let defaultSidebarWidth: CGFloat = 320
    static let minSidebarWidth: CGFloat = 240
    static let maxSidebarWidth: CGFloat = 520
    static let cardHorizontalInset: CGFloat = 14
    static let cardSpacing: CGFloat = 10
    static let cardHorizontalSpacing: CGFloat = 10
    /// Hard lower bound for a card in a multi-column row (SPEC §3.2.2).
    static let minCardWidth: CGFloat = 42
    static let pageVerticalInset: CGFloat = 14

    /// Maximum cards in a single row (SPEC Stage 2).
    static let maxCardsPerRow = 4
    /// Rows may tighten to this gap before their heights are compressed.
    static let minRowSpacing: CGFloat = 5
    /// Upper bound for comfort expansion (SPEC Stage 3).
    static let maxComfortScale: CGFloat = 1.5
    /// Blend between source-anchor alignment and even viewport distribution (SPEC Stage 4).
    static let sourceAnchorWeight: CGFloat = 0.55
    /// Maximum extra vertical padding added to each row in the comfort pass.
    static let maxComfortPadding: CGFloat = 18
    /// Pure label rows expand far less: short badges should stay crisp instead of
    /// turning into tall empty boxes when the sidebar has spare height.
    static let compactRowComfortScale: CGFloat = 1.18
    static let compactRowPadding: CGFloat = 8

    // MARK: - Reading order (SPEC §3.1.3)

    /// Sorts annotations in natural reading order: page ascending, top-to-bottom, and
    /// left-to-right for boxes sharing a horizontal band. `rect` must be y-down.
    static func sortInReadingOrder<T>(
        _ items: [T],
        page: (T) -> Int,
        rect: (T) -> CGRect,
        id: (T) -> UUID
    ) -> [T] {
        let base = items.sorted { a, b in
            let pa = page(a), pb = page(b)
            if pa != pb { return pa < pb }
            let ra = rect(a), rb = rect(b)
            if abs(ra.minY - rb.minY) > 0.01 { return ra.minY < rb.minY }
            if abs(ra.minX - rb.minX) > 0.01 { return ra.minX < rb.minX }
            return id(a).uuidString < id(b).uuidString
        }

        var ordered: [T] = []
        ordered.reserveCapacity(base.count)
        var index = 0
        while index < base.count {
            let bandPage = page(base[index])
            let anchorRect = rect(base[index])
            let anchorY = anchorRect.minY
            let anchorHeight = max(anchorRect.height, 1)
            var band: [T] = []
            while index < base.count, page(base[index]) == bandPage {
                let r = rect(base[index])
                let threshold = max(6, 0.35 * min(anchorHeight, max(r.height, 1)))
                let minHeight = max(min(anchorHeight, max(r.height, 1)), 1)
                // Side-by-side captions often differ by more than the old 6pt top threshold.
                // If their vertical ranges overlap substantially (or their centers are close),
                // they belong to the same visual row and must be ordered left-to-right;
                // otherwise the cards get the opposite column order and their leader lines
                // cross for no reason.
                let overlap = max(0, min(anchorRect.maxY, r.maxY) - max(anchorRect.minY, r.minY))
                let overlaps = overlap >= 0.35 * minHeight
                let centersClose = abs(anchorRect.midY - r.midY) <= 0.5 * minHeight
                if !band.isEmpty, r.minY - anchorY > threshold, !overlaps, !centersClose { break }
                band.append(base[index])
                index += 1
            }
            band.sort { a, b in
                let ra = rect(a), rb = rect(b)
                if abs(ra.minX - rb.minX) > 0.01 { return ra.minX < rb.minX }
                if abs(ra.minY - rb.minY) > 0.01 { return ra.minY < rb.minY }
                return id(a).uuidString < id(b).uuidString
            }
            ordered.append(contentsOf: band)
        }
        return ordered
    }

    // MARK: - Screen layout (y-down overlay coordinates)

    /// Places cards in screen/overlay coordinates (y-down: origin at top-left, y increases downward).
    /// Every returned frame lies inside `[pageVerticalInset, viewportHeight - pageVerticalInset]`
    /// and every row spans the full available sidebar width.
    static func placeScreenCards(
        _ specs: [SidebarCardSpec],
        cardX: CGFloat,
        cardWidth: CGFloat,
        viewportHeight: CGFloat,
        spacing: CGFloat = cardSpacing
    ) -> [PlacedSidebarCard] {
        guard !specs.isEmpty else { return [] }
        let availableWidth = max(cardWidth, 1)
        let viewport = max(viewportHeight, 2 * pageVerticalInset + 2)
        let yMin = pageVerticalInset
        let yMax = viewport - pageVerticalInset
        let ordered = sortInReadingOrder(specs, page: \.page, rect: \.layoutSourceRect, id: \.id)
        let items = makeItems(ordered, availableWidth: availableWidth)
        let frames = layoutFrames(
            items: items,
            cardX: cardX,
            availableWidth: availableWidth,
            viewportMinY: yMin,
            viewportMaxY: yMax,
            horizontalSpacing: cardHorizontalSpacing,
            verticalSpacing: spacing
        )
        return items.enumerated().map { offset, item in
            PlacedSidebarCard(id: item.spec.id, page: item.spec.page, frame: frames[offset])
        }
    }

    // MARK: - Export layout (y-up PDF coordinates)

    /// Places cards for a single page in PDF export coordinates (y-up: origin at bottom-left).
    /// The page height is used as the viewport, so the solver never grows the exported media box:
    /// `lowestY` is always `pageBounds.minY`.
    static func placeExportCards(
        _ specs: [SidebarCardSpec],
        cardX: CGFloat,
        cardWidth: CGFloat,
        pageBounds: CGRect,
        spacing: CGFloat = cardSpacing
    ) -> (cards: [PlacedSidebarCard], lowestY: CGFloat) {
        guard !specs.isEmpty else { return ([], pageBounds.minY) }
        let availableWidth = max(cardWidth, 1)
        // Export math runs in a y-down local space anchored at the page top so the screen and
        // export paths share one solver; convert the source boxes once up front.
        let normalized = specs.map { spec in
            SidebarCardSpec(
                id: spec.id,
                page: spec.page,
                sourceRect: spec.sourceRect,
                desiredY: spec.desiredY,
                preferredWidth: spec.preferredWidth,
                height: spec.height,
                pageMinY: spec.pageMinY,
                pageMaxY: spec.pageMaxY,
                viewportRect: CGRect(
                    x: spec.sourceRect.minX,
                    y: pageBounds.maxY - spec.sourceRect.maxY,
                    width: max(spec.sourceRect.width, 1),
                    height: max(spec.sourceRect.height, 1)
                ),
                isFullWidth: spec.isFullWidth,
                contentUnits: spec.contentUnits
            )
        }
        let ordered = sortInReadingOrder(normalized, page: \.page, rect: \.layoutSourceRect, id: \.id)
        let items = makeItems(ordered, availableWidth: availableWidth)
        let framesDown = layoutFrames(
            items: items,
            cardX: cardX,
            availableWidth: availableWidth,
            viewportMinY: pageVerticalInset,
            viewportMaxY: max(pageBounds.height - pageVerticalInset, pageVerticalInset),
            horizontalSpacing: cardHorizontalSpacing,
            verticalSpacing: spacing
        )

        var cards: [PlacedSidebarCard] = []
        cards.reserveCapacity(items.count)
        for (offset, item) in items.enumerated() {
            let down = framesDown[offset]
            let frame = CGRect(
                x: down.minX,
                y: pageBounds.maxY - down.maxY,
                width: down.width,
                height: down.height
            )
            cards.append(PlacedSidebarCard(id: item.spec.id, page: item.spec.page, frame: frame))
        }
        return (cards, pageBounds.minY)
    }

    // MARK: - Stage 2 building blocks

    private struct LayoutItem {
        let spec: SidebarCardSpec
        let sourceRect: CGRect
        let naturalWidth: CGFloat
        let naturalHeight: CGFloat
        let isFullWidth: Bool
        let contentUnits: CGFloat

        /// Compact labels keep a fixed aspect ratio and can stack in a sub-column.
        var isCompactLabel: Bool {
            naturalHeight <= 28 || (contentUnits > 0 && contentUnits <= 18)
        }
    }

    private struct ColumnPlan {
        let itemIndices: [Int]
        let width: CGFloat
        /// Sum of the estimated item heights plus the gaps between them.
        let naturalHeight: CGFloat
        let itemHeights: [CGFloat]
    }

    private struct RowPlan {
        let itemIndices: [Int]
        let columns: [ColumnPlan]
        /// Tallest column; the row is a Bento grid so every column matches this height.
        let baseHeight: CGFloat
        let widthCost: CGFloat
        let heightGrowthCost: CGFloat
        /// Smallest row height that lets the vector content fill the allocated column width
        /// without leaving unused vertical space (uniform-scale aspect fit).
        let visualHeight: CGFloat
        /// Every card in this row is a compact label (no paragraph or block content).
        let isCompactRow: Bool
    }

    private static func makeItems(_ specs: [SidebarCardSpec], availableWidth: CGFloat) -> [LayoutItem] {
        specs.map { spec in
            let preferred = spec.preferredWidth.flatMap { $0.isFinite ? $0 : nil } ?? availableWidth
            let naturalWidth = min(max(ceil(preferred), min(minCardWidth, availableWidth)), availableWidth)
            return LayoutItem(
                spec: spec,
                sourceRect: spec.layoutSourceRect,
                naturalWidth: max(naturalWidth, 1),
                naturalHeight: max(spec.height, 1),
                isFullWidth: spec.isFullWidth,
                contentUnits: spec.contentUnits
            )
        }
    }

    private static func estimatedHeight(for item: LayoutItem, width: CGFloat) -> CGFloat {
        let ratio = width / max(item.naturalWidth, 1)
        if item.isCompactLabel {
            // A one-line badge keeps its line height even when it stretches across a wide
            // column; only the text itself scales up (capped by the renderer). Growing the
            // box with the width is what used to produce tall, empty label cards.
            let scale = min(max(ratio, 0.9), 1.08)
            return max(item.naturalHeight * scale, 8)
        }
        let reflow = min(max(1 / max(ratio, 0.01), 0.75), 1.35)
        return max(item.naturalHeight * reflow, 8)
    }

    /// Evaluates the best arrangement of a contiguous run of items into one row.
    /// Returns `nil` when the row violates the full-width or minimum-width constraints.
    private static func makeRowPlan(
        items: [LayoutItem],
        range: Range<Int>,
        availableWidth: CGFloat,
        horizontalSpacing: CGFloat,
        verticalSpacing: CGFloat,
        crowding: CGFloat
    ) -> RowPlan? {
        let indices = Array(range)
        let count = indices.count
        guard count > 0, count <= maxCardsPerRow else { return nil }

        let hasFullWidth = indices.contains { items[$0].isFullWidth }
        let columnLimit = hasFullWidth ? (crowding >= 1 ? 2 : 1) : maxCardsPerRow
        if count > columnLimit { return nil }

        // Case A (one card per column) uses the 0.85 width weight from SPEC §3.2.2;
        // Case B (sub-column stacking) splits by the raw column weights.
        var candidates: [(groups: [[Int]], weightExponent: CGFloat)] = [
            (indices.map { [$0] }, 0.85)
        ]
        if !hasFullWidth, count >= 3 {
            for split in 1..<count {
                let left = Array(indices[0..<split])
                let right = Array(indices[split...])
                if left.count > 1 || right.count > 1 {
                    candidates.append(([left, right], 1))
                }
            }
        }

        var best: RowPlan?
        for candidate in candidates {
            guard let plan = makeColumnPlan(
                groups: candidate.groups,
                items: items,
                availableWidth: availableWidth,
                horizontalSpacing: horizontalSpacing,
                verticalSpacing: verticalSpacing,
                weightExponent: candidate.weightExponent
            ) else { continue }
            if best == nil || rowPlanScore(plan, crowding: crowding) < rowPlanScore(best!, crowding: crowding) {
                best = plan
            }
        }
        return best
    }

    private static func makeColumnPlan(
        groups: [[Int]],
        items: [LayoutItem],
        availableWidth: CGFloat,
        horizontalSpacing: CGFloat,
        verticalSpacing: CGFloat,
        weightExponent: CGFloat
    ) -> RowPlan? {
        let columnCount = groups.count
        guard columnCount > 0 else { return nil }
        let netWidth = availableWidth - CGFloat(columnCount - 1) * horizontalSpacing
        guard netWidth >= 1 else { return nil }

        let weights = groups.map { group -> CGFloat in
            let widest = group.map { items[$0].naturalWidth }.max() ?? 1
            return pow(max(widest, 1), weightExponent)
        }
        let weightSum = weights.reduce(0, +)
        guard weightSum > 0 else { return nil }

        var columns: [ColumnPlan] = []
        columns.reserveCapacity(columnCount)
        var assigned: CGFloat = 0
        for (columnIndex, group) in groups.enumerated() {
            let width: CGFloat
            if columnIndex == columnCount - 1 {
                width = netWidth - assigned
            } else {
                width = netWidth * weights[columnIndex] / weightSum
                assigned += width
            }
            guard width.isFinite, width > 0 else { return nil }
            // The hard minimum only applies when several columns share the row.
            if columnCount > 1, width < minCardWidth - 0.01 { return nil }

            let itemHeights = group.map { estimatedHeight(for: items[$0], width: width) }
            let naturalHeight = itemHeights.reduce(0, +) + CGFloat(max(group.count - 1, 0)) * verticalSpacing
            columns.append(ColumnPlan(
                itemIndices: group,
                width: width,
                naturalHeight: naturalHeight,
                itemHeights: itemHeights
            ))
        }

        let baseHeight = columns.map(\.naturalHeight).max() ?? 0
        guard baseHeight > 0 else { return nil }

        var widthCost: CGFloat = 0
        var growthCost: CGFloat = 0
        for column in columns {
            for (slot, itemIndex) in column.itemIndices.enumerated() {
                let item = items[itemIndex]
                let ratio = column.width / max(item.naturalWidth, 1)
                if ratio < 1 {
                    widthCost += 80 * pow(1 - ratio, 2)
                }
                if ratio > 2.2 {
                    widthCost += 18 * (ratio - 2.2)
                }
                growthCost += 1.2 * max(0, column.itemHeights[slot] - item.naturalHeight)
            }
        }
        // Prefer balanced columns: empty vertical pockets below short sub-columns read as holes.
        for column in columns {
            growthCost += 0.05 * max(0, baseHeight - column.naturalHeight)
        }

        let allIndices = columns.flatMap(\.itemIndices)
        return RowPlan(
            itemIndices: allIndices,
            columns: columns,
            baseHeight: baseHeight,
            widthCost: widthCost,
            heightGrowthCost: growthCost,
            visualHeight: visualRowHeight(
                columns: columns,
                items: items,
                verticalSpacing: verticalSpacing
            ),
            isCompactRow: allIndices.allSatisfy { items[$0].isCompactLabel }
        )
    }

    /// Height the row would naturally occupy when the vector content is scaled uniformly to
    /// the allocated column width. Stage 3 caps comfort expansion at this value so a wide card
    /// never becomes an empty frame around text limited by its width. Stacked sub-columns add
    /// up their members (plus gaps); taking only the tallest member would under-cap the row and
    /// crush the lower labels.
    private static func visualRowHeight(
        columns: [ColumnPlan],
        items: [LayoutItem],
        verticalSpacing: CGFloat
    ) -> CGFloat {
        var height: CGFloat = 0
        for column in columns {
            var columnHeight: CGFloat = 0
            for (slot, itemIndex) in column.itemIndices.enumerated() {
                let item = items[itemIndex]
                let contentWidth = max(column.width - 2 * TranslationAnnotation.cardInsetX, 1)
                let naturalContentWidth = max(
                    item.naturalWidth - 2 * TranslationAnnotation.cardInsetX, 1
                )
                let contentScale = min(
                    contentWidth / naturalContentWidth,
                    RenderedTranslation.maxContentScale
                )
                let naturalContentHeight = max(
                    item.naturalHeight - 2 * TranslationAnnotation.cardInsetY, 1
                )
                if slot > 0 { columnHeight += verticalSpacing }
                columnHeight += naturalContentHeight * max(contentScale, 0.01)
                    + 2 * TranslationAnnotation.cardInsetY
            }
            height = max(height, columnHeight)
        }
        return height
    }

    private static func rowPlanScore(_ plan: RowPlan, crowding: CGFloat) -> CGFloat {
        plan.widthCost + plan.heightGrowthCost * growthPenaltyWeight(crowding: crowding)
    }

    /// Quadratic height growth matters most in a sparse viewport (comfort reading). Once the
    /// viewport is crowded, the SPEC's row-height cost should drive multi-column packing, so the
    /// extra growth term fades out instead of blocking rows that reduce total height.
    private static func growthPenaltyWeight(crowding: CGFloat) -> CGFloat {
        min(max((1 - crowding) / 0.3, 0), 1)
    }

    /// SPEC §3.2.3 once the row arrangement is fixed.
    private static func rowCost(
        _ plan: RowPlan,
        items: [LayoutItem],
        crowding: CGFloat,
        verticalSpacing: CGFloat,
        viewportMinY: CGFloat,
        viewportMaxY: CGFloat
    ) -> CGFloat {
        let anchors = plan.itemIndices.map { index -> CGFloat in
            let mid = items[index].sourceRect.midY
            return min(max(mid, viewportMinY), viewportMaxY)
        }
        let span = (anchors.max() ?? 0) - (anchors.min() ?? 0)
        let allowance = 28 + 90 * min(max(crowding - 0.7, 0), 1.5)
        let spanCost: CGFloat
        if span <= allowance {
            spanCost = 0.25 * span
        } else {
            spanCost = 0.25 * allowance + 1.5 * pow(span - allowance, 2) / max(allowance, 1)
        }
        let heightWeight = 1.2 * pow(max(0, crowding - 0.85), 2)
        let heightCost = heightWeight * (plan.baseHeight + verticalSpacing)
        let growthCost = plan.heightGrowthCost * growthPenaltyWeight(crowding: crowding)
        return plan.widthCost + growthCost + spanCost + heightCost
    }

    // MARK: - Global solver

    private static func layoutFrames(
        items: [LayoutItem],
        cardX: CGFloat,
        availableWidth: CGFloat,
        viewportMinY: CGFloat,
        viewportMaxY: CGFloat,
        horizontalSpacing: CGFloat,
        verticalSpacing: CGFloat
    ) -> [CGRect] {
        let count = items.count
        guard count > 0 else { return [] }
        let availableHeight = max(viewportMaxY - viewportMinY, 1)

        let singleHeight = items.reduce(CGFloat(0)) { $0 + $1.naturalHeight }
            + CGFloat(max(count - 1, 0)) * verticalSpacing
        let crowding = singleHeight / availableHeight

        let rows = solveRows(
            items: items,
            availableWidth: availableWidth,
            horizontalSpacing: horizontalSpacing,
            verticalSpacing: verticalSpacing,
            crowding: crowding,
            viewportMinY: viewportMinY,
            viewportMaxY: viewportMaxY
        )
        guard !rows.isEmpty else { return Array(repeating: .zero, count: count) }

        let (rowHeights, gap) = distributeHeights(
            rows: rows,
            availableHeight: availableHeight,
            baseSpacing: max(verticalSpacing, minRowSpacing)
        )
        let rowTops = placeRows(
            rows: rows,
            heights: rowHeights,
            gap: gap,
            items: items,
            viewportMinY: viewportMinY,
            viewportMaxY: viewportMaxY
        )

        var frames = Array(repeating: CGRect.zero, count: count)
        for (rowIndex, row) in rows.enumerated() {
            let rowTop = rowTops[rowIndex]
            let rowHeight = rowHeights[rowIndex]
            var x = cardX
            for (columnIndex, column) in row.columns.enumerated() {
                let columnWidth = column.width
                let itemCount = column.itemIndices.count
                var stackingGap: CGFloat = 0
                var usable = rowHeight
                if itemCount > 1 {
                    // Reserve g_y between stacked labels when the compressed row still has room.
                    let maximumGap = max(0, (rowHeight - CGFloat(itemCount) * 0.5) / CGFloat(itemCount - 1))
                    stackingGap = min(max(verticalSpacing, 0), maximumGap)
                    usable = max(rowHeight - CGFloat(itemCount - 1) * stackingGap, 0)
                }
                let weightSum = max(column.itemHeights.reduce(0, +), 0.001)
                var y = rowTop
                var remaining = usable
                for (slot, itemIndex) in column.itemIndices.enumerated() {
                    let height: CGFloat
                    if slot == itemCount - 1 {
                        height = remaining
                    } else {
                        // Use the planned height at this column width; the natural height is
                        // measured at the card's preferred width and misallocates space when a
                        // narrow column reflows text taller.
                        height = usable * column.itemHeights[slot] / weightSum
                        remaining -= height
                    }
                    frames[itemIndex] = CGRect(x: x, y: y, width: columnWidth, height: max(height, 0))
                    y += height + stackingGap
                }
                if columnIndex == row.columns.count - 1 {
                    // Snap the last column to the exact right edge to defeat float drift.
                    let rightEdge = cardX + availableWidth
                    let columnRight = x + columnWidth
                    if abs(columnRight - rightEdge) > 0.0001, !column.itemIndices.isEmpty {
                        for itemIndex in column.itemIndices {
                            frames[itemIndex].size.width += rightEdge - columnRight
                        }
                    }
                }
                x += columnWidth + horizontalSpacing
            }
        }
        return frames
    }

    /// Knuth-Plass dynamic program over contiguous groups of at most `maxCardsPerRow` cards.
    private static func solveRows(
        items: [LayoutItem],
        availableWidth: CGFloat,
        horizontalSpacing: CGFloat,
        verticalSpacing: CGFloat,
        crowding: CGFloat,
        viewportMinY: CGFloat,
        viewportMaxY: CGFloat
    ) -> [RowPlan] {
        let count = items.count
        var dp = [CGFloat](repeating: .greatestFiniteMagnitude, count: count + 1)
        var choice = [Int](repeating: 0, count: count + 1)
        var plans = [Int: RowPlan](minimumCapacity: count)
        dp[0] = 0

        for end in 1...count {
            let earliest = max(1, end - maxCardsPerRow + 1)
            var start = end
            while start >= earliest {
                guard dp[start - 1] < .greatestFiniteMagnitude else {
                    start -= 1
                    continue
                }
                let range = (start - 1)..<end
                if let plan = makeRowPlan(
                    items: items,
                    range: range,
                    availableWidth: availableWidth,
                    horizontalSpacing: horizontalSpacing,
                    verticalSpacing: verticalSpacing,
                    crowding: crowding
                ) {
                    let cost = dp[start - 1] + rowCost(
                        plan,
                        items: items,
                        crowding: crowding,
                        verticalSpacing: verticalSpacing,
                        viewportMinY: viewportMinY,
                        viewportMaxY: viewportMaxY
                    )
                    if cost < dp[end] - 0.0001 {
                        dp[end] = cost
                        choice[end] = start
                        plans[end] = plan
                    }
                }
                start -= 1
            }
        }

        // A single full-width card is always feasible; the fallback keeps layout total even if
        // pathological widths (e.g. a 10pt sidebar) reject every merged row.
        if dp[count] == .greatestFiniteMagnitude {
            return fallbackRows(
                items: items,
                availableWidth: availableWidth,
                verticalSpacing: verticalSpacing,
                indexOffset: 0
            )
        }

        var rows: [RowPlan] = []
        var end = count
        while end > 0 {
            let start = choice[end]
            if let plan = plans[end] {
                rows.append(plan)
            } else {
                rows.append(contentsOf: fallbackRows(
                    items: Array(items[(start - 1)..<end]),
                    availableWidth: availableWidth,
                    verticalSpacing: verticalSpacing,
                    indexOffset: start - 1
                ))
            }
            end = start - 1
        }
        return rows.reversed()
    }

    private static func fallbackRows(
        items: [LayoutItem],
        availableWidth: CGFloat,
        verticalSpacing: CGFloat,
        indexOffset: Int
    ) -> [RowPlan] {
        items.enumerated().map { offset, item in
            let height = estimatedHeight(for: item, width: availableWidth)
            let index = offset + indexOffset
            let column = ColumnPlan(
                itemIndices: [index],
                width: availableWidth,
                naturalHeight: height,
                itemHeights: [height]
            )
            return RowPlan(
                itemIndices: [index],
                columns: [column],
                baseHeight: height,
                widthCost: 0,
                heightGrowthCost: 0,
                visualHeight: height,
                isCompactRow: item.isCompactLabel
            )
        }
    }

    // MARK: - Stage 3: Box-and-Glue vertical allocation

    private static func distributeHeights(
        rows: [RowPlan],
        availableHeight: CGFloat,
        baseSpacing: CGFloat
    ) -> (heights: [CGFloat], gap: CGFloat) {
        let count = rows.count
        guard count > 0 else { return ([], baseSpacing) }
        let baseHeights = rows.map { max($0.baseHeight, 1) }
        let baseTotal = baseHeights.reduce(0, +)
        // `net` is the content height left after row gaps. The SPEC's M×18 comfort floor is
        // bounded by the viewport: overflowing the sidebar is never an acceptable trade-off.
        var gap = max(baseSpacing, minRowSpacing)
        var net = availableHeight - CGFloat(count - 1) * gap

        // Dense viewport: first tighten the row gaps from 6pt toward 4pt.
        if baseTotal > net, count > 1 {
            let idealGap = (availableHeight - baseTotal) / CGFloat(count - 1)
            gap = min(max(idealGap, minRowSpacing), gap)
            net = availableHeight - CGFloat(count - 1) * gap
        }
        // Collapsed windows: gaps alone must never consume the viewport.
        if count > 1 {
            let capacityGap = max(0, (availableHeight - CGFloat(count) * 0.5) / CGFloat(count - 1))
            if gap > capacityGap {
                gap = capacityGap
                net = availableHeight - CGFloat(count - 1) * gap
            }
        }

        var heights: [CGFloat]
        if baseTotal > net {
            let scale = max(net, 1) / baseTotal
            heights = baseHeights.map { max($0 * scale, 0.5) }
        } else {
            let comfort = min(net / max(baseTotal, 0.001), maxComfortScale)
            let alpha = max(comfort, 1)
            let pad = min(maxComfortPadding, max(0, (net - alpha * baseTotal) / CGFloat(count) * 0.5))
            heights = rows.indices.map { index in
                if rows[index].isCompactRow {
                    return baseHeights[index] * min(alpha, compactRowComfortScale)
                        + min(pad, compactRowPadding)
                }
                return baseHeights[index] * alpha + pad
            }
        }

        // Cap comfort expansion at the height the rendered content can actually use. Without
        // this, wide but width-limited paragraphs turn into large boxes with tiny text.
        for index in rows.indices {
            let visualCap = rows[index].visualHeight + 4
            heights[index] = min(heights[index], max(visualCap, 8))
        }

        // Guaranteed viewport fit, including float drift and degenerate viewports.
        let usable = max(availableHeight - CGFloat(count - 1) * gap, 1)
        let total = heights.reduce(0, +)
        if total > usable, total > 0 {
            let scale = usable / total
            heights = heights.map { $0 * scale }
        }
        return (heights, gap)
    }

    // MARK: - Stage 4: Boundary labeling + PAVA

    private static func placeRows(
        rows: [RowPlan],
        heights: [CGFloat],
        gap: CGFloat,
        items: [LayoutItem],
        viewportMinY: CGFloat,
        viewportMaxY: CGFloat
    ) -> [CGFloat] {
        let count = rows.count
        guard count > 0 else { return [] }
        // Prefix offsets: O[r] is the total height (and gaps) of rows above r.
        var offsets = [CGFloat](repeating: 0, count: count)
        for r in 1..<count {
            offsets[r] = offsets[r - 1] + heights[r - 1] + gap
        }
        let total = offsets[count - 1] + heights[count - 1]
        let available = max(viewportMaxY - viewportMinY, 1)

        if total >= available - 0.5 {
            // Completely filled: pack tightly from the top.
            return (0..<count).map { viewportMinY + offsets[$0] }
        }

        // Even distribution center, spreading the leftover space proportionally to row heights.
        let leftover = max(available - total, 0)
        let heightSum = max(heights.reduce(0, +), 0.001)
        var cumulative: CGFloat = 0
        var evenCenters = [CGFloat](repeating: 0, count: count)
        for r in 0..<count {
            let top = viewportMinY + offsets[r] + leftover * cumulative / heightSum
            evenCenters[r] = top + heights[r] * 0.5
            cumulative += heights[r]
        }

        // Blended target: 75% source-anchor alignment, 25% even viewport distribution.
        var targets = [CGFloat](repeating: 0, count: count)
        for r in 0..<count {
            let sourceCenter = rows[r].itemIndices.reduce(CGFloat(0)) {
                $0 + items[$1].sourceRect.midY
            } / CGFloat(max(rows[r].itemIndices.count, 1))
            targets[r] = sourceAnchorWeight * (sourceCenter - heights[r] * 0.5)
                + (1 - sourceAnchorWeight) * (evenCenters[r] - heights[r] * 0.5)
        }

        let lower = viewportMinY
        let upper = max(lower, viewportMaxY - (offsets[count - 1] + heights[count - 1]))

        // Weighted PAVA on z_r = y_r - O_r with the separation constraints folded in.
        var blockValues: [CGFloat] = []
        var blockWeights: [CGFloat] = []
        var blockCounts: [Int] = []
        for r in 0..<count {
            let z = targets[r] - offsets[r]
            var value = z
            var weight: CGFloat = 1
            var members = 1
            while let last = blockValues.last, last > value {
                let lastWeight = blockWeights.removeLast()
                let lastValue = blockValues.removeLast()
                let lastMembers = blockCounts.removeLast()
                value = (lastValue * lastWeight + value * weight) / max(lastWeight + weight, 0.0001)
                weight += lastWeight
                members += lastMembers
            }
            blockValues.append(value)
            blockWeights.append(weight)
            blockCounts.append(members)
        }

        var zValues = [CGFloat](repeating: lower, count: count)
        var cursor = 0
        for block in blockValues.indices {
            let clamped = min(max(blockValues[block], lower), upper)
            let members = blockCounts[block]
            for _ in 0..<members {
                if cursor < count { zValues[cursor] = clamped }
                cursor += 1
            }
        }
        return (0..<count).map { zValues[$0] + offsets[$0] }
    }
}
