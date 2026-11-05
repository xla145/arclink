import Foundation

/// A small, lossless block projection for chat. Unsupported Markdown remains
/// readable text; no HTML, JavaScript, file access or Agent commands execute.
enum MessageBlock: Equatable {
    case text(String)
    case heading(level: Int, text: String)
    case quote(String)
    case list(marker: String, text: String, depth: Int, checked: Bool?)
    case code(language: String?, code: String)
    case table(headers: [String], rows: [[String]])
    case image(alt: String, source: String)
    case rule
}

enum MessageMarkdown {
    static func snippet(_ text: String) -> String {
        let blocks = parse(String(text.prefix(6000)))
        let preview = blocks.prefix(3).map { block -> String in
            switch block {
            case .text(let value), .heading(_, let value), .quote(let value), .list(_, let value, _, _): return value
            case .code(_, let value): return String(value.prefix(120))
            case .image(let alt, _): return alt.isEmpty ? "图片" : alt
            case .table(let headers, _): return headers.joined(separator: " · ")
            case .rule: return ""
            }
        }.joined(separator: " ")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let clean = (try? AttributedString(markdown: preview, options: options)).map { String($0.characters) } ?? preview
        return clean.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func safeLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), url.user == nil, url.password == nil else { return false }
        if scheme == "mailto" { return !url.absoluteString.dropFirst(7).isEmpty }
        return ["https", "http"].contains(scheme) && url.host?.isEmpty == false
    }

    static func imageURL(_ source: String) -> URL? {
        guard let url = URL(string: source), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), safeLink(url) else { return nil }
        return url
    }

    static func imageData(_ source: String) -> Data? {
        guard let comma = source.firstIndex(of: ","), source.utf8.count <= 14_000_000 else { return nil }
        let header = source[..<comma].lowercased()
        guard ["data:image/png;base64", "data:image/jpeg;base64", "data:image/gif;base64", "data:image/webp;base64", "data:image/avif;base64"].contains(header) else { return nil }
        guard let data = Data(base64Encoded: String(source[source.index(after: comma)...])), data.count <= 10 * 1024 * 1024 else { return nil }
        return data
    }

    static func parse(_ text: String) -> [MessageBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MessageBlock] = []
        var prose: [String] = []
        var index = 0
        func flush() {
            let chunk = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { blocks += images(in: chunk) }
            prose = []
        }
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = fenceStart(line) {
                flush()
                var code: [String] = []
                index += 1
                while index < lines.count {
                    let closing = lines[index].trimmingCharacters(in: .whitespaces)
                    if closing.count >= fence.length && closing.allSatisfy({ $0 == fence.character }) {
                        index += 1
                        break
                    }
                    code.append(lines[index]); index += 1
                }
                blocks.append(.code(language: fence.language, code: code.joined(separator: "\n")))
                continue
            }
            if index + 1 < lines.count, line.contains("|"), tableSeparator(lines[index + 1], columns: tableCells(line).count) {
                flush()
                let headers = tableCells(line)
                index += 2
                var rows: [[String]] = []
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    let cells = tableCells(lines[index])
                    rows.append((0..<headers.count).map { $0 < cells.count ? cells[$0] : "" })
                    index += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }
            if let match = captures(#"^ {0,3}(#{1,6})[ \t]+(.+?)(?:[ \t]+#+)?[ \t]*$"#, line) {
                flush(); blocks.append(.heading(level: match[0].count, text: match[1]))
            } else if trimmed.hasPrefix(">") {
                flush()
                var quote: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let value = lines[index].trimmingCharacters(in: .whitespaces).dropFirst()
                    quote.append(value.hasPrefix(" ") ? String(value.dropFirst()) : String(value))
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n"))); continue
            } else if let match = captures(#"^(\s*)([-+*]|\d+[.)])\s+(.+)$"#, line) {
                flush()
                let depth = min(6, match[0].replacingOccurrences(of: "\t", with: "    ").count / 2)
                if let task = captures(#"^\[([ xX])\]\s+(.*)$"#, match[2]) {
                    blocks.append(.list(marker: match[1], text: task[1], depth: depth, checked: task[0].lowercased() == "x"))
                } else {
                    blocks.append(.list(marker: match[1], text: match[2], depth: depth, checked: nil))
                }
            } else if ["---", "***", "___"].contains(trimmed) {
                flush(); blocks.append(.rule)
            } else if trimmed.isEmpty {
                flush()
            } else {
                prose.append(line)
            }
            index += 1
        }
        flush()
        return blocks
    }

    private static func captures(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }

    private static func fenceStart(_ line: String) -> (character: Character, length: Int, language: String?)? {
        guard let values = captures(#"^ {0,3}(`{3,}|~{3,})(.*)$"#, line), let character = values[0].first else { return nil }
        let language = values[1].trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace).first.map(String.init)
        return (character, values[0].count, language)
    }

    private static func tableSeparator(_ line: String, columns: Int) -> Bool {
        let cells = tableCells(line)
        return !cells.isEmpty && cells.count == columns && cells.allSatisfy { captures(#"^:?-{3,}:?$"#, $0) != nil }
    }

    static func tableCells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") && !value.hasSuffix("\\|") { value.removeLast() }
        var cells: [String] = []; var cell = ""; var escaped = false; var inCode = false
        for character in value {
            if escaped { cell.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; cell.append(character); continue }
            if character == "`" { inCode.toggle() }
            if character == "|", !inCode {
                cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = ""
            } else { cell.append(character) }
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// Image destinations may contain balanced parentheses (common in file
    /// names). Keep malformed references as text instead of dropping content.
    private static func images(in text: String) -> [MessageBlock] {
        var blocks: [MessageBlock] = []
        var cursor = text.startIndex
        var search = cursor
        while search < text.endIndex, let open = text.range(of: "![", range: search..<text.endIndex) {
            if open.lowerBound > text.startIndex, text[text.index(before: open.lowerBound)] == "\\" {
                search = open.upperBound; continue
            }
            // Image-looking text inside an inline code span stays literal.
            let prefix = text[cursor..<open.lowerBound]
            if prefix.filter({ $0 == "`" }).count % 2 != 0 {
                search = open.upperBound; continue
            }
            guard let boundary = text.range(of: "](", range: open.upperBound..<text.endIndex) else { break }
            var end = boundary.upperBound; var depth = 1; var escaped = false
            while end < text.endIndex {
                let char = text[end]
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "(" { depth += 1 }
                else if char == ")" { depth -= 1; if depth == 0 { break } }
                end = text.index(after: end)
            }
            guard end < text.endIndex else { break }
            let before = String(text[cursor..<open.lowerBound])
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(.text(before)) }
            var destination = String(text[boundary.upperBound..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Common optional quoted title is presentation metadata, not URL.
            if let title = destination.range(of: #"\s+["'][^"']*["']\s*$"#, options: .regularExpression) { destination.removeSubrange(title) }
            if destination.hasPrefix("<"), destination.hasSuffix(">") { destination = String(destination.dropFirst().dropLast()) }
            // Markdown escapes belong to the destination syntax, not the
            // fetched URL (e.g. a\(1\).png must request a(1).png).
            destination = destination.replacingOccurrences(of: #"\\([\\()])"#, with: "$1", options: .regularExpression)
            blocks.append(.image(alt: String(text[open.upperBound..<boundary.lowerBound]), source: destination))
            cursor = text.index(after: end); search = cursor
        }
        let rest = String(text[cursor...])
        if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(.text(rest)) }
        return blocks
    }
}
