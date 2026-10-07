import SwiftUI

/// Companion app: hosts the Final Cut Pro extension and also works standalone with exported .fcpxml files.
@main
struct SubDubApp: App {
    var body: some Scene {
        WindowGroup("SubDub") {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Panel inside Final Cut Pro").font(.headline)
                    Text("In Final Cut Pro choose Window ▸ Extensions ▸ SubDub. If it isn't listed, restart Final Cut Pro.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("You can also use it here: drop a project from Final Cut Pro or an exported .fcpxml file.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5))
                Divider()
                PanelView()
            }
            .frame(minWidth: 400, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
    }
}
