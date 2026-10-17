import Foundation

struct Annotation: Codable {
    var id: UUID
    var page: Int
    var rect: CGRect
    var translationMd: String
    var createdAt: Date
}

struct Sidecar: Codable {
    var version: Int = 1
    var pdfSha256: String
    var annotations: [Annotation]
}

final class AnnotationStore {
    private(set) var annotations: [Annotation] = []
    private var views: [UUID: TranslationAnnotation] = [:]

    func add(_ model: Annotation, view: TranslationAnnotation) {
        annotations.append(model)
        views[model.id] = view
    }

    func update(_ model: Annotation) {
        if let i = annotations.firstIndex(where: { $0.id == model.id }) {
            annotations[i] = model
        }
    }

    /// Returns the removed annotation's position, so an undo can put it back in place.
    @discardableResult
    func remove(id: UUID) -> Int? {
        let index = annotations.firstIndex { $0.id == id }
        annotations.removeAll { $0.id == id }
        views[id] = nil
        return index
    }

    func insert(_ model: Annotation, view: TranslationAnnotation, at index: Int) {
        annotations.insert(model, at: min(max(index, 0), annotations.count))
        views[model.id] = view
    }

    func view(for id: UUID) -> TranslationAnnotation? {
        views[id]
    }

    var allViews: [TranslationAnnotation] {
        annotations.compactMap { views[$0.id] }
    }

    func removeAll() {
        annotations.removeAll()
        views.removeAll()
    }
}
