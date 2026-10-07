import AppKit
import SwiftUI
import Translation

enum TranslationBrokerError: LocalizedError {
    case noPrompt(String)

    var errorDescription: String? {
        switch self {
        case .noPrompt(let language):
            return "macOS didn't start the download for \(language). Download it in System Settings ▸ General ▸ Language & Region ▸ Translation Languages, then try again."
        }
    }
}

/// Translation through SwiftUI's `translationTask`, so macOS can show its own
/// "download language" prompt the first time a language is used.
/// Languages that are already installed are translated directly, without UI.
@MainActor
final class TranslationBroker: ObservableObject, TranslationProvider {
    @Published var configuration: TranslationSession.Configuration?

    private struct Job {
        var texts: [String]?          // nil = only download the language
        var languageName: String
        var continuation: CheckedContinuation<[String], Error>
    }

    private var pending: Job?
    private var timeout: Task<Void, Never>?

    /// How long to wait for the system to hand us a session before giving up.
    private static let sessionTimeout: Duration = .seconds(20)

    nonisolated func translate(_ texts: [String], from source: Locale.Language, to target: SubtitleLanguage) async throws -> [String] {
        let status = await LanguageAvailability().status(from: source, to: target.language)
        if status == .installed {
            return try await InstalledTranslationProvider().translate(texts, from: source, to: target)
        }
        if status == .unsupported {
            throw TranslatorError.unsupportedPair(source.minimalIdentifier, target.code)
        }
        return try await requestSession(texts: texts, source: source, target: target)
    }

    /// Downloads the language pair (shows the system prompt) without translating anything.
    func download(from source: Locale.Language, to target: SubtitleLanguage) async throws {
        _ = try await requestSession(texts: nil, source: source, target: target)
    }

    static func openTranslationSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Localization-Settings.extension?translation",
            "x-apple.systempreferences:com.apple.Localization-Settings.extension",
        ]
        for s in urls {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }

    private nonisolated func requestSession(texts: [String]?, source: Locale.Language, target: SubtitleLanguage) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                self.pending?.continuation.resume(throwing: CancellationError())
                self.pending = Job(texts: texts, languageName: target.displayName, continuation: continuation)

                let config = TranslationSession.Configuration(source: source, target: target.language)
                if self.configuration == config {
                    self.configuration?.invalidate()
                } else {
                    self.configuration = config
                }

                self.timeout?.cancel()
                self.timeout = Task { @MainActor in
                    try? await Task.sleep(for: Self.sessionTimeout)
                    guard !Task.isCancelled, let job = self.pending else { return }
                    self.pending = nil
                    job.continuation.resume(throwing: TranslationBrokerError.noPrompt(job.languageName))
                }
            }
        }
    }

    /// Called from the view's `translationTask` with a session for `configuration`.
    func perform(_ session: TranslationSession) async {
        guard let job = pending else { return }
        pending = nil
        timeout?.cancel()
        do {
            try await session.prepareTranslation()
            if let texts = job.texts {
                job.continuation.resume(returning: try await Translator.run(session: session, texts: texts))
            } else {
                job.continuation.resume(returning: [])
            }
        } catch {
            job.continuation.resume(throwing: error)
        }
    }
}

/// Attaches `translationTask` to a view and keeps it in sync with the broker.
/// The broker must be observed directly: changes inside a nested ObservableObject
/// don't re-render the parent view, and the task would never fire.
struct TranslationHost: ViewModifier {
    @ObservedObject var broker: TranslationBroker

    func body(content: Content) -> some View {
        content.translationTask(broker.configuration) { session in
            await broker.perform(session)
        }
    }
}
