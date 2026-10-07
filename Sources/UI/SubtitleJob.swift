import AVFoundation
import SwiftUI
import Translation

/// State of the panel: loaded project, chosen languages, and the running job.
@MainActor
final class SubtitleJob: ObservableObject {
    enum Phase {
        case idle
        case running(step: String, fraction: Double)
        case done(PipelineResult, importError: String?)
        case failed(String)
    }

    struct LoadedProject {
        var data: Data
        var name: String
        var duration: Double
    }

    @Published var project: LoadedProject?
    @Published var loadError: String?
    @Published var phase: Phase = .idle

    @Published var sourceLocales: [Locale] = []
    @Published var targetLanguages: [SubtitleLanguage] = []

    @Published var sourceLocaleID: String {
        didSet {
            UserDefaults.standard.set(sourceLocaleID, forKey: "sourceLocale")
            Task { await refreshDownloads() }
        }
    }
    @Published var selectedTargets: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(selectedTargets), forKey: "targets")
            Task { await refreshDownloads() }
        }
    }

    /// Selected translation languages that still need a one-time download.
    @Published var notDownloaded: [SubtitleLanguage] = []
    @Published var downloadingLanguage: String?
    @Published var downloadError: String?
    @Published var includeOriginal: Bool {
        didSet { UserDefaults.standard.set(includeOriginal, forKey: "includeOriginal") }
    }

    // Output
    enum OriginalAudioMode: String, CaseIterable, Identifiable {
        case keep = "Keep", lower = "Lower", mute = "Mute"
        var id: String { rawValue }
    }

    @Published var makeCaptions: Bool {
        didSet { UserDefaults.standard.set(makeCaptions, forKey: "makeCaptions") }
    }
    @Published var makeDub: Bool {
        didSet { UserDefaults.standard.set(makeDub, forKey: "makeDub") }
    }
    /// Chosen voice per language code (missing = default voice).
    @Published var dubVoices: [String: String] {
        didSet { UserDefaults.standard.set(dubVoices, forKey: "dubVoices") }
    }
    @Published var originalAudio: OriginalAudioMode {
        didSet { UserDefaults.standard.set(originalAudio.rawValue, forKey: "originalAudio") }
    }

    private var voiceCache: [String: [DubVoice]] = [:]
    private let previewSynth = AVSpeechSynthesizer()

    let translator = TranslationBroker()
    private var task: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    init() {
        let d = UserDefaults.standard
        sourceLocaleID = d.string(forKey: "sourceLocale") ?? "ru-RU"
        selectedTargets = Set(d.stringArray(forKey: "targets") ?? ["en", "th"])
        includeOriginal = d.object(forKey: "includeOriginal") as? Bool ?? true
        makeCaptions = d.object(forKey: "makeCaptions") as? Bool ?? true
        makeDub = d.object(forKey: "makeDub") as? Bool ?? false
        dubVoices = d.dictionary(forKey: "dubVoices") as? [String: String] ?? [:]
        originalAudio = OriginalAudioMode(rawValue: d.string(forKey: "originalAudio") ?? "") ?? .lower
    }

    func voices(for language: SubtitleLanguage) -> [DubVoice] {
        if let cached = voiceCache[language.code] { return cached }
        let list = Dubber.voices(for: language.code)
        voiceCache[language.code] = list
        return list
    }

    /// The voice used for a language: the saved choice if it is still installed, else the default.
    func voiceID(for language: SubtitleLanguage) -> String {
        let list = voices(for: language)
        if let saved = dubVoices[language.code], list.contains(where: { $0.id == saved }) { return saved }
        return Dubber.defaultVoice(for: language.code)?.id ?? ""
    }

    func setVoice(_ id: String, for language: SubtitleLanguage) {
        dubVoices[language.code] = id
    }

    func preview(_ language: SubtitleLanguage) {
        previewSynth.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: Self.sample(for: language))
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceID(for: language))
        previewSynth.speak(utterance)
    }

    /// Refreshes the voice list, e.g. after the user installs voices in System Settings.
    func reloadVoices() {
        voiceCache = [:]
        objectWillChange.send()
    }

    static func openVoiceSettings() {
        for s in ["x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent",
                  "x-apple.systempreferences:com.apple.Accessibility-Settings.extension"] {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }

    private static func sample(for language: SubtitleLanguage) -> String {
        let samples = [
            "ar": "هكذا سيبدو التعليق الصوتي.", "de": "So klingt die Synchronisation.",
            "en": "This is how the voice-over will sound.", "es": "Así sonará el doblaje.",
            "fr": "Voici comment sonnera le doublage.", "hi": "वॉइस-ओवर ऐसा सुनाई देगा।",
            "id": "Beginilah suara sulih suaranya.", "it": "Ecco come suonerà il doppiaggio.",
            "ja": "吹き替えはこのように聞こえます。", "ko": "더빙은 이렇게 들립니다.",
            "nl": "Zo klinkt de voice-over.", "pl": "Tak będzie brzmiał lektor.",
            "pt": "É assim que a dublagem vai soar.", "ru": "Так будет звучать озвучка.",
            "th": "นี่คือตัวอย่างเสียงพากย์", "tr": "Seslendirme böyle duyulacak.",
            "uk": "Так звучатиме озвучення.", "vi": "Đây là giọng lồng tiếng.",
            "zh": "这是配音的效果。",
        ]
        let key = String(language.code.prefix(2))
        if language.code == "zh-Hant" { return "這是配音的效果。" }
        return samples[key] ?? language.nativeName
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var sourceLanguage: SubtitleLanguage { SubtitleLanguage(Locale(identifier: sourceLocaleID).language) }

    var canStart: Bool {
        guard project != nil, !isRunning, downloadingLanguage == nil else { return false }
        let captions = makeCaptions && (includeOriginal || !effectiveTargets.isEmpty)
        let dub = makeDub && !effectiveTargets.isEmpty
        return captions || dub
    }

    /// Selected targets in display order, without the source language itself.
    var effectiveTargets: [SubtitleLanguage] {
        targetLanguages.filter { selectedTargets.contains($0.code) && $0.code != sourceLanguage.code }
    }

    func loadLanguages() async {
        guard sourceLocales.isEmpty else { return }
        let locales = await Transcriber.supportedLocales()
        let en = Locale(identifier: "en")
        sourceLocales = locales.sorted {
            (en.localizedString(forIdentifier: $0.identifier) ?? "") < (en.localizedString(forIdentifier: $1.identifier) ?? "")
        }
        if !sourceLocales.contains(where: { $0.identifier(.bcp47) == sourceLocaleID }),
           let first = sourceLocales.first(where: { $0.language.languageCode?.identifier == "ru" }) ?? sourceLocales.first {
            sourceLocaleID = first.identifier(.bcp47)
        }
        targetLanguages = await Translator.supportedTargets()
        await refreshDownloads()
    }

    func refreshDownloads() async {
        let source = Locale(identifier: sourceLocaleID).language
        var missing: [SubtitleLanguage] = []
        for target in effectiveTargets {
            if await LanguageAvailability().status(from: source, to: target.language) == .supported {
                missing.append(target)
            }
        }
        notDownloaded = missing
        if missing.isEmpty {
            downloadError = nil
            pollTask?.cancel()
            pollTask = nil
        } else if pollTask == nil {
            // Downloads continue in the background after the system dialog closes: keep checking.
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, !Task.isCancelled else { return }
                    await self.refreshDownloads()
                }
            }
        }
    }

    /// Downloads every missing language one by one through the system prompt.
    func downloadMissing() async {
        downloadError = nil
        let source = Locale(identifier: sourceLocaleID).language
        for target in notDownloaded {
            downloadingLanguage = target.displayName
            do {
                try await translator.download(from: source, to: target)
            } catch {
                downloadError = error.localizedDescription
                break
            }
        }
        downloadingLanguage = nil
        await refreshDownloads()
        if downloadError == nil, !notDownloaded.isEmpty {
            let names = notDownloaded.map(\.displayName).joined(separator: ", ")
            downloadError = "\(names) not downloaded yet. In the system dialog click Download next to each language and wait until it finishes — or use Open Settings. This panel updates automatically."
        }
    }

    func load(_ data: Data) {
        do {
            let p = try FCPXMLProject(data: data)
            project = LoadedProject(data: data, name: p.name, duration: p.duration)
            loadError = nil
            phase = .idle
        } catch {
            loadError = error.localizedDescription
        }
    }

    func toggle(_ language: SubtitleLanguage) {
        if selectedTargets.contains(language.code) {
            selectedTargets.remove(language.code)
        } else {
            selectedTargets.insert(language.code)
        }
    }

    func start() {
        guard let project, canStart else { return }
        let original: FCPXMLProject.OriginalAudio
        switch originalAudio {
        case .keep: original = .keep
        case .lower: original = .duck(dB: -15)
        case .mute: original = .mute
        }
        let options = SubtitlePipeline.Options(
            sourceLocale: Locale(identifier: sourceLocaleID),
            includeOriginal: includeOriginal,
            targets: effectiveTargets,
            outputRoot: SubtitlePipeline.defaultOutputRoot,
            captions: makeCaptions,
            dubVoices: makeDub ? Dictionary(uniqueKeysWithValues: effectiveTargets.map { ($0.code, voiceID(for: $0)) }) : [:],
            originalAudio: original)
        let pipeline = SubtitlePipeline(translator: translator)
        phase = .running(step: "Preparing…", fraction: 0)

        task = Task {
            do {
                let result = try await pipeline.run(projectData: project.data, options: options) { step, fraction in
                    Task { @MainActor in
                        if case .running = self.phase { self.phase = .running(step: step, fraction: fraction) }
                    }
                }
                try Task.checkCancellation()
                var importError: String?
                do {
                    try await FinalCutBridge.importIntoFinalCut(result.fcpxmlURL)
                } catch {
                    importError = error.localizedDescription
                }
                phase = .done(result, importError: importError)
                await refreshDownloads()
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
                await refreshDownloads()
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }
}
