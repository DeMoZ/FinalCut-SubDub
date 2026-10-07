import AppKit
import SwiftUI

/// Accepts a project dragged from the Final Cut Pro browser (FCPXML on the pasteboard)
/// or an exported .fcpxml / .fcpxmld file from Finder.
struct FCPXMLDropTarget: NSViewRepresentable {
    var isTargeted: Binding<Bool>
    var onDrop: (Data) -> Void

    func makeNSView(context: Context) -> DropView {
        let view = DropView()
        view.onDrop = onDrop
        view.onTargetChange = { isTargeted.wrappedValue = $0 }
        return view
    }

    func updateNSView(_ view: DropView, context: Context) {
        view.onDrop = onDrop
        view.onTargetChange = { isTargeted.wrappedValue = $0 }
    }

    final class DropView: NSView {
        var onDrop: ((Data) -> Void)?
        var onTargetChange: ((Bool) -> Void)?

        /// Newest first: FCP hands over the newest FCPXML version the receiver accepts.
        static let fcpxmlTypes: [NSPasteboard.PasteboardType] =
            (8...14).reversed().map { NSPasteboard.PasteboardType("com.apple.finalcutpro.xml.v1-\($0)") }
            + [NSPasteboard.PasteboardType("com.apple.finalcutpro.xml")]

        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes(Self.fcpxmlTypes + [.fileURL])
        }

        required init?(coder: NSCoder) { fatalError() }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard canAccept(sender.draggingPasteboard) else { return [] }
            onTargetChange?(true)
            return .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            onTargetChange?(false)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            onTargetChange?(false)
            guard let data = Self.readFCPXML(from: sender.draggingPasteboard) else { return false }
            onDrop?(data)
            return true
        }

        private func canAccept(_ pb: NSPasteboard) -> Bool {
            if pb.types?.contains(where: { $0.rawValue.contains("finalcutpro.xml") }) == true { return true }
            return Self.fileURLs(pb).contains { ["fcpxml", "fcpxmld"].contains($0.pathExtension.lowercased()) }
        }

        static func readFCPXML(from pb: NSPasteboard) -> Data? {
            for type in fcpxmlTypes + (pb.types ?? []).filter({ $0.rawValue.contains("finalcutpro.xml") }) {
                if let data = pb.data(forType: type) { return data }
                if let string = pb.string(forType: type) { return Data(string.utf8) }
            }
            for url in fileURLs(pb) {
                switch url.pathExtension.lowercased() {
                case "fcpxml": return try? Data(contentsOf: url)
                case "fcpxmld": return try? Data(contentsOf: url.appendingPathComponent("Info.fcpxml"))
                default: continue
                }
            }
            return nil
        }

        private static func fileURLs(_ pb: NSPasteboard) -> [URL] {
            (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        }
    }
}
