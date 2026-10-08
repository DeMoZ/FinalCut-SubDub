import Foundation

/// Projects opened with the SubDub app (from the Final Cut Pro panel's "Open in App",
/// or an .fcpxml opened from Finder). The panel view picks them up.
@MainActor
final class ProjectInbox: ObservableObject {
    static let shared = ProjectInbox()
    @Published var url: URL?
}
