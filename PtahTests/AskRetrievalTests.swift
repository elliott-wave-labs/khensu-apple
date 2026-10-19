// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import KhensuKit
import Testing
@testable import Ptah

@MainActor
@Suite("Ask khėnsu retrieval")
struct AskRetrievalTests {
    private let now = Date(timeIntervalSince1970: 1_792_434_600)
    private let chat = ConversationID.random()

    private func snippet(_ id: String, _ text: String, place: String = "Ana", daysAgo: Double = 1) -> AskSnippet {
        AskSnippet(id: id, source: .chat(chat), place: place, sender: "Ana", text: text,
                   date: now.addingTimeInterval(-daysAgo * 86_400))
    }

    @Test("~ commands route to presets; / is not a command")
    func commands() {
        #expect(AskCommand("~summarize") == .summarize)
        #expect(AskCommand("  ~Summarize ") == .summarize)
        #expect(AskCommand("~find dinner plans") == .find("dinner plans"))
        #expect(AskCommand("~find") == .help)
        #expect(AskCommand("~") == .help)
        #expect(AskCommand("~dance") == .unknown("dance"))
        #expect(AskCommand("/summarize") == .ask("/summarize"))
        #expect(AskCommand("where is the party?") == .ask("where is the party?"))
    }

    @Test("Keywords drop filler words and repeats")
    func keywords() {
        #expect(AskRetrieval.keywords("What did Ana say about the Dinner on Friday? dinner!") == ["ana", "dinner", "friday"])
        #expect(AskRetrieval.keywords("Café plans") == ["cafe", "plans"])
        #expect(AskRetrieval.keywords("is it ok") == [])
    }

    @Test("Keyword matches outrank recency, and non-matches are left out")
    func ranking() {
        let snippets = [
            snippet("old-hit", "Dinner at the noodle place on Friday?", daysAgo: 30),
            snippet("new-miss", "lol", daysAgo: 0),
            snippet("new-hit", "Friday works", daysAgo: 0.1),
            snippet("double", "dinner friday, dinner friday", daysAgo: 2),
        ]
        let ranked = AskRetrieval.rank(snippets, question: "dinner friday", now: now).map(\.id)
        #expect(ranked.first == "double")
        #expect(ranked.contains("old-hit"))
        #expect(ranked.contains("new-hit"))
        #expect(!ranked.contains("new-miss"))
        #expect(ranked.firstIndex(of: "old-hit")! < ranked.firstIndex(of: "new-hit")!)
    }

    @Test("Vague questions fall back to the most recent snippets, capped at the limit")
    func recencyFallback() {
        let snippets = (0..<30).map { snippet("m\($0)", "message \($0)", daysAgo: Double($0)) }
        let ranked = AskRetrieval.rank(snippets, question: "is it ok", now: now)
        #expect(ranked.count == AskRetrieval.limit)
        #expect(ranked.first?.id == "m0")
        #expect(ranked.last?.id == "m19")
    }

    @Test("Duplicates are counted once; the chat name counts as a match")
    func duplicatesAndPlace() {
        let a = snippet("x", "see you there", place: "Climbing club")
        let ranked = AskRetrieval.rank([a, a], question: "climbing", now: now)
        #expect(ranked.map(\.id) == ["x"])
    }

    @Test("Prompt lines cite the chat and clip long text")
    func promptLine() {
        let line = snippet("p", String(repeating: "a", count: 400), place: "Ben").promptLine(3)
        #expect(line.hasPrefix("[3] Chat: Ben · "))
        #expect(line.hasSuffix("…"))
        #expect(line.count < 400)
        let prompt = AskKhensu.prompt([snippet("q", "hi")], ask: "Question: hello?")
        #expect(prompt.hasPrefix("Snippets:\n[1] Chat: Ana"))
        #expect(prompt.hasSuffix("Question: hello?"))
    }
}
