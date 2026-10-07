import AppKit

/// Sends generated FCPXML back to Final Cut Pro.
enum FinalCutBridge {
    static let bundleIdentifiers = ["com.apple.FinalCutApp", "com.apple.FinalCut", "com.apple.FinalCutTrial"]

    static var applicationURL: URL? {
        if let running = NSWorkspace.shared.runningApplications.first(where: { bundleIdentifiers.contains($0.bundleIdentifier ?? "") }) {
            return running.bundleURL
        }
        return bundleIdentifiers.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    /// Opening an .fcpxml with Final Cut Pro imports it into the library it came from.
    static func importIntoFinalCut(_ url: URL) async throws {
        guard let app = applicationURL else {
            throw NSError(domain: "SubDub", code: 1, userInfo: [NSLocalizedDescriptionKey: "Final Cut Pro was not found."])
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
