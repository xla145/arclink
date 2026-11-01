import Foundation
import SwiftUI

struct UserQuestionAnswer: Equatable {
    let question: String
    let answer: String
}

enum UserMessageBlock: Equatable {
    case text(String)
    case answers([UserQuestionAnswer])
}

/// Presentation only. Unknown schemas and literal examples remain byte-for-byte text.
enum UserMessageContent {
    private static let opening = "<send_user_message_question_reply>"
    private static let closing = "</send_user_message_question_reply>"

    static func parse(_ text: String) -> [UserMessageBlock] {
        guard text.utf8.count <= 256 * 1024 else { return [.text(text)] }
        var blocks: [UserMessageBlock] = []
        var cursor = text.startIndex
        var pending = cursor
        var lineStart = cursor
        var fence: (Character, Int)?
        var inlineTicks: Int?

        while cursor < text.endIndex {
            if cursor == lineStart, inlineTicks == nil {
                let lineEnd = text[cursor...].firstIndex(of: "\n") ?? text.endIndex
                let line = text[cursor..<lineEnd]
                let indentation = line.prefix { $0 == " " || $0 == "\t" }
                let trimmed = line.dropFirst(indentation.count)
                let marker = trimmed.first
                let count = marker.map { character in trimmed.prefix { $0 == character }.count } ?? 0
                let next = lineEnd < text.endIndex ? text.index(after: lineEnd) : lineEnd
                if let current = fence {
                    if indentation.count <= 3, !indentation.contains("\t"), marker == current.0, count >= current.1,
                       trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                    cursor = next; lineStart = next
                    continue
                }
                if indentation.contains("\t") || indentation.count >= 4 || trimmed.hasPrefix(">") {
                    cursor = next; lineStart = next
                    continue
                }
                if let marker, (marker == "`" || marker == "~"), count >= 3 {
                    fence = (marker, count)
                    cursor = next; lineStart = next
                    continue
                }
            }
            if text[cursor] == "`" {
                let run = text[cursor...].prefix { $0 == "`" }.count
                if inlineTicks == run { inlineTicks = nil }
                else if inlineTicks == nil { inlineTicks = run }
                cursor = text.index(cursor, offsetBy: run)
                continue
            }
            if inlineTicks == nil, text[cursor...].hasPrefix(opening),
               text[lineStart..<cursor].trimmingCharacters(in: .whitespaces).isEmpty {
                let bodyStart = text.index(cursor, offsetBy: opening.count)
                if let end = text.range(of: closing, range: bodyStart..<text.endIndex),
                   let answers = decode(String(text[bodyStart..<end.lowerBound])) {
                    if pending < cursor { blocks.append(.text(String(text[pending..<cursor]))) }
                    blocks.append(.answers(answers))
                    cursor = end.upperBound
                    pending = cursor
                    // A JSON block may contain newlines; resume at its real final line.
                    lineStart = text[..<cursor].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
                    continue
                }
                // A malformed envelope is one literal unit; do not reinterpret
                // nested tags inside its damaged payload.
                cursor = text.range(of: closing, range: bodyStart..<text.endIndex)?.upperBound ?? text.endIndex
                lineStart = text[..<cursor].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
                continue
            }
            if text[cursor] == "\n" { lineStart = text.index(after: cursor) }
            cursor = text.index(after: cursor)
        }
        if pending < text.endIndex { blocks.append(.text(String(text[pending...]))) }
        return blocks.isEmpty ? [.text(text)] : blocks
    }

    private static func decode(_ json: String) -> [UserQuestionAnswer]? {
        guard let data = json.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !rows.isEmpty, rows.count <= 128 else { return nil }
        let keys: Set<String> = ["questionItemId", "question", "answer"]
        var answers: [UserQuestionAnswer] = []
        for row in rows {
            guard Set(row.keys).isSubset(of: keys),
                  let question = row["question"] as? String,
                  let answer = row["answer"] as? String else { return nil }
            if let id = row["questionItemId"], !(id is String) { return nil }
            answers.append(UserQuestionAnswer(question: question, answer: answer))
        }
        return answers
    }
}

struct UserMessageBody: View {
    var text: String

    var body: some View {
        let blocks = UserMessageContent.parse(text)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks.indices, id: \.self) { index in
                switch blocks[index] {
                case .text(let body):
                    if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(body).textSelection(.enabled)
                    }
                case .answers(let replies):
                    VStack(alignment: .leading, spacing: 12) {
                        Label("补充信息", systemImage: "text.bubble")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(replies.indices, id: \.self) { reply in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(replies[reply].question).font(.caption).foregroundStyle(.secondary)
                                Text(replies[reply].answer).font(.body.weight(.medium))
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        }
                    }
                    .accessibilityIdentifier("user-question-replies")
                }
            }
        }
    }
}
