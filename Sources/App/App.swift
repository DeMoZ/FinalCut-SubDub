import SwiftUI

/// Companion app: hosts the Final Cut Pro extension, and runs the full panel standalone —
/// including Siri voices, which the sandboxed panel inside Final Cut Pro can't use.
@main
struct SubDubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("SubDub", id: "main") {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SubDub").font(.headline)
                    Text("In Final Cut Pro: Window ▸ Extensions ▸ SubDub, then Open in App to use Siri voices. You can also drop a project from Final Cut Pro or an .fcpxml file below.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5))
                Divider()
                PanelView()
            }
            .frame(minWidth: 420, minHeight: 680)
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { ["fcpxml", "fcpxmld"].contains($0.pathExtension.lowercased()) }) else { return }
        Task { @MainActor in
            ProjectInbox.shared.url = url
            NSApp.activate()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
