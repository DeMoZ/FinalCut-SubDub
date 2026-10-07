import Foundation

struct PipelineResult {
    var fcpxmlURL: URL
    var srtURLs: [URL]
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
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("FCPAutoSubs-\(UUID().uuidString)")
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

        // 3. Translations
        var tracks: [(language: SubtitleLanguage, cues: [CaptionCue])] = []
        if options.includeOriginal { tracks.append((sourceLanguage, cues)) }
        let targets = options.targets.filter { $0.code != sourceLanguage.code }
        for (i, target) in targets.enumerated() {
            report("Translating: \(target.displayName)…", 0.7 + 0.25 * Double(i) / Double(max(targets.count, 1)))
            let translated = try await translator.translate(cues.map(\.text), from: options.sourceLocale.language, to: target)
            let wrapped = zip(cues, translated).map { cue, text in
                CaptionCue(start: cue.start, end: cue.end, text: LineWrapper.wrap(text, language: target.code))
            }
            tracks.append((target, wrapped))
        }

        // 4. Output
        report("Writing captions…", 0.97)
        let langs = tracks.map(\.language.code).joined(separator: ", ")
        project.addCaptions(tracks.map { ($0.language.code, $0.cues) })
        project.markAsCopy(suffix: "— subtitles (\(langs))")

        let folder = options.outputRoot.appendingPathComponent(Self.safeName("\(project.name) \(Self.timestamp())"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fcpxmlURL = folder.appendingPathComponent(Self.safeName(project.name) + ".fcpxml")
        try project.xmlData().write(to: fcpxmlURL)

        var srtURLs: [URL] = []
        for track in tracks {
            let url = folder.appendingPathComponent("\(track.language.code).srt")
            try SRTWriter.srt(track.cues).write(to: url, atomically: true, encoding: .utf8)
            srtURLs.append(url)
        }
        report("Done", 1)
        return PipelineResult(fcpxmlURL: fcpxmlURL, srtURLs: srtURLs, outputFolder: folder,
                              cueCount: cues.count, warnings: warnings)
    }

    /// Where results go: ~/Movies/FCP AutoSubs (the real home, also from inside the sandbox).
    static var defaultOutputRoot: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Movies/FCP AutoSubs", isDirectory: true)
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
