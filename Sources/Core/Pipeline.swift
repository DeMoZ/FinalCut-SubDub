import AVFoundation

struct PipelineResult {
    var fcpxmlURL: URL
    var srtURLs: [URL]
    var dubURLs: [URL]
    var outputFolder: URL
    var cueCount: Int
    var warnings: [String]
}

/// Project → mixdown → speech recognition → cues → translations → FCPXML with caption lanes + SRT files.
final class SubtitlePipeline {
    struct Options {
        var sourceLocale: Locale
        var includeOriginal: Bool
        var targets: [SubtitleLanguage]
        var outputRoot: URL
        /// Add caption roles (subtitles).
        var captions: Bool = true
        /// Voice-over languages: language code → voice identifier ("" = default voice).
        var dubVoices: [String: String] = [:]
        var originalAudio: FCPXMLProject.OriginalAudio = .duck(dB: -15)
    }

    typealias Report = (_ step: String, _ fraction: Double) -> Void

    private let translator: TranslationProvider

    init(translator: TranslationProvider) {
        self.translator = translator
    }

    func run(projectData: Data, options: Options, report: @escaping Report) async throws -> PipelineResult {
        let project = try FCPXMLProject(data: projectData)
        var warnings: [String] = []

        // 1. Audio
        report("Mixing timeline audio…", 0)
        let pieces = project.audioPieces()
        if project.skippedRetimedClips > 0 {
            warnings.append("Skipped retimed clips: \(project.skippedRetimedClips).")
        }
        if !project.missingMediaFiles.isEmpty {
            warnings.append("Missing media: \(project.missingMediaFiles.prefix(5).joined(separator: ", "))")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("SubDub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let audioURL = work.appendingPathComponent("mix.caf")
        try await AudioMixdown.render(pieces: pieces, totalDuration: project.duration, to: audioURL) { p in
            report("Mixing timeline audio…", 0.15 * p)
        }

        // 2. Speech
        var step = "Transcribing…"
        let words = try await Transcriber.transcribe(
            fileURL: audioURL, locale: options.sourceLocale, duration: project.duration,
            status: { s in step = s; report(s, 0.15) },
            progress: { p in report(step, 0.15 + 0.55 * p) })

        let sourceLanguage = SubtitleLanguage(options.sourceLocale.language)
        let cues = Segmenter.cues(from: words, language: sourceLanguage.code)
        let dubbing = options.dubVoices.filter { $0.key != sourceLanguage.code }

        // 3. Translations
        var tracks: [(language: SubtitleLanguage, cues: [CaptionCue], spoken: [CaptionCue])] = []
        if options.includeOriginal && options.captions { tracks.append((sourceLanguage, cues, cues)) }
        let targets = options.targets.filter { $0.code != sourceLanguage.code && (options.captions || dubbing[$0.code] != nil) }
        for (i, target) in targets.enumerated() {
            report("Translating: \(target.displayName)…", 0.7 + 0.1 * Double(i) / Double(max(targets.count, 1)))
            let translated = try await translator.translate(cues.map(\.text), from: options.sourceLocale.language, to: target)
            let spoken = zip(cues, translated).map { CaptionCue(start: $0.start, end: $0.end, text: $1) }
            let wrapped = spoken.map { CaptionCue(start: $0.start, end: $0.end, text: LineWrapper.wrap($0.text, language: target.code)) }
            tracks.append((target, wrapped, spoken))
        }

        // 4. Output
        let captionCodes = options.captions ? tracks.map(\.language.code) : []
        let dubTracks = tracks.filter { dubbing[$0.language.code] != nil }
        var parts: [String] = []
        if !captionCodes.isEmpty { parts.append("subtitles") }
        if !dubTracks.isEmpty { parts.append("dub") }
        let langs = (captionCodes + dubTracks.map(\.language.code)).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        project.markAsCopy(suffix: "— \(parts.joined(separator: " + ")) (\(langs.joined(separator: ", ")))")
        project.assignLibraryFromMedia()

        let folder = options.outputRoot.appendingPathComponent(Self.safeName("\(project.name) \(Self.timestamp())"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // 5. Voice-over
        var voiceTracks: [(name: String, url: URL, frames: Int64, sampleRate: Int64)] = []
        var speech: [ClosedRange<Double>] = []
        for (i, track) in dubTracks.enumerated() {
            let base = 0.8 + 0.17 * Double(i) / Double(dubTracks.count)
            report("Voicing: \(track.language.displayName)…", base)
            let url = folder.appendingPathComponent("dub-\(track.language.code).wav")
            let voice = dubbing[track.language.code].flatMap { $0.isEmpty ? nil : $0 }
            let ranges = try await Dubber.render(cues: track.spoken, voiceID: voice, languageCode: track.language.code,
                                                 totalDuration: project.duration, to: url) { p in
                report("Voicing: \(track.language.displayName)…", base + 0.17 * p / Double(dubTracks.count))
            }
            speech += ranges
            let frames = try AVAudioFile(forReading: url).length
            voiceTracks.append((track.language.displayName, url, frames, Int64(Dubber.sampleRate)))
        }

        report("Writing project…", 0.97)
        if options.captions {
            project.addCaptions(tracks.map { ($0.language.code, $0.cues) })
        }
        if !voiceTracks.isEmpty {
            project.addVoiceOver(voiceTracks, original: options.originalAudio, speech: speech)
        }

        let fcpxmlURL = folder.appendingPathComponent(Self.safeName(project.name) + ".fcpxml")
        try project.xmlData().write(to: fcpxmlURL)

        var srtURLs: [URL] = []
        if options.captions {
            for track in tracks {
                let url = folder.appendingPathComponent("\(track.language.code).srt")
                try SRTWriter.srt(track.cues).write(to: url, atomically: true, encoding: .utf8)
                srtURLs.append(url)
            }
        }
        report("Done", 1)
        return PipelineResult(fcpxmlURL: fcpxmlURL, srtURLs: srtURLs, dubURLs: voiceTracks.map(\.url),
                              outputFolder: folder, cueCount: cues.count, warnings: warnings)
    }

    /// Where results go: ~/Movies/SubDub (the real home, also from inside the sandbox).
    static var defaultOutputRoot: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Movies/SubDub", isDirectory: true)
    }

    private static func safeName(_ s: String) -> String {
        String(s.map { "/:\\".contains($0) ? "-" : $0 }.prefix(120))
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }
}
