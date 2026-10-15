// SPDX-License-Identifier: AGPL-3.0-only

import KhensuKit
import SwiftUI
import Translation

/// Captions under a voice/video note, plus optional on-device auto-translation.
struct MessageCaptions: View {
    let sourceText: String?
    var audioData: Data? = nil
    /// When false, only the translation line is shown (source is already visible above).
    var showSourceCaption: Bool = true

    @AppStorage(SettingsKey.showCaptions) private var showCaptions = true
    @AppStorage(SettingsKey.autoTranslate) private var autoTranslate = true
    @State private var transcript: String?
    @State private var translated: String?
    @State private var status: String?
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var busy = false

    private var displaySource: String? {
        let t = transcript ?? sourceText
        let s = t?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }

    var body: some View {
        let wantsCaption = showCaptions && showSourceCaption
        let wantsTranslate = autoTranslate
        Group {
            if wantsCaption || wantsTranslate, displaySource != nil || audioData != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let status, displaySource == nil {
                        Text(status).font(.caption2).foregroundStyle(.secondary)
                    }
                    if wantsCaption, let displaySource {
                        Text(displaySource)
                            .font(.footnote)
                            .foregroundStyle(.primary.opacity(0.92))
                            .textSelection(.enabled)
                            .accessibilityLabel("Caption")
                    }
                    if wantsTranslate, let translated, translated != displaySource {
                        Text(translated)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .accessibilityLabel("Translation")
                    } else if wantsTranslate, busy, displaySource != nil, translated == nil {
                        Text("Translating on this device…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .task(id: taskKey) { await refresh() }
                .translationTask(translationConfig) { session in
                    let text = displaySource
                    guard let text else { return }
                    // TranslationSession isn’t Sendable; the task owns the session for this call.
                    nonisolated(unsafe) let session = session
                    do {
                        try await session.prepareTranslation()
                        let response = try await session.translate(text)
                        let out = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                        await MainActor.run {
                            translated = out.isEmpty ? text : out
                            busy = false
                            translationConfig = nil
                        }
                    } catch {
                        await MainActor.run {
                            status = error.localizedDescription
                            busy = false
                            translationConfig = nil
                        }
                    }
                }
            }
        }
    }

    private var taskKey: String {
        "\(showCaptions)-\(autoTranslate)-\(showSourceCaption)-\(sourceText ?? "")-\(audioData?.count ?? 0)"
    }

    @MainActor
    private func refresh() async {
        status = nil
        translated = nil
        if showCaptions, transcript == nil, let audioData, !audioData.isEmpty {
            busy = true
            status = "Captioning on this device…"
            do {
                transcript = try await OnDeviceCaptions.transcribe(data: audioData)
                status = nil
            } catch {
                status = error.localizedDescription
            }
            busy = false
        }
        guard autoTranslate, let displaySource else { return }
        busy = true
        translationConfig = .init(source: nil, target: Locale.current.language)
    }
}

/// Plain message text with optional on-device auto-translation underneath.
struct AutoTranslatedText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).textSelection(.enabled)
            MessageCaptions(sourceText: text, showSourceCaption: false)
        }
    }
}
