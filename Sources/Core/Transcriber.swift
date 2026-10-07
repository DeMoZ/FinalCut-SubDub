import AVFoundation
import Speech

/// A recognised word (or punctuation-attached token) with its position in the audio.
struct TimedWord {
    var text: String
    var start: Double
    var end: Double
}

enum TranscriberError: LocalizedError {
    case unsupportedLocale(String)
    case nothingRecognised

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let l): return "macOS can't transcribe \(l) speech."
        case .nothingRecognised: return "No speech recognized. Check the spoken language and audio level."
        }
    }
}

/// On-device speech recognition via SpeechAnalyzer (macOS 26+).
/// Uses SpeechTranscriber when the locale is supported (best for long-form audio),
/// otherwise falls back to DictationTranscriber, which covers more languages (Russian, Thai, …).
enum Transcriber {
    /// All locales that can be used as the source language.
    static func supportedLocales() async -> [Locale] {
        var seen = Set<String>()
        var result: [Locale] = []
        for l in await SpeechTranscriber.supportedLocales + DictationTranscriber.supportedLocales {
            let id = l.identifier(.bcp47)
            if seen.insert(id).inserted { result.append(l) }
        }
        return result
    }

    static func transcribe(fileURL: URL, locale: Locale, duration: Double,
                           status: @escaping (String) -> Void,
                           progress: @escaping (Double) -> Void) async throws -> [TimedWord] {
        let module: any SpeechModule
        let speechLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        let dictationLocale = await DictationTranscriber.supportedLocale(equivalentTo: locale)

        let speech: SpeechTranscriber?
        let dictation: DictationTranscriber?
        if let l = speechLocale {
            speech = SpeechTranscriber(locale: l, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
            dictation = nil
            module = speech!
        } else if let l = dictationLocale {
            dictation = DictationTranscriber(locale: l, contentHints: [], transcriptionOptions: [.punctuation],
                                             reportingOptions: [], attributeOptions: [.audioTimeRange])
            speech = nil
            module = dictation!
        } else {
            throw TranscriberError.unsupportedLocale(locale.identifier)
        }

        if await AssetInventory.status(forModules: [module]) != .installed {
            status("Downloading speech model (one time)…")
            _ = try? await AssetInventory.reserve(locale: speechLocale ?? dictationLocale!)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
        }
        status("Transcribing…")

        let analyzer = SpeechAnalyzer(modules: [module])
        let file = try AVAudioFile(forReading: fileURL)

        let collector = Task { () -> [TimedWord] in
            var words: [TimedWord] = []
            func add(_ text: AttributedString, _ range: CMTimeRange) {
                words.append(contentsOf: Self.words(from: text, fallback: range))
                if duration > 0 { progress(min(1, range.end.seconds / duration)) }
            }
            if let speech {
                for try await r in speech.results { add(r.text, r.range) }
            } else if let dictation {
                for try await r in dictation.results { add(r.text, r.range) }
            }
            return words
        }

        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        let words = try await collector.value
        progress(1)
        guard !words.isEmpty else { throw TranscriberError.nothingRecognised }
        return words
    }

    /// Splits a result into word-level tokens using the per-run audio time ranges.
    private static func words(from text: AttributedString, fallback: CMTimeRange) -> [TimedWord] {
        var out: [TimedWord] = []
        for run in text.runs {
            let piece = String(text[run.range].characters)
            let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self]
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if let range, range.duration.seconds > 0 || out.isEmpty {
                // A run may contain several space-separated tokens; split time evenly.
                let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
                let step = range.duration.seconds / Double(tokens.count)
                for (i, t) in tokens.enumerated() {
                    let s = range.start.seconds + step * Double(i)
                    out.append(TimedWord(text: t, start: s, end: s + step))
                }
            } else if !out.isEmpty, !piece.first!.isWhitespace {
                // Untimed punctuation glued to the previous word.
                out[out.count - 1].text += trimmed
            } else {
                let s = out.last?.end ?? fallback.start.seconds
                out.append(TimedWord(text: trimmed, start: s, end: s))
            }
        }
        if out.isEmpty {
            let t = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(TimedWord(text: t, start: fallback.start.seconds, end: fallback.end.seconds)) }
        }
        return out
    }
}
