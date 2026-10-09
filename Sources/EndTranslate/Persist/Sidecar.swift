import Foundation
import CryptoKit

enum SidecarIO {
    enum LoadResult {
        /// No sidecar next to the PDF.
        case missing
        /// Written for a different version of the PDF.
        case mismatch
        /// Existing data must be backed up before a later save replaces it.
        case unreadable(String)
        case loaded([Annotation])
    }

    static func url(for pdfURL: URL) -> URL {
        pdfURL.deletingPathExtension().appendingPathExtension("etr.json")
    }

    static func backupURL(for pdfURL: URL) -> URL {
        url(for: pdfURL).appendingPathExtension("bak")
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Loads annotations only if the sidecar was written for this exact PDF.
    static func load(for pdfURL: URL, pdfSha256: String?) -> LoadResult {
        let sidecarURL = url(for: pdfURL)
        let data: Data
        do {
            data = try Data(contentsOf: sidecarURL)
        } catch {
            if isMissing(error) { return .missing }
            Log.write("sidecar read failed: \(error)")
            return .unreadable(error.localizedDescription)
        }
        do {
            let sidecar = try JSONDecoder().decode(Sidecar.self, from: data)
            guard sidecar.version == 1 else {
                return .unreadable("不支持的译注版本：\(sidecar.version)")
            }
            guard let pdfSha256, sidecar.pdfSha256 == pdfSha256 else {
                Log.write("sidecar sha mismatch, ignoring \(sidecarURL.lastPathComponent)")
                return .mismatch
            }
            Log.write("sidecar loaded \(sidecar.annotations.count) annotation(s)")
            return .loaded(sidecar.annotations)
        } catch {
            Log.write("sidecar decode failed: \(error)")
            return .unreadable(error.localizedDescription)
        }
    }

    /// Copies the current sidecar aside without replacing an earlier backup.
    /// If this fails, the caller must leave the source untouched.
    @discardableResult
    static func backup(for pdfURL: URL) throws -> URL? {
        let source = url(for: pdfURL)
        do {
            _ = try FileManager.default.attributesOfItem(atPath: source.path)
        } catch {
            if isMissing(error) { return nil }
            throw error
        }
        let base = backupURL(for: pdfURL)
        var target = base
        var suffix = 1
        while FileManager.default.fileExists(atPath: target.path) {
            target = base.appendingPathExtension(String(suffix))
            suffix += 1
        }
        try FileManager.default.copyItem(at: source, to: target)
        Log.write("sidecar backed up to \(target.lastPathComponent)")
        return target
    }

    static func save(_ annotations: [Annotation], pdfSha256: String, for pdfURL: URL) throws {
        // No annotations left: don't leave an empty sidecar next to the PDF.
        if annotations.isEmpty {
            do {
                try FileManager.default.removeItem(at: url(for: pdfURL))
            } catch {
                if !isMissing(error) { throw error }
            }
            Log.write("sidecar removed (no annotations)")
            return
        }
        let sidecar = Sidecar(pdfSha256: pdfSha256, annotations: annotations)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sidecar)
        try data.write(to: url(for: pdfURL), options: .atomic)
        Log.write("sidecar saved \(annotations.count) annotation(s)")
    }

    private static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
    }
}
