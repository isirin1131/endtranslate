import Foundation

/// Readable text while vector typesetting is pending or unavailable.
enum MarkdownText {
    static func plainText(_ markdown: String) -> String {
        var lines: [String] = []
        var inCode = false
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inCode.toggle()
                continue
            }
            if inCode { lines.append(raw); continue }
            while line.hasPrefix("#") { line.removeFirst() }
            if line.hasPrefix(">") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("|") {
                line = line.replacingOccurrences(of: "|", with: " ").trimmingCharacters(in: .whitespaces)
                if line.allSatisfy({ $0 == "-" || $0 == ":" || $0 == " " }) { continue }
            }
            lines.append(line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: ""))
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
