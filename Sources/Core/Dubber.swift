import AVFoundation

enum VoiceGender: String, CaseIterable, Identifiable {
    case female = "Female", male = "Male"
    var id: String { rawValue }
}

/// A system voice that can speak a subtitle language.
struct DubVoice: Identifiable, Hashable {
    let id: String          // AVSpeechSynthesisVoice.identifier
    let name: String
    let language: String    // BCP-47, e.g. "en-US"
    let quality: AVSpeechSynthesisVoiceQuality
    let gender: VoiceGender?

    var label: String {
        let region = Locale(identifier: language).region.flatMap { Locale(identifier: "en").localizedString(forRegionCode: $0.identifier) }
        let q: String
        switch quality {
        case .premium: q = " · Premium"
        case .enhanced: q = " · Enhanced"
        default: q = ""
        }
        return region.map { "\(name) (\($0))\(q)" } ?? "\(name)\(q)"
    }

    /// Modern Apple voices first, then Eloquence (Eddy, Flo…), then legacy MacinTalk (Fred, Ralph…).
    var tier: Int {
        if id.contains(".eloquence.") { return 1 }
        if id.hasPrefix("com.apple.speech.synthesis.voice.") { return 2 }
        return 0
    }

    init(_ voice: AVSpeechSynthesisVoice) {
        id = voice.identifier
        name = voice.name
        language = voice.language
        quality = voice.quality
        switch voice.gender {
        case .female: gender = .female
        case .male: gender = .male
        default: gender = Self.knownGenders[voice.name]
        }
    }

    /// Voices that don't report a gender.
    private static let knownGenders: [String: VoiceGender] = [
        "Eddy": .male, "Reed": .male, "Rocko": .male, "Grandpa": .male,
        "Flo": .female, "Sandy": .female, "Shelley": .female, "Grandma": .female,
        "Albert": .male, "Fred": .male, "Junior": .male, "Ralph": .male, "Kathy": .female,
    ]
}

enum DubberError: LocalizedError {
    case noVoice(String)

    var errorDescription: String? {
        switch self {
        case .noVoice(let l): return "No system voice is installed for \(l). Add one in System Settings ▸ Accessibility ▸ Spoken Content ▸ System Voice ▸ Manage Voices."
        }
    }
}

/// Voice-over: speaks translated cues with on-device Apple voices and renders one
/// audio file per language that lines up with the timeline (file time 0 = sequence start).
enum Dubber {
    static let sampleRate: Double = 48_000
    /// Fastest speed-up allowed to make a line fit its slot, relative to the default rate.
    static let maxSpeedUp = 1.35

    /// Voices for a subtitle language code ("en", "zh-Hans", "pt-BR", …), best quality first.
    static func voices(for code: String) -> [DubVoice] {
        let wanted = Locale.Language(identifier: code)
        let all = AVSpeechSynthesisVoice.speechVoices().filter { v in
            let l = Locale.Language(identifier: v.language)
            guard l.languageCode == wanted.languageCode else { return false }
            if code == "zh-Hant" { return ["TW", "HK"].contains(l.region?.identifier ?? "") }
            if code == "zh-Hans" { return l.region?.identifier == "CN" }
            if code.contains("-"), let r = wanted.region { return l.region == r }
            return true
        }
        // Novelty voices (Bells, Bubbles, …) are not useful for dubbing.
        let usable = all.filter { !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice) }
        return usable
            .map(DubVoice.init)
            .sorted { a, b in
                if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
                if a.tier != b.tier { return a.tier < b.tier }
                return a.name < b.name
            }
    }

    /// Best voice for a language, preferring the requested gender when one is installed.
    static func defaultVoice(for code: String, gender: VoiceGender? = nil) -> DubVoice? {
        let all = voices(for: code)
        let list = gender.map { g in all.filter { $0.gender == g } }.flatMap { $0.isEmpty ? nil : $0 } ?? all
        // Among the best-quality tier, prefer the user's region of that language.
        guard let best = list.first else { return nil }
        // Then the language's main region (en → US, es → ES, …).
        let regions = [Locale.current.region?.identifier,
                       Locale.Language(identifier: Locale.Language(identifier: code).maximalIdentifier).region?.identifier]
        for region in regions.compactMap({ $0 }) {
            if let v = list.first(where: { $0.quality == best.quality && $0.tier == best.tier && Locale(identifier: $0.language).region?.identifier == region }) {
                return v
            }
        }
        return best
    }

    /// Speaks every cue and writes a 48 kHz mono WAV aligned to the timeline.
    /// - Returns: the speech ranges actually used (seconds), for ducking the original audio.
    static func render(cues: [CaptionCue], voiceID: String?, languageCode: String, totalDuration: Double,
                       to url: URL, progress: @escaping (Double) -> Void) async throws -> [ClosedRange<Double>] {
        guard let voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? defaultVoice(for: languageCode).flatMap({ AVSpeechSynthesisVoice(identifier: $0.id) }) else {
            throw DubberError.noVoice(languageCode)
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)

        let synth = Synthesizer()
        var written: AVAudioFramePosition = 0
        var ranges: [ClosedRange<Double>] = []

        for (i, cue) in cues.enumerated() {
            try Task.checkCancellation()
            let text = cue.text.replacingOccurrences(of: "\n", with: " ")
            let slotEnd = i + 1 < cues.count ? cues[i + 1].start : max(cue.end, totalDuration)
            let slot = max(0.3, slotEnd - cue.start)

            var rate = AVSpeechUtteranceDefaultSpeechRate
            var speech = try await synth.speak(text, voice: voice, rate: rate, format: format)
            // Too long for its slot: speed up (measured, two refinement passes).
            for _ in 0..<2 where speech.duration > slot * 1.02 {
                let currentSpeed = 1 + Double(rate - AVSpeechUtteranceDefaultSpeechRate) / 0.36
                let speedUp = min(maxSpeedUp, currentSpeed * speech.duration / slot)
                let newRate = Self.rate(forSpeedUp: speedUp)
                guard newRate > rate + 0.005 else { break }
                rate = newRate
                speech = try await synth.speak(text, voice: voice, rate: rate, format: format)
            }

            let startFrame = max(AVAudioFramePosition(cue.start * sampleRate), written)
            if startFrame > written { try writeSilence(startFrame - written, to: file, format: format) }
            try file.write(from: speech.buffer)
            written = startFrame + AVAudioFramePosition(speech.buffer.frameLength)
            ranges.append(Double(startFrame) / sampleRate ... Double(written) / sampleRate)
            progress(Double(i + 1) / Double(cues.count))
        }
        let total = AVAudioFramePosition(totalDuration * sampleRate)
        if total > written { try writeSilence(total - written, to: file, format: format) }
        return ranges
    }

    /// AVSpeechUtterance.rate is not linear; this mapping was measured to be close
    /// to the real speed-up between the default rate (0.5) and ~0.62.
    private static func rate(forSpeedUp s: Double) -> Float {
        let r = AVSpeechUtteranceDefaultSpeechRate + Float((s - 1) * 0.36)
        return min(max(r, AVSpeechUtteranceDefaultSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    private static func writeSilence(_ frames: AVAudioFramePosition, to file: AVAudioFile, format: AVAudioFormat) throws {
        var remaining = frames
        while remaining > 0 {
            let n = AVAudioFrameCount(min(remaining, 65_536))
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
            buf.frameLength = n
            memset(buf.floatChannelData![0], 0, Int(n) * MemoryLayout<Float>.size)
            try file.write(from: buf)
            remaining -= AVAudioFramePosition(n)
        }
    }
}

/// Wraps AVSpeechSynthesizer.write into async/await and converts output to one format.
private final class Synthesizer {
    struct Speech {
        var buffer: AVAudioPCMBuffer
        var duration: Double { Double(buffer.frameLength) / buffer.format.sampleRate }
    }

    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String, voice: AVSpeechSynthesisVoice, rate: Float, format: AVAudioFormat) async throws -> Speech {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0

        let pieces: [AVAudioPCMBuffer] = await withCheckedContinuation { continuation in
            var collected: [AVAudioPCMBuffer] = []
            var finished = false
            synthesizer.write(utterance) { buffer in
                guard !finished else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    finished = true
                    continuation.resume(returning: collected)
                    return
                }
                collected.append(pcm)
            }
        }
        let merged = try convert(pieces, to: format)
        return Speech(buffer: trimSilence(merged))
    }

    private func convert(_ pieces: [AVAudioPCMBuffer], to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let first = pieces.first else { return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)! }
        let inFrames = pieces.reduce(0) { $0 + Int($1.frameLength) }
        let ratio = format.sampleRate / first.format.sampleRate
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(inFrames) * ratio) + 4096)!
        guard let converter = AVAudioConverter(from: first.format, to: format) else { return out }

        var index = 0
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if index < pieces.count {
                status.pointee = .haveData
                defer { index += 1 }
                return pieces[index]
            }
            status.pointee = .endOfStream
            return nil
        }
        if let error { throw error }
        return out
    }

    /// Removes leading/trailing near-silence the synthesizer adds around speech.
    private func trimSilence(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return buffer }
        let n = Int(buffer.frameLength)
        let threshold: Float = 0.003
        var start = 0
        while start < n && abs(data[start]) < threshold { start += 1 }
        var end = n
        while end > start && abs(data[end - 1]) < threshold { end -= 1 }
        // Keep a few milliseconds so words don't start abruptly.
        let pad = Int(buffer.format.sampleRate * 0.02)
        start = max(0, start - pad)
        end = min(n, end + pad)
        guard end > start, start > 0 || end < n else { return buffer }
        let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(end - start))!
        out.frameLength = AVAudioFrameCount(end - start)
        memcpy(out.floatChannelData![0], data + start, (end - start) * MemoryLayout<Float>.size)
        return out
    }
}
