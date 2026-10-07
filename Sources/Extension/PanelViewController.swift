import AppKit
import SwiftUI

/// Principal view controller of the Final Cut Pro workflow extension.
/// ProExtensionMain instantiates it by the name in Info.plist (ProExtensionPrincipalViewControllerClass).
@objc(PanelViewController)
final class PanelViewController: NSViewController {
    override func loadView() {
        let hosting = NSHostingView(rootView: PanelView())
        hosting.frame = NSRect(x: 0, y: 0, width: 380, height: 620)
        view = hosting
        preferredContentSize = hosting.frame.size
    }
}
