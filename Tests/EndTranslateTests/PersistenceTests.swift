import Foundation
import Testing
@testable import EndTranslate

@Suite(.serialized)
final class PersistenceTests {
    private let directory: URL
    private let pdfURL: URL
    private let hash = "fixture-pdf-hash"

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EndTranslateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pdfURL = directory.appendingPathComponent("paper.pdf")
    }

    deinit {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    private func annotation(_ text: String = "中文译文") -> Annotation {
        Annotation(id: UUID(), page: 2, rect: CGRect(x: 10, y: 20, width: 200, height: 60),
                   translationMd: text, createdAt: Date(timeIntervalSince1970: 1_000))
    }

    private func session() -> AnnotationPersistence {
        let session = AnnotationPersistence(pdfURL: pdfURL)
        _ = session.load(pdfSha256: hash)
        return session
    }

    private func withReadOnlyDirectory(_ body: () throws -> Void) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        try body()
    }

    @Test func roundTripPreservesAnnotation() throws {
        let note = annotation()
        try SidecarIO.save([note], pdfSha256: hash, for: pdfURL)
        guard case .loaded(let notes) = SidecarIO.load(for: pdfURL, pdfSha256: hash) else {
            Issue.record("Expected saved annotations")
            return
        }
        #expect(notes.count == 1)
        #expect(notes.first?.id == note.id)
        #expect(notes.first?.page == note.page)
        #expect(notes.first?.rect == note.rect)
        #expect(notes.first?.translationMd == note.translationMd)
        #expect(notes.first?.createdAt == note.createdAt)
    }

    @Test(.enabled(if: geteuid() != 0, "Permission failures require a non-root process"))
    func failedSaveStaysDirtyAndCanBeRetried() throws {
        let oldNote = annotation("旧译文")
        let newNote = annotation("新译文")
        try SidecarIO.save([oldNote], pdfSha256: hash, for: pdfURL)
        let original = try Data(contentsOf: SidecarIO.url(for: pdfURL))
        let state = session()
        state.markChanged()

        try withReadOnlyDirectory { () throws -> Void in
            #expect(throws: (any Error).self) { try state.save([newNote]) }
            #expect(state.isDirty)
            #expect(try Data(contentsOf: SidecarIO.url(for: pdfURL)) == original)
        }
        try state.save([newNote])
        #expect(!state.isDirty)
        guard case .loaded(let notes) = SidecarIO.load(for: pdfURL, pdfSha256: hash) else {
            Issue.record("Retry did not save the annotation")
            return
        }
        #expect(notes.first?.translationMd == "新译文")
    }

    @Test(.enabled(if: geteuid() != 0, "Permission failures require a non-root process"))
    func failedDeletionStaysDirtyAndCanBeRetried() throws {
        try SidecarIO.save([annotation()], pdfSha256: hash, for: pdfURL)
        let state = session()
        state.markChanged()
        try withReadOnlyDirectory { () throws -> Void in
            #expect(throws: (any Error).self) { try state.save([]) }
            #expect(state.isDirty)
            #expect(FileManager.default.fileExists(atPath: SidecarIO.url(for: pdfURL).path))
        }
        try state.save([])
        #expect(!state.isDirty)
        #expect(!FileManager.default.fileExists(atPath: SidecarIO.url(for: pdfURL).path))
    }

    @Test func deletingAnAlreadyMissingSidecarSucceeds() throws {
        let state = session()
        state.markChanged()
        try state.save([])
        #expect(!state.isDirty)
    }

    @Test func corruptSidecarIsBackedUpBeforeReplacement() throws {
        let corrupt = Data(#"{"version":1,"annotations":[broken"#.utf8)
        try corrupt.write(to: SidecarIO.url(for: pdfURL))
        let state = AnnotationPersistence(pdfURL: pdfURL)
        guard case .unreadable = state.load(pdfSha256: hash) else {
            Issue.record("A corrupt file must not be treated as missing")
            return
        }
        state.markChanged()
        try state.save([annotation()])
        #expect(try Data(contentsOf: SidecarIO.backupURL(for: pdfURL)) == corrupt)
        #expect(!state.isDirty)
        guard case .loaded = SidecarIO.load(for: pdfURL, pdfSha256: hash) else {
            Issue.record("Expected a new valid sidecar")
            return
        }
    }

    @Test func pdfMismatchIsBackedUpBeforeReplacement() throws {
        try SidecarIO.save([annotation("原 PDF 的译文")], pdfSha256: "old-pdf", for: pdfURL)
        let original = try Data(contentsOf: SidecarIO.url(for: pdfURL))
        let state = AnnotationPersistence(pdfURL: pdfURL)
        guard case .mismatch = state.load(pdfSha256: hash) else {
            Issue.record("Expected PDF hash mismatch")
            return
        }
        state.markChanged()
        try state.save([annotation("新 PDF 的译文")])
        #expect(try Data(contentsOf: SidecarIO.backupURL(for: pdfURL)) == original)
        guard case .loaded(let notes) = SidecarIO.load(for: pdfURL, pdfSha256: hash) else {
            Issue.record("Expected annotations associated with the new PDF")
            return
        }
        #expect(notes.first?.translationMd == "新 PDF 的译文")
    }

    @Test(.enabled(if: geteuid() != 0, "Permission failures require a non-root process"))
    func backupFailurePreservesOriginalAndPreviousBackup() throws {
        let corrupt = Data("unreadable sidecar".utf8)
        let oldBackup = Data("older recoverable annotations".utf8)
        try corrupt.write(to: SidecarIO.url(for: pdfURL))
        try oldBackup.write(to: SidecarIO.backupURL(for: pdfURL))
        let state = session()
        state.markChanged()

        try withReadOnlyDirectory { () throws -> Void in
            #expect(throws: (any Error).self) { try state.save([annotation()]) }
            #expect(state.isDirty)
            #expect(try Data(contentsOf: SidecarIO.url(for: pdfURL)) == corrupt)
            #expect(try Data(contentsOf: SidecarIO.backupURL(for: pdfURL)) == oldBackup)
        }
        try state.save([annotation()])
        #expect(!state.isDirty)
        #expect(try Data(contentsOf: SidecarIO.backupURL(for: pdfURL)) == oldBackup)
        #expect(try Data(contentsOf: SidecarIO.backupURL(for: pdfURL).appendingPathExtension("1")) == corrupt)
    }

    @Test func futureSidecarVersionIsPreserved() throws {
        var future = Sidecar(pdfSha256: hash, annotations: [annotation()])
        future.version = 2
        let original = try JSONEncoder().encode(future)
        try original.write(to: SidecarIO.url(for: pdfURL))
        let state = AnnotationPersistence(pdfURL: pdfURL)
        guard case .unreadable = state.load(pdfSha256: hash) else {
            Issue.record("Unsupported versions must not be interpreted as current data")
            return
        }
        state.markChanged()
        try state.save([annotation("编辑后的译文")])
        #expect(try Data(contentsOf: SidecarIO.backupURL(for: pdfURL)) == original)
    }

    @Test func unreadablePathIsNotReportedAsMissing() throws {
        try FileManager.default.createDirectory(at: SidecarIO.url(for: pdfURL), withIntermediateDirectories: true)
        guard case .unreadable = SidecarIO.load(for: pdfURL, pdfSha256: hash) else {
            Issue.record("A read error must be distinguished from an absent file")
            return
        }
    }

    @Test func savingBeforeHashIsReadyDoesNotDiscardChanges() throws {
        let state = AnnotationPersistence(pdfURL: pdfURL)
        state.markChanged()
        #expect(throws: (any Error).self) { try state.save([annotation()]) }
        #expect(state.isDirty)
        #expect(!state.isReady)
        _ = state.load(pdfSha256: hash)
        try state.save([annotation()])
        #expect(!state.isDirty)
    }

    @Test func hashingReadFailureThrows() {
        #expect(throws: (any Error).self) { try SidecarIO.sha256(of: pdfURL) }
        #expect(throws: (any Error).self) { try SidecarIO.sha256(of: directory) }
    }
}
