// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import Foundation
import Speech
import Translation

/// On-device captions (SpeechAnalyzer / SpeechTranscriber) and translation (Translation).
/// Nothing leaves the device — PLAN.md: no cloud speech or translation.
enum OnDeviceCaptions {
    enum CaptionError: Error, LocalizedError {
        case speechUnavailable
        case emptyAudio
        case translationUnavailable

        var errorDescription: String? {
            switch self {
            case .speechUnavailable: "On-device speech recognition isn’t available on this device."
            case .emptyAudio: "No audio to caption."
            case .translationUnavailable: "On-device translation isn’t ready for this language pair."
            }
        }
    }

    /// Transcribe a local audio file. Downloads the locale model on device when needed.
    static func transcribe(fileURL: URL, locale: Locale = .current) async throws -> String {
        guard SpeechTranscriber.isAvailable else { throw CaptionError.speechUnavailable }
        let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
        let transcriber = SpeechTranscriber(locale: resolved, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: fileURL)
        guard file.length > 0 else { throw CaptionError.emptyAudio }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let collected: String = {
            var parts: [String] = []
            for try await result in transcriber.results {
                let s = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { parts.append(s) }
            }
            return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        _ = try await analyzer.analyzeSequence(from: file)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let text = try await collected
        guard !text.isEmpty else { throw CaptionError.emptyAudio }
        return text
    }

    /// Transcribe in-memory audio (e.g. a voice-note preview) via a short temp file.
    static func transcribe(data: Data, locale: Locale = .current) async throws -> String {
        guard !data.isEmpty else { throw CaptionError.emptyAudio }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("khensu-caption-\(UUID().uuidString).caf")
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await transcribe(fileURL: url, locale: locale)
    }

    /// Standalone translate when a session can be opened for the device language.
    static func translate(_ text: String, to target: Locale.Language = Locale.current.language) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        let availability = LanguageAvailability()
        let status = try await availability.status(for: trimmed, to: target)
        guard status == .installed || status == .supported else {
            throw CaptionError.translationUnavailable
        }
        // Bootstrap with English as installed source when the device language isn’t installed yet;
        // `translate(_:)` still detects the source from the string on device.
        let source = Locale.Language(identifier: "en")
        let session = TranslationSession(installedSource: source, target: target)
        try await session.prepareTranslation()
        let response = try await session.translate(trimmed)
        let out = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? text : out
    }
}
