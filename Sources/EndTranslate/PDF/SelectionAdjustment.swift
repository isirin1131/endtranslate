import Foundation

/// Handle names use the PDF's original, y-up coordinate space.
enum SelectionHandle: CaseIterable, Equatable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight
    case top, bottom, left, right

    var changesMinX: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var changesMaxX: Bool { self == .right || self == .topRight || self == .bottomRight }
    var changesMinY: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
    var changesMaxY: Bool { self == .top || self == .topLeft || self == .topRight }

    func point(in rect: CGRect) -> CGPoint {
        CGPoint(x: changesMinX ? rect.minX : (changesMaxX ? rect.maxX : rect.midX),
                y: changesMinY ? rect.minY : (changesMaxY ? rect.maxY : rect.midY))
    }

    var edgeCorners: (SelectionHandle, SelectionHandle)? {
        switch self {
        case .top: return (.topLeft, .topRight)
        case .bottom: return (.bottomLeft, .bottomRight)
        case .left: return (.bottomLeft, .topLeft)
        case .right: return (.bottomRight, .topRight)
        default: return nil
        }
    }
}

/// A drag always starts from a snapshot, so repeated mouse/scroll events do not
/// accumulate rounding errors. The opposite edge stays fixed while resizing.
struct SelectionAdjustment {
    enum Kind: Equatable {
        case move
        case resize(SelectionHandle)
    }

    static let minimumSize: CGFloat = 3
    let kind: Kind
    let startPoint: CGPoint
    let startRect: CGRect

    func rect(at point: CGPoint, within page: CGRect) -> CGRect {
        let dx = point.x - startPoint.x
        let dy = point.y - startPoint.y
        switch kind {
        case .move:
            return CGRect(
                x: min(max(startRect.minX + dx, page.minX), page.maxX - startRect.width),
                y: min(max(startRect.minY + dy, page.minY), page.maxY - startRect.height),
                width: startRect.width, height: startRect.height
            )
        case .resize(let handle):
            var minX = startRect.minX, maxX = startRect.maxX
            var minY = startRect.minY, maxY = startRect.maxY
            if handle.changesMinX { minX = min(max(minX + dx, page.minX), maxX - Self.minimumSize) }
            if handle.changesMaxX { maxX = max(min(maxX + dx, page.maxX), minX + Self.minimumSize) }
            if handle.changesMinY { minY = min(max(minY + dy, page.minY), maxY - Self.minimumSize) }
            if handle.changesMaxY { maxY = max(min(maxY + dy, page.maxY), minY + Self.minimumSize) }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }
}
