import Foundation

/// Save state belongs to one PDF, so a failed write cannot be forgotten or carried
/// into another document. PDFViewModel supplies UI feedback and debounce timing.
final class AnnotationPersistence {
    enum SaveError: LocalizedError {
        case notReady

        var errorDescription: String? { "译注尚未加载完成，请稍后重试保存" }
    }

    let pdfURL: URL
    private var pdfSha256: String?
    private var needsBackup = false
    private(set) var isDirty = false

    var isReady: Bool { pdfSha256 != nil }

    init(pdfURL: URL) {
        self.pdfURL = pdfURL
    }

    func load(pdfSha256: String) -> SidecarIO.LoadResult {
        self.pdfSha256 = pdfSha256
        let result = SidecarIO.load(for: pdfURL, pdfSha256: pdfSha256)
        switch result {
        case .mismatch, .unreadable:
            needsBackup = true
        case .missing, .loaded:
            needsBackup = false
        }
        return result
    }

    func markChanged() {
        isDirty = true
    }

    func save(_ annotations: [Annotation]) throws {
        guard isDirty else { return }
        guard let pdfSha256 else { throw SaveError.notReady }
        if needsBackup {
            try SidecarIO.backup(for: pdfURL)
            needsBackup = false
        }
        try SidecarIO.save(annotations, pdfSha256: pdfSha256, for: pdfURL)
        isDirty = false
    }
}
