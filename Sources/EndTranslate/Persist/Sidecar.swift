import Foundation
import CryptoKit

enum SidecarIO {
    enum LoadResult {
        /// No sidecar next to the PDF (or it can't be read).
        case missing
        /// Written for a different version of the PDF.
        case mismatch
        case loaded([Annotation])
    }

    static func url(for pdfURL: URL) -> URL {
        pdfURL.deletingPathExtension().appendingPathExtension("etr.json")
    }

    static func backupURL(for pdfURL: URL) -> URL {
        url(for: pdfURL).appendingPathExtension("bak")
    }

    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Loads annotations only if the sidecar was written for this exact PDF.
    static func load(for pdfURL: URL, pdfSha256: String?) -> LoadResult {
        let sidecarURL = url(for: pdfURL)
        guard let data = try? Data(contentsOf: sidecarURL) else { return .missing }
        do {
            let sidecar = try JSONDecoder().decode(Sidecar.self, from: data)
            guard let pdfSha256, sidecar.pdfSha256 == pdfSha256 else {
                Log.write("sidecar sha mismatch, ignoring \(sidecarURL.lastPathComponent)")
                return .mismatch
            }
            Log.write("sidecar loaded \(sidecar.annotations.count) annotation(s)")
            return .loaded(sidecar.annotations)
        } catch {
            Log.write("sidecar decode failed: \(error)")
            return .missing
        }
    }

    /// Moves the current sidecar aside to `<name>.etr.json.bak` (replacing an older backup).
    static func backup(for pdfURL: URL) {
        let source = url(for: pdfURL)
        let target = backupURL(for: pdfURL)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.copyItem(at: source, to: target)
            Log.write("sidecar backed up to \(target.lastPathComponent)")
        } catch {
            Log.write("sidecar backup failed: \(error)")
        }
    }

    @discardableResult
    static func save(_ annotations: [Annotation], pdfSha256: String, for pdfURL: URL) -> Bool {
        // No annotations left: don't leave an empty sidecar next to the PDF.
        if annotations.isEmpty {
            try? FileManager.default.removeItem(at: url(for: pdfURL))
            Log.write("sidecar removed (no annotations)")
            return true
        }
        let sidecar = Sidecar(pdfSha256: pdfSha256, annotations: annotations)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(sidecar)
            try data.write(to: url(for: pdfURL), options: .atomic)
            Log.write("sidecar saved \(annotations.count) annotation(s)")
            return true
        } catch {
            Log.write("sidecar save failed: \(error)")
            return false
        }
    }
}
