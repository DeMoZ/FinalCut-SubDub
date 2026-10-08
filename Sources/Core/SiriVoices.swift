import AppKit
import AVFoundation

enum SiriVoicesError: LocalizedError {
    case unavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Siri voices need the SubDub app (not the Final Cut Pro panel) and Xcode installed."
        case .failed(let m): return "Siri voice failed: \(m)"
        }
    }
}

/// Siri voices through the Swift interpreter from Xcode.
///
/// macOS only gives Siri voices to programs signed by Apple. The Swift interpreter is, so the
/// SubDub app runs Tools/SiriRevoice/siri-revoice.swift with it. The Final Cut Pro panel can't:
/// it is sandboxed and may not launch other programs.
enum SiriVoices {
    /// DubVoice ids of Siri voices start with this prefix.
    static let idPrefix = "siri:"

    static var isSandboxed: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil }

    /// Xcode's Developer folder (the Command Line Tools alone are not enough on every setup).
    static var developerDir: URL? {
        let candidates = [NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode"),
                          URL(fileURLWithPath: "/Applications/Xcode.app")].compactMap { $0 }
        return candidates
            .map { $0.appendingPathComponent("Contents/Developer") }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("usr/bin").path) }
    }

    /// The helper ships inside the app; SUBDUB_SIRI_SCRIPT points the CLI at Tools/SiriRevoice/siri-revoice.swift.
    static var scriptURL: URL? {
        if let path = ProcessInfo.processInfo.environment["SUBDUB_SIRI_SCRIPT"] { return URL(fileURLWithPath: path) }
        return Bundle.main.url(forResource: "siri-revoice", withExtension: "swift")
    }

    static var isAvailable: Bool { !isSandboxed && developerDir != nil && scriptURL != nil }

    /// Downloaded Siri voices. Takes a few seconds: the interpreter compiles the script first.
    static func list() async -> [DubVoice] {
        guard isAvailable, let output = try? await run(["--list-json"]),
              let json = output.split(separator: "\n").last(where: { $0.hasPrefix("[") }),
              let items = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: String]] else { return [] }
        return items.compactMap { d in
            guard let id = d["id"], let name = d["name"], let language = d["language"] else { return nil }
            return DubVoice(siriID: id, name: name, language: language, gender: d["gender"].flatMap(VoiceGender.init(rawValue:)))
        }
    }

    /// Renders a dub track with a Siri voice. Same timing rules as `Dubber.render`.
    static func render(cues: [CaptionCue], voiceID: String, totalDuration: Double, to url: URL,
                       progress: @escaping (Double) -> Void) async throws -> [ClosedRange<Double>] {
        guard isAvailable else { throw SiriVoicesError.unavailable }
        let job: [String: Any] = [
            "voice": String(voiceID.dropFirst(idPrefix.count)),
            "output": url.path,
            "totalSeconds": totalDuration,
            "cues": cues.map { ["start": $0.start, "end": $0.end, "text": $0.text.replacingOccurrences(of: "\n", with: " ")] },
        ]
        let jobURL = FileManager.default.temporaryDirectory.appendingPathComponent("subdub-siri-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: job).write(to: jobURL)
        defer { try? FileManager.default.removeItem(at: jobURL) }

        let output = try await run(["--render", jobURL.path]) { line in
            // "PROGRESS i n"
            let parts = line.split(separator: " ")
            if parts.count == 3, parts[0] == "PROGRESS", let i = Double(parts[1]), let n = Double(parts[2]), n > 0 {
                progress(i / n)
            }
        }
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix("RANGES ") }),
              let ranges = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(7).utf8)) as? [[Double]] else {
            throw SiriVoicesError.failed("no result from the Siri helper")
        }
        return ranges.compactMap { $0.count == 2 && $0[1] >= $0[0] ? $0[0] ... $0[1] : nil }
    }

    /// Speaks a short sample (the panel's preview button).
    static func preview(_ text: String, voiceID: String) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("subdub-siri-preview.wav")
        _ = try await render(cues: [CaptionCue(start: 0, end: 4, text: text)], voiceID: voiceID, totalDuration: 0.1, to: url) { _ in }
        await MainActor.run {
            previewPlayer = try? AVAudioPlayer(contentsOf: url)
            previewPlayer?.play()
        }
    }

    @MainActor private static var previewPlayer: AVAudioPlayer?

    /// Runs the helper through `xcrun swift` and returns its standard output.
    private static func run(_ arguments: [String], onLine: ((String) -> Void)? = nil) async throws -> String {
        guard let developerDir, let scriptURL else { throw SiriVoicesError.unavailable }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swift", scriptURL.path] + arguments
        var env = ProcessInfo.processInfo.environment
        env["DEVELOPER_DIR"] = developerDir.path
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let collected = Collector()
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = String(decoding: handle.availableData, as: UTF8.self)
            for line in collected.append(chunk) { onLine?(line) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { p in
                out.fileHandleForReading.readabilityHandler = nil
                let rest = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                for line in collected.append(rest + "\n") { onLine?(line) }
                if p.terminationStatus == 0 {
                    continuation.resume(returning: collected.text)
                } else {
                    let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    continuation.resume(throwing: SiriVoicesError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    /// Thread-safe line splitter for the helper's output.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""
        private(set) var text = ""

        func append(_ chunk: String) -> [String] {
            lock.lock(); defer { lock.unlock() }
            text += chunk
            buffer += chunk
            var lines = buffer.components(separatedBy: "\n")
            buffer = lines.removeLast()
            return lines.filter { !$0.isEmpty }
        }
    }
}
