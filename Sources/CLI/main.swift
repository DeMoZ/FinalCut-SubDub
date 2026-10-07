import Foundation

// Command-line test harness: subdub <project.fcpxml> [source-locale] [targets,comma,separated]
@main
struct CLI {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("usage: subdub <project.fcpxml> [ru-RU] [en,th]")
            exit(2)
        }
        let input = URL(fileURLWithPath: args[1])
        let locale = Locale(identifier: args.count > 2 ? args[2] : "ru-RU")
        let codes = args.count > 3 ? args[3].split(separator: ",").map(String.init) : []
        let all = await Translator.supportedTargets()
        let gender = ProcessInfo.processInfo.environment["SUBDUB_GENDER"].flatMap(VoiceGender.init(rawValue:))
        let targets = codes.compactMap { c in all.first { $0.code == c || $0.code.hasPrefix(c) } }

        do {
            let data = try Data(contentsOf: input)
            let pipeline = SubtitlePipeline(translator: InstalledTranslationProvider())
            var lastStep = ""
            let result = try await pipeline.run(
                projectData: data,
                options: .init(sourceLocale: locale, includeOriginal: true, targets: targets,
                               outputRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("out"),
                               // SUBDUB_DUB=1 also voices every target language; SUBDUB_GENDER=Male|Female picks the voice.
                               dubVoices: ProcessInfo.processInfo.environment["SUBDUB_DUB"] == "1"
                                   ? Dictionary(uniqueKeysWithValues: targets.map { t in
                                       (t.code, Dubber.defaultVoice(for: t.code, gender: gender)?.id ?? "") }) : [:]),
                report: { step, f in
                    if step != lastStep { print("\n[\(Int(f * 100))%] \(step)", terminator: ""); lastStep = step }
                })
            print("\n\nFCPXML: \(result.fcpxmlURL.path)")
            result.srtURLs.forEach { print("SRT:    \($0.path)") }
            result.dubURLs.forEach { print("DUB:    \($0.path)") }
            for t in targets { print("VOICE:  \(t.code) → \(Dubber.defaultVoice(for: t.code, gender: gender)?.name ?? "-")") }
            result.warnings.forEach { print("WARN:   \($0)") }
        } catch {
            print("\nERROR: \(error.localizedDescription)")
            exit(1)
        }
    }
}
