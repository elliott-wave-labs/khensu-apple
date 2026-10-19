// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import KhensuKit

/// What the person typed into Ask khėnsu: a question or a `~` command.
enum AskCommand: Equatable {
    case ask(String)
    case summarize
    case find(String)
    case help
    case unknown(String)

    static let commands: [(name: String, text: String)] = [
        ("~summarize", "Summarize the chat you have open, or the most recent one"),
        ("~find <words>", "Every message and post that mentions something"),
    ]

    init(_ raw: String) {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.hasPrefix("~") else {
            self = .ask(input)
            return
        }
        let body = input.dropFirst()
        let name = body.prefix { !$0.isWhitespace }.lowercased()
        let rest = body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "summarize", "summarise", "sum": self = .summarize
        case "find": self = rest.isEmpty ? .help : .find(rest)
        case "", "help": self = .help
        default: self = .unknown(String(name))
        }
    }
}

/// A piece of the person's own data that can go into the prompt.
struct AskSnippet: Identifiable, Hashable {
    enum Source: Hashable { case chat(ConversationID), post }

    let id: String
    let source: Source
    /// The chat's name (or "Your feed posts"), used for citations.
    let place: String
    let sender: String
    let text: String
    let date: Date

    var conversationID: ConversationID? {
        if case .chat(let id) = source { id } else { nil }
    }

    func promptLine(_ n: Int) -> String {
        let clipped = text.count > AskRetrieval.maxSnippetLength ? String(text.prefix(AskRetrieval.maxSnippetLength)) + "…" : text
        let when = date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute())
        return "[\(n)] Chat: \(place) · \(when) · \(sender): \(clipped.replacingOccurrences(of: "\n", with: " "))"
    }
}

/// Keyword and recency ranking over local snippets. Plain and deterministic so
/// it can run on every keystroke and be tested.
enum AskRetrieval {
    static let limit = 20
    static let maxSnippetLength = 280
    /// Days for the recency bonus to halve.
    static let recencyHalfLife: Double = 14

    private static let stopwords: Set<String> = [
        "the", "and", "for", "are", "was", "were", "you", "your", "with", "that", "this", "what", "when", "where",
        "who", "whom", "why", "how", "did", "does", "has", "have", "had", "about", "from", "into", "they", "them",
        "their", "there", "then", "than", "can", "could", "would", "should", "will", "said", "say", "tell", "any",
        "all", "our", "out", "but", "not", "its", "his", "her", "she", "him", "get", "got", "let", "lets", "which",
        "me", "my", "is", "it", "in", "on", "of", "to", "a", "an", "do", "i", "we", "be", "or", "at", "by", "us",
    ]

    /// Lowercased words of three letters or more, without filler words, in order, once each.
    static func keywords(_ question: String) -> [String] {
        var seen = Set<String>()
        return question
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 && !stopwords.contains($0) && seen.insert($0).inserted }
    }

    static func score(_ snippet: AskSnippet, keywords: [String], phrase: String, now: Date) -> Double {
        let text = snippet.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        let place = snippet.place.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        var score = 0.0
        for k in keywords {
            let hits = text.components(separatedBy: k).count - 1
            if hits > 0 { score += 2 + Double(min(hits, 3) - 1) * 0.5 }
            if place.contains(k) { score += 1 }
        }
        let p = phrase.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        if p.count >= 3, text.contains(p) { score += 3 }
        let ageDays = max(0, now.timeIntervalSince(snippet.date) / 86_400)
        return score + pow(0.5, ageDays / recencyHalfLife)
    }

    /// The best `limit` snippets for a question. With keywords, snippets that
    /// match none of them are left out; without any (a vague question), the
    /// most recent ones win.
    static func rank(_ snippets: [AskSnippet], question: String, now: Date = .now, limit: Int = limit) -> [AskSnippet] {
        let words = keywords(question)
        var unique: [String: AskSnippet] = [:]
        for s in snippets { unique[s.id] = s }
        let scored = unique.values.map { ($0, score($0, keywords: words, phrase: question, now: now)) }
        let kept = words.isEmpty ? scored : scored.filter { $0.1 >= 1.5 }
        return kept
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.date > $1.0.date }
            .prefix(limit)
            .map(\.0)
    }
}
