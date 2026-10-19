// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import FoundationModels
import KhensuKit
import Observation
import os

/// Ask khėnsu (nu.ral): questions about your own chats and posts, answered by
/// Apple's on-device model from snippets found locally. Nothing leaves the
/// device: no server, no Private Cloud Compute.
@MainActor @Observable
final class AskKhensu {
    enum Phase: Equatable { case idle, searching, answering, done, failed(String) }

    private(set) var phase: Phase = .idle
    private(set) var answer = ""
    private(set) var sources: [AskSnippet] = []
    private(set) var heading = ""
    private var task: Task<Void, Never>?
    private let log = Logger(subsystem: "nu.khensu.ptah", category: "ask")

    /// Why the on-device model can't run, in words for the person; nil when it can.
    var unavailableReason: String? { Self.unavailableReason(SystemLanguageModel.default.availability) }

    static func unavailableReason(_ availability: SystemLanguageModel.Availability) -> String? {
        switch availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This device can't run Apple Intelligence, so Ask khėnsu can't answer here. Search and ~find still work."
            case .appleIntelligenceNotEnabled:
                return "Turn on Apple Intelligence in Settings to use Ask khėnsu. It runs on this device only."
            case .modelNotReady:
                return "The on-device model is still downloading or getting ready. Try again in a little while."
            @unknown default:
                return "Ask khėnsu isn't available on this device right now."
            }
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        phase = .idle
        answer = ""
        sources = []
        heading = ""
    }

    func run(_ input: String, app: AppModel) {
        task?.cancel()
        answer = ""
        sources = []
        let command = AskCommand(input)
        task = Task { await perform(command, app: app) }
    }

    private func perform(_ command: AskCommand, app: AppModel) async {
        switch command {
        case .help, .ask(""):
            phase = .idle
        case .unknown(let name):
            heading = "~\(name)"
            phase = .failed("There's no ~\(name). Try " + AskCommand.commands.map(\.name).joined(separator: " or ") + ".")
        case .ask(let question):
            heading = question
            phase = .searching
            let found = await gather(question, app: app)
            guard !Task.isCancelled else { return }
            sources = found
            guard !found.isEmpty else {
                answer = "Nothing in your chats or posts matches that."
                phase = .done
                return
            }
            await stream(instructions: Self.answerInstructions,
                         prompt: Self.prompt(found, ask: "Question: \(question)"))
        case .find(let words):
            heading = "~find \(words)"
            phase = .searching
            let found = await gather(words, app: app)
            guard !Task.isCancelled else { return }
            sources = found
            guard !found.isEmpty else {
                answer = "Nothing mentions “\(words)”."
                phase = .done
                return
            }
            guard unavailableReason == nil else {
                phase = .done
                return
            }
            await stream(instructions: Self.answerInstructions,
                         prompt: Self.prompt(found, ask: "List every snippet that mentions “\(words)”, one short line each with the chat in brackets."))
        case .summarize:
            phase = .searching
            guard let chat = app.conversation(app.selectedConversation) ?? app.conversations.max(by: { $0.lastActivity < $1.lastActivity }) else {
                heading = "~summarize"
                answer = "There are no chats to summarize yet."
                phase = .done
                return
            }
            heading = "~summarize \(chat.title)"
            let messages = ((try? await app.core.messages(in: chat.id)) ?? []).sorted { $0.sentAt < $1.sentAt }.suffix(40)
            var snippets: [AskSnippet] = []
            for m in messages { snippets.append(await snippet(m, in: chat, app: app)) }
            guard !Task.isCancelled else { return }
            sources = snippets.reversed()
            guard !snippets.isEmpty else {
                answer = "\(chat.title) has no messages yet."
                phase = .done
                return
            }
            await stream(instructions: Self.summaryInstructions,
                         prompt: Self.prompt(snippets, ask: "Summarize the chat “\(chat.title)”."))
        }
    }

    private func stream(instructions: String, prompt: String) async {
        if let reason = unavailableReason {
            phase = .failed(reason)
            return
        }
        phase = .answering
        do {
            let session = LanguageModelSession(instructions: instructions)
            for try await snapshot in session.streamResponse(to: prompt) {
                guard !Task.isCancelled else { return }
                answer = snapshot.content
            }
            phase = .done
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            phase = .failed("That's more than the on-device model can read at once. Ask something narrower.")
        } catch is CancellationError {
            return
        } catch {
            log.error("ask: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Retrieval

    /// The core's local search for the whole question and each keyword, plus
    /// recent messages from the latest chats and this device's feed posts, ranked.
    private func gather(_ question: String, app: AppModel) async -> [AskSnippet] {
        var messages: [MessageID: Message] = [:]
        for query in [question] + AskRetrieval.keywords(question).prefix(6) {
            for m in (try? await app.core.search(query)) ?? [] { messages[m.id] = m }
        }
        let recentChats = app.conversations.sorted { $0.lastActivity > $1.lastActivity }.prefix(8)
        for chat in recentChats {
            for m in ((try? await app.core.messages(in: chat.id)) ?? []).suffix(60) { messages[m.id] = m }
        }
        var snippets: [AskSnippet] = []
        for m in messages.values {
            guard let chat = app.conversation(m.conversationID) else { continue }
            snippets.append(await snippet(m, in: chat, app: app))
        }
        let me = app.identity?.handle.map { "You (@\($0.name))" } ?? "You"
        snippets += MyFeedPosts.load().map {
            AskSnippet(id: "post-\($0.id)", source: .post, place: "Your feed posts", sender: me, text: $0.caption, date: $0.createdAt)
        }
        return AskRetrieval.rank(snippets.filter { !$0.text.isEmpty }, question: question)
    }

    private func snippet(_ m: Message, in chat: Conversation, app: AppModel) async -> AskSnippet {
        var sender = "You"
        if case .contact(let address) = m.sender {
            sender = chat.kind == .direct ? chat.title : "Someone"
            if chat.kind != .direct, let contact = await app.core.contact(address) { sender = contact.displayName }
        }
        return AskSnippet(id: m.id.raw.hex, source: .chat(chat.id), place: chat.title, sender: sender,
                          text: m.body.previewText, date: m.sentAt)
    }

    // MARK: Prompt

    static let answerInstructions = """
        You are Ask khėnsu, a private assistant that runs only on this person's device. \
        Answer only from the numbered snippets you are given. They are the person's own messages and posts. \
        After each fact, cite the chat it came from in square brackets, for example [Ana]. \
        If the snippets don't answer the question, say you couldn't find it in their chats. \
        Never invent messages, people, dates or details. Keep the answer short.
        """

    static let summaryInstructions = """
        You are Ask khėnsu, a private assistant that runs only on this person's device. \
        Summarize the chat from the numbered messages you are given, in three to six short bullet points: \
        what was discussed, anything decided, and anything still open. \
        Use only what the messages say. Name people as they appear. Never invent details.
        """

    static func prompt(_ snippets: [AskSnippet], ask: String) -> String {
        let lines = snippets.enumerated().map { $1.promptLine($0 + 1) }.joined(separator: "\n")
        return "Snippets:\n\(lines)\n\n\(ask)"
    }
}
