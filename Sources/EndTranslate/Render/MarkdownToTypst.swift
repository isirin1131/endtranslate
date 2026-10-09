import Foundation

enum MarkdownToTypst {
    static let mitexVersion = "0.2.7"
    /// Bump when the generated typst template or conversion rules change, to invalidate render caches.
    static let templateVersion = 4

    static func document(
        markdown: String,
        width: CGFloat,
        fontSize: CGFloat,
        degradedMath: Set<String> = []
    ) -> String {
        let preamble = """
        #set page(width: \(fmt(width))pt, height: auto, margin: 4pt)
        #set text(font: ("New Computer Modern", "PingFang SC", "Songti SC"), size: \(fmt(fontSize))pt, lang: "zh")
        #set par(leading: 0.62em, justify: false, spacing: 0.55em)
        #set list(indent: 0.9em, body-indent: 0.45em, spacing: 0.28em)
        #set enum(indent: 0.9em, body-indent: 0.45em, spacing: 0.28em)
        #show heading: it => block(above: 0.5em, below: 0.2em)[#set text(weight: "bold", size: \(fmt(fontSize + 1))pt); #it.body]
        #show raw.where(block: true): it => block(width: 100%, inset: 3pt, fill: luma(245), radius: 1.5pt, text(font: "Menlo", size: \(fmt(fontSize - 1.5))pt, it.text))
        #show raw.where(block: false): it => box(inset: 1pt, fill: luma(242), radius: 1pt, text(font: "Menlo", size: \(fmt(fontSize - 0.5))pt, it.text))
        #import "@preview/mitex:\(mitexVersion)": mi

        """
        return preamble + body(markdown, degradedMath: degradedMath) + "\n"
    }

    // MARK: - Blocks

    static func body(_ markdown: String, degradedMath: Set<String> = []) -> String {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var out: [String] = []
        var i = 0
        var displayBuffer: [String]?

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            if let buffer = displayBuffer {
                if let r = line.range(of: "$$") {
                    let head = String(line[line.startIndex..<r.lowerBound])
                    out.append(blockMath((buffer + [head]).joined(separator: " "), degraded: degradedMath))
                    let rest = String(line[r.upperBound...])
                    if !rest.trimmingCharacters(in: .whitespaces).isEmpty { out.append(inline(rest, degraded: degradedMath)) }
                    displayBuffer = nil
                } else if let r = line.range(of: "\\]") {
                    let head = String(line[line.startIndex..<r.lowerBound])
                    out.append(blockMath((buffer + [head]).joined(separator: " "), degraded: degradedMath))
                    displayBuffer = nil
                } else {
                    displayBuffer = buffer + [line]
                }
                i += 1
                continue
            }

            if line.isEmpty { out.append(""); i += 1; continue }

            if line.hasPrefix("$$") || line.hasPrefix("\\[") {
                let marker = line.hasPrefix("$$") ? "$$" : "\\["
                let after = String(line.dropFirst(marker.count))
                if let r = after.range(of: marker) {
                    out.append(blockMath(String(after[after.startIndex..<r.lowerBound]), degraded: degradedMath))
                    let rest = String(after[r.upperBound...])
                    if !rest.trimmingCharacters(in: .whitespaces).isEmpty { out.append(inline(rest, degraded: degradedMath)) }
                } else {
                    displayBuffer = [after]
                }
                i += 1
                continue
            }

            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                let fence = line.hasPrefix("```") ? "```" : "~~~"
                let lang = String(line.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var buffer: [String] = []
                var j = i + 1
                while j < lines.count, !lines[j].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    buffer.append(lines[j])
                    j += 1
                }
                out.append(fence + lang + "\n" + buffer.joined(separator: "\n") + "\n" + fence)
                i = j < lines.count ? j + 1 : lines.count
                continue
            }

            if line.hasPrefix("|"),
               i + 1 < lines.count,
               isTableSeparator(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                var rows: [[String]] = []
                var j = i
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    if !isTableSeparator(t) { rows.append(splitRow(t)) }
                    j += 1
                }
                out.append(table(rows, degraded: degradedMath))
                i = j
                continue
            }

            if let m = heading(line) {
                out.append(String(repeating: "=", count: m.0) + " " + inline(m.1, degraded: degradedMath))
                i += 1
                continue
            }

            if isRule(line) {
                out.append("#line(length: 100%, stroke: 0.5pt + luma(185))")
                i += 1
                continue
            }

            if let (depth, text) = bullet(raw) {
                out.append(String(repeating: "  ", count: depth) + "- " + inline(text, degraded: degradedMath))
                i += 1
                continue
            }

            if let (depth, text) = ordered(raw) {
                out.append(String(repeating: "  ", count: depth) + "+ " + inline(text, degraded: degradedMath))
                i += 1
                continue
            }

            if line.hasPrefix(">") {
                let text = line.dropFirst().trimmingCharacters(in: .whitespaces)
                out.append("#block(inset: (left: 6pt, right: 2pt), stroke: (left: 1pt + luma(170)), width: 100%)[" + inline(text, degraded: degradedMath) + "]")
                i += 1
                continue
            }

            out.append(inline(line, degraded: degradedMath))
            i += 1
        }

        if let buffer = displayBuffer, !buffer.isEmpty {
            out.append(blockMath(buffer.joined(separator: " "), degraded: degradedMath))
        }
        return out.joined(separator: "\n")
    }

    static func heading(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes <= 6 else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        return (hashes, rest.trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" || $0 == "*" || $0 == "_" }
    }

    static func bullet(_ raw: String) -> (Int, String)? {
        let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
        let rest = raw.dropFirst(indent)
        guard let first = rest.first, first == "-" || first == "*" || first == "+" else { return nil }
        let after = rest.dropFirst()
        guard after.hasPrefix(" ") || after.isEmpty else { return nil }
        return (min(indent / 2, 3), after.trimmingCharacters(in: .whitespaces))
    }

    static func ordered(_ raw: String) -> (Int, String)? {
        let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
        let rest = raw.dropFirst(indent)
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let after = rest.dropFirst(digits.count)
        guard after.hasPrefix(".") || after.hasPrefix(")") else { return nil }
        let text = after.dropFirst()
        guard text.hasPrefix(" ") else { return nil }
        return (min(indent / 2, 3), text.trimmingCharacters(in: .whitespaces))
    }

    static func isTableSeparator(_ line: String) -> Bool {
        guard line.hasPrefix("|") else { return false }
        let stripped = line.replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty && line.contains("-")
    }

    static func splitRow(_ line: String) -> [String] {
        var t = line
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func table(_ rows: [[String]], degraded: Set<String> = []) -> String {
        guard let first = rows.first, !first.isEmpty else { return "" }
        let cols = max(rows.map(\.count).max() ?? 1, 1)
        var cells: [String] = []
        for (r, row) in rows.enumerated() {
            var padded = row
            while padded.count < cols { padded.append("") }
            for cell in padded {
                let content = inline(cell, degraded: degraded)
                if r == 0 {
                    cells.append("table.cell(fill: luma(238))[" + (content.isEmpty ? "" : "*" + content + "*") + "]")
                } else {
                    cells.append("[" + content + "]")
                }
            }
        }
        return "#table(columns: \(cols), stroke: 0.4pt + luma(200), inset: 3pt,\n  "
            + cells.joined(separator: ",\n  ") + "\n)"
    }

    // MARK: - Inline

    static func inline(_ text: String, degraded: Set<String> = []) -> String {
        let a = Array(text)
        var out = ""
        var plain = ""
        var i = 0

        func flush() {
            guard !plain.isEmpty else { return }
            out += escape(plain)
            plain = ""
        }

        func find(_ token: [Character], from: Int) -> Int? {
            var j = from
            while j + token.count <= a.count {
                if a[j] == "\\" { j += 2; continue }
                if Array(a[j..<(j + token.count)]) == token { return j }
                j += 1
            }
            return nil
        }

        while i < a.count {
            let c = a[i]

            if c == "\\", i + 1 < a.count, "$*_`\\[]()".contains(a[i + 1]) {
                plain.append(a[i + 1])
                i += 2
                continue
            }

            if c == "`", let close = find(["`"], from: i + 1) {
                flush()
                out += "`" + String(a[(i + 1)..<close]) + "`"
                i = close + 1
                continue
            }

            if c == "$", let close = find(["$"], from: i + 1) {
                flush()
                out += inlineMath(String(a[(i + 1)..<close]), degraded: degraded)
                i = close + 1
                continue
            }

            if c == "\\", i + 1 < a.count, a[i + 1] == "(", let close = find([")"], from: i + 2) {
                flush()
                out += inlineMath(String(a[(i + 2)..<close]), degraded: degraded)
                i = close + 1
                continue
            }

            if c == "*" || c == "_" {
                let double = i + 1 < a.count && a[i + 1] == c
                let token: [Character] = double ? [c, c] : [c]
                if let close = find(token, from: i + token.count) {
                    let inner = String(a[(i + token.count)..<close])
                    if !inner.isEmpty, inner.count < 500, !inner.hasPrefix(" ") {
                        flush()
                        let marker = double ? "*" : "_"
                        out += marker + inline(inner, degraded: degraded) + marker
                        i = close + token.count
                        continue
                    }
                }
            }

            if c == "[", let close = find(["]"], from: i + 1), close + 1 < a.count, a[close + 1] == "(",
               let urlClose = find([")"], from: close + 2) {
                flush()
                let label = String(a[(i + 1)..<close])
                let url = String(a[(close + 2)..<urlClose])
                out += "#link(\"" + typstString(url) + "\")[" + inline(label, degraded: degraded) + "]"
                i = urlClose + 1
                continue
            }

            plain.append(c)
            i += 1
        }
        flush()
        return out
    }

    /// Last-resort fallback when typst is unavailable: markdown markers removed.
    static func plainText(_ markdown: String) -> String {
        var lines: [String] = []
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("$$") { line = String(line.dropFirst(2)) }
            if line.hasSuffix("$$") { line = String(line.dropLast(2)) }
            if line.hasPrefix("\\[") { line = String(line.dropFirst(2)) }
            if line.hasSuffix("\\]") { line = String(line.dropLast(2)) }
            if line.hasPrefix("\\(") { line = String(line.dropFirst(2)) }
            if line.hasSuffix("\\)") { line = String(line.dropLast(2)) }
            while line.hasPrefix("#") { line.removeFirst() }
            if let f = line.first, f == ">" { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("|") {
                line = line.replacingOccurrences(of: "|", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                if line.allSatisfy({ $0 == "-" || $0 == ":" || $0 == " " }) { continue }
            }
            lines.append(line)
        }
        var text = lines.joined(separator: "\n")
        for marker in ["**", "`", "$"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func escape(_ s: String) -> String {        var out = ""
        for ch in s {
            if "\\`*_#$<>@~".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    static func inlineMath(_ latex: String, degraded: Set<String> = []) -> String {
        if degraded.contains(normalizeMath(latex)) { return escape(latex) }
        return "#mi(\"" + typstString(latex) + "\")"
    }

    static func blockMath(_ latex: String, degraded: Set<String> = []) -> String {
        if degraded.contains(normalizeMath(latex)) { return escape(latex) }
        return "$ #mi(\"" + typstString(latex) + "\") $"
    }

    /// Whitespace-insensitive key so snippets extracted from markdown match what the parser emits.
    static func normalizeMath(_ latex: String) -> String {
        latex.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Raw LaTeX snippets in the source, in emission order; used to isolate formulas typst rejects.
    static func mathSnippets(_ markdown: String) -> [String] {
        let a = Array(markdown)
        var out: [String] = []
        var i = 0
        while i < a.count {
            if a[i] == "\\" {
                i += 2
                continue
            }
            if a[i] == "$" {
                let isBlock = i + 1 < a.count && a[i + 1] == "$"
                let start = i + (isBlock ? 2 : 1)
                var j = start
                var close: Int?
                while j < a.count {
                    if a[j] == "\\" { j += 2; continue }
                    if a[j] == "$" {
                        if isBlock {
                            if j + 1 < a.count, a[j + 1] == "$" { close = j; break }
                        } else {
                            close = j
                            break
                        }
                    }
                    j += 1
                }
                guard let close else { break }
                out.append(String(a[start..<close]))
                i = isBlock ? close + 2 : close + 1
                continue
            }
            i += 1
        }
        return out
    }

    static func typstString(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n", "\r", "\t": out.append(" ")
            default: out.append(ch)
            }
        }
        return out
    }

    static func fmt(_ v: CGFloat) -> String {
        String(format: "%.2f", Double(v))
    }
}
