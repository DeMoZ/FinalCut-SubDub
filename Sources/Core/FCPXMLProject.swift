import Foundation

enum FCPXMLError: LocalizedError {
    case invalidXML(String)
    case noProject
    case noSpine

    var errorDescription: String? {
        switch self {
        case .invalidXML(let m): return "Couldn't read FCPXML: \(m)"
        case .noProject: return "No project found. Drag a project (not a clip or event) from the Final Cut Pro browser."
        case .noSpine: return "The project timeline is empty."
        }
    }
}

/// A piece of source audio placed on the project timeline.
struct AudioPiece {
    var url: URL
    /// Position in the source file, seconds.
    var sourceStart: Double
    /// Position on the timeline, seconds relative to the sequence start (0 = first frame).
    var timelineStart: Double
    var duration: Double
}

/// A subtitle cue to be placed on the timeline. Times are seconds from the sequence start.
struct CaptionCue {
    var start: Double
    var end: Double
    var text: String
}

/// Wraps an FCPXML document containing one project and knows how to
/// (1) find all audible media on its timeline and (2) add caption lanes to it.
final class FCPXMLProject {
    let document: XMLDocument
    let project: XMLElement
    let sequence: XMLElement
    let spine: XMLElement
    let frameDuration: RationalTime
    let sequenceStart: RationalTime
    let duration: Double

    private let resources: [String: XMLElement]

    /// Number of clips whose audio was skipped because they are retimed (speed changes).
    private(set) var skippedRetimedClips = 0
    private(set) var missingMediaFiles: [String] = []

    var name: String { project.attribute(forName: "name")?.stringValue ?? "Project" }

    convenience init(data: Data) throws {
        let doc: XMLDocument
        do {
            doc = try XMLDocument(data: data, options: [.nodePreserveWhitespace])
        } catch {
            throw FCPXMLError.invalidXML(error.localizedDescription)
        }
        try self.init(document: doc)
    }

    convenience init(url: URL) throws {
        var fileURL = url
        if url.pathExtension.lowercased() == "fcpxmld" {
            fileURL = url.appendingPathComponent("Info.fcpxml")
        }
        try self.init(data: Data(contentsOf: fileURL))
    }

    init(document: XMLDocument) throws {
        self.document = document
        guard let root = document.rootElement() else { throw FCPXMLError.invalidXML("empty document") }
        guard let project = (try? root.nodes(forXPath: ".//project"))?.first as? XMLElement else {
            throw FCPXMLError.noProject
        }
        guard let sequence = project.child("sequence"), let spine = sequence.child("spine") else {
            throw FCPXMLError.noSpine
        }
        self.project = project
        self.sequence = sequence
        self.spine = spine

        var resources: [String: XMLElement] = [:]
        for res in root.child("resources")?.childElements ?? [] {
            if let id = res.attr("id") { resources[id] = res }
        }
        self.resources = resources

        let format = sequence.attr("format").flatMap { resources[$0] }
        frameDuration = RationalTime(fcpxml: format?.attr("frameDuration")) ?? RationalTime(num: 1, den: 25)
        sequenceStart = RationalTime(fcpxml: sequence.attr("tcStart")) ?? .zero
        duration = (RationalTime(fcpxml: sequence.attr("duration")) ?? .zero).seconds
    }

    // MARK: - Audio discovery

    /// Flattens the timeline into a list of audible source-file ranges.
    func audioPieces() -> [AudioPiece] {
        skippedRetimedClips = 0
        missingMediaFiles = []
        var pieces: [AudioPiece] = []
        let all = Window(start: -.infinity, end: .infinity)
        for item in spine.childElements {
            collect(item, shift: -sequenceStart.seconds, window: all, into: &pieces)
        }
        return pieces.filter { $0.duration > 0.01 }.sorted { $0.timelineStart < $1.timelineStart }
    }

    private struct Window {
        var start: Double
        var end: Double
        func intersect(_ s: Double, _ e: Double) -> Window { Window(start: max(start, s), end: min(end, e)) }
    }

    /// - Parameters:
    ///   - shift: maps the parent's local time to timeline time (timeline = parentLocal + shift).
    ///   - window: timeline range in which this element is audible.
    private func collect(_ el: XMLElement, shift: Double, window: Window, into pieces: inout [AudioPiece]) {
        guard el.attr("enabled") != "0" else { return }
        let name = el.name ?? ""
        let offset = el.time("offset") ?? 0
        let start = el.time("start") ?? 0
        let dur = el.time("duration")
        let childShift = shift + offset - start
        let elStart = shift + offset
        let contentWindow = dur.map { window.intersect(elStart, elStart + $0) } ?? window

        if el.child("timeMap") != nil {
            skippedRetimedClips += 1
            return
        }
        if let vol = el.child("adjust-volume")?.attr("amount"), let db = Double(vol.replacingOccurrences(of: "dB", with: "")), db <= -90 {
            return
        }

        func recurseChildren(of container: XMLElement, shift: Double) {
            for child in container.childElements {
                // Anchored items (with a lane) are not clipped by the container's range.
                let w = child.attr("lane") != nil ? window : contentWindow
                collect(child, shift: shift, window: w, into: &pieces)
            }
        }

        switch name {
        case "asset-clip", "audio":
            if el.attr("srcEnable") == "video" { break }
            if let ref = el.attr("ref"), let asset = resources[ref], asset.name == "asset",
               asset.attr("hasAudio") == "1", let url = mediaURL(asset) {
                let aStart = el.time("audioStart") ?? start
                let aDur = el.time("audioDuration") ?? dur ?? 0
                let tlStart = elStart + (aStart - start)
                let w = window.intersect(tlStart, tlStart + aDur)
                if w.end > w.start {
                    let local = w.start - childShift
                    let assetStart = asset.time("start") ?? 0
                    pieces.append(AudioPiece(url: url, sourceStart: local - assetStart,
                                             timelineStart: w.start, duration: w.end - w.start))
                }
            }
            recurseChildren(of: el, shift: childShift)

        case "clip", "sync-clip", "gap", "title", "video":
            recurseChildren(of: el, shift: childShift)

        case "spine":
            // Secondary storyline: children are positioned in the parent's time base.
            // Some writers position them relative to the spine itself; detect that.
            let firstOffset = el.childElements.first?.time("offset") ?? offset
            let spineShift = abs(firstOffset - offset) < 0.001 || offset == 0 ? shift : shift + offset
            for child in el.childElements {
                collect(child, shift: spineShift, window: window, into: &pieces)
            }

        case "ref-clip":
            if el.attr("srcEnable") == "video" { break }
            if let ref = el.attr("ref"), let media = resources[ref], let innerSpine = media.child("sequence")?.child("spine") {
                for child in innerSpine.childElements {
                    collect(child, shift: childShift, window: contentWindow, into: &pieces)
                }
            }
            recurseAnchored(of: el, shift: childShift, window: window, into: &pieces)

        case "mc-clip":
            let audioAngles = Set(el.children("mc-source")
                .filter { ["all", "audio"].contains($0.attr("srcEnable") ?? "all") }
                .compactMap { $0.attr("angleID") })
            if let ref = el.attr("ref"), let multicam = resources[ref]?.child("multicam") {
                for angle in multicam.children("mc-angle") where audioAngles.contains(angle.attr("angleID") ?? "") {
                    for child in angle.childElements {
                        collect(child, shift: childShift, window: contentWindow, into: &pieces)
                    }
                }
            }
            recurseAnchored(of: el, shift: childShift, window: window, into: &pieces)

        case "audition":
            // The first child is the active pick.
            if let active = el.childElements.first {
                collect(active, shift: shift, window: window, into: &pieces)
            }

        default:
            break
        }
    }

    private func recurseAnchored(of el: XMLElement, shift: Double, window: Window, into pieces: inout [AudioPiece]) {
        for child in el.childElements where child.attr("lane") != nil {
            collect(child, shift: shift, window: window, into: &pieces)
        }
    }

    private func mediaURL(_ asset: XMLElement) -> URL? {
        let reps = asset.children("media-rep")
        let rep = reps.first { ($0.attr("kind") ?? "original-media") == "original-media" } ?? reps.first
        guard let src = rep?.attr("src"), let url = URL(string: src) else { return nil }
        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) {
            if !missingMediaFiles.contains(url.lastPathComponent) { missingMediaFiles.append(url.lastPathComponent) }
            return nil
        }
        return url
    }

    // MARK: - Captions

    /// Adds one caption lane per language to the primary storyline.
    /// - Parameter tracks: language code (e.g. "en", "th", "zh-Hans") → cues.
    func addCaptions(_ tracks: [(language: String, cues: [CaptionCue])]) {
        let items = spine.childElements.filter { $0.name != "transition" }
        guard !items.isEmpty else { return }

        var lane = maxAnchoredLane(in: items) + 1
        var styleCounter = 0

        for track in tracks {
            let role = "iTT?captionFormat=ITT.\(track.language)"
            var lastEnd = RationalTime.zero
            for cue in track.cues {
                var tStart = sequenceStart + RationalTime.frameAligned(cue.start, frameDuration: frameDuration)
                let tEnd = sequenceStart + RationalTime.frameAligned(cue.end, frameDuration: frameDuration)
                if tStart < lastEnd { tStart = lastEnd } // captions of one language must not overlap
                guard tStart < tEnd else { continue }
                lastEnd = tEnd

                let parent = items.last { ($0.rational("offset") ?? .zero) <= tStart } ?? items[0]
                let parentOffset = parent.rational("offset") ?? .zero
                let parentStart = parent.rational("start") ?? .zero
                let localStart = parentStart + (tStart - parentOffset)

                let styleID = uniqueID("subdub_ts", counter: &styleCounter)
                let caption = XMLElement(name: "caption")
                caption.setAttributesWith([
                    "lane": "\(lane)",
                    "offset": localStart.fcpxmlString,
                    "name": String(cue.text.replacingOccurrences(of: "\n", with: " ").prefix(40)),
                    "duration": (tEnd - tStart).fcpxmlString,
                    "role": role,
                ])
                let text = XMLElement(name: "text")
                text.addAttribute(XMLNode.attribute(withName: "placement", stringValue: "bottom") as! XMLNode)
                let styled = XMLElement(name: "text-style", stringValue: cue.text)
                styled.addAttribute(XMLNode.attribute(withName: "ref", stringValue: styleID) as! XMLNode)
                text.addChild(styled)
                caption.addChild(text)

                let def = XMLElement(name: "text-style-def")
                def.addAttribute(XMLNode.attribute(withName: "id", stringValue: styleID) as! XMLNode)
                let style = XMLElement(name: "text-style")
                style.setAttributesWith([
                    "font": ".AppleSystemUIFont",
                    "fontSize": "13",
                    "fontFace": "Regular",
                    "fontColor": "1 1 1 1",
                    "backgroundColor": "0 0 0 1",
                ])
                def.addChild(style)
                caption.addChild(def)

                insertAnchored(caption, into: parent)
            }
            lane += 1
        }
    }

    // MARK: - Library

    /// Projects dragged out of Final Cut Pro arrive without a library, so FCP asks where to import.
    /// When the media lives inside a library bundle, point the import at that library and event.
    func assignLibraryFromMedia() {
        guard let root = document.rootElement() else { return }
        if root.child("library")?.attr("location") != nil { return }

        var libraryURL: String?
        var eventName: String?
        for res in resources.values where res.name == "asset" {
            for rep in res.children("media-rep") {
                guard let src = rep.attr("src"), let r = src.range(of: ".fcpbundle/") else { continue }
                libraryURL = String(src[..<r.upperBound])
                let rest = src[r.upperBound...].split(separator: "/").first.map(String.init)
                eventName = rest?.removingPercentEncoding
                break
            }
            if libraryURL != nil { break }
        }
        guard let libraryURL else { return }

        if let library = root.child("library") {
            library.addAttribute(XMLNode.attribute(withName: "location", stringValue: libraryURL) as! XMLNode)
            return
        }
        let library = XMLElement(name: "library")
        library.addAttribute(XMLNode.attribute(withName: "location", stringValue: libraryURL) as! XMLNode)
        let events = root.children("event")
        if !events.isEmpty {
            for e in events { e.detach(); library.addChild(e) }
        } else {
            let event = XMLElement(name: "event")
            event.addAttribute(XMLNode.attribute(withName: "name", stringValue: eventName ?? "SubDub") as! XMLNode)
            for item in root.childElements where !["import-options", "resources"].contains(item.name ?? "") {
                item.detach()
                event.addChild(item)
            }
            library.addChild(event)
        }
        root.addChild(library)
    }

    // MARK: - Voice-over

    enum OriginalAudio {
        case keep
        case duck(dB: Double)
        case mute
    }

    /// Adds one connected audio clip per dub language (lanes below the storyline) and
    /// optionally lowers the original audio while the dub speaks.
    func addVoiceOver(_ tracks: [(name: String, url: URL, frames: Int64, sampleRate: Int64)],
                      original: OriginalAudio, speech: [ClosedRange<Double>]) {
        let items = spine.childElements.filter { $0.name != "transition" }
        guard let anchor = items.first, let resourcesEl = document.rootElement()?.child("resources") else { return }

        let minLane = anchor.childElements.compactMap { $0.attr("lane").flatMap(Int.init) }.min() ?? 0
        let anchorOffset = anchor.rational("offset") ?? .zero
        let anchorStart = anchor.rational("start") ?? .zero
        let localZero = anchorStart + (sequenceStart - anchorOffset)
        let sequenceDuration = RationalTime.frameAligned(duration, frameDuration: frameDuration)

        for (i, track) in tracks.enumerated() {
            var counter = i
            let assetID = uniqueID("subdub_dub", counter: &counter)
            let assetDuration = RationalTime(num: track.frames, den: track.sampleRate)
            let asset = XMLElement(name: "asset")
            asset.setAttributesWith([
                "id": assetID, "name": "Dub \(track.name)", "start": "0s",
                "duration": assetDuration.fcpxmlString, "hasAudio": "1",
                "audioSources": "1", "audioChannels": "1", "audioRate": "\(track.sampleRate)",
            ])
            let rep = XMLElement(name: "media-rep")
            rep.setAttributesWith(["kind": "original-media", "src": track.url.absoluteString])
            asset.addChild(rep)
            resourcesEl.addChild(asset)

            let clip = XMLElement(name: "asset-clip")
            clip.setAttributesWith([
                "ref": assetID,
                "lane": "\(min(minLane, 0) - 1 - i)",
                "offset": localZero.fcpxmlString,
                "name": "Dub \(track.name)",
                "duration": min(sequenceDuration, assetDuration).fcpxmlString,
                "audioRole": "dialogue.Dub \(track.name)",
            ])
            insertAnchored(clip, into: anchor)
        }

        guard !speech.isEmpty else { return }
        switch original {
        case .keep: break
        case .mute: for item in items { setVolume(item, keyframes: nil, constantOffset: -96) }
        case .duck(let dB):
            let merged = Self.merge(speech, gap: 0.6)
            for item in items { duck(item, ranges: merged, dB: dB) }
        }
    }

    private static func merge(_ ranges: [ClosedRange<Double>], gap: Double) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, r.lowerBound - last.upperBound < gap {
                out[out.count - 1] = last.lowerBound ... max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }

    private static let audible: Set<String> = ["asset-clip", "clip", "sync-clip", "mc-clip", "ref-clip", "audio"]

    /// Volume keyframes in the item's local time: fade down before each line, back up after.
    private func duck(_ item: XMLElement, ranges: [ClosedRange<Double>], dB: Double) {
        guard Self.audible.contains(item.name ?? "") else { return }
        let offset = item.rational("offset") ?? .zero
        let start = item.rational("start") ?? .zero
        guard let dur = item.rational("duration") else { return }
        // Timeline seconds (0 = sequence start) of this item.
        let tlStart = (offset - sequenceStart).seconds
        let tlEnd = tlStart + dur.seconds
        let fadeDown = 0.25, fadeUp = 0.4

        var points: [(t: Double, ducked: Bool)] = []
        for r in ranges where r.upperBound + fadeUp > tlStart && r.lowerBound - fadeDown < tlEnd {
            points.append((r.lowerBound - fadeDown, false))
            points.append((r.lowerBound, true))
            points.append((r.upperBound, true))
            points.append((r.upperBound + fadeUp, false))
        }
        guard !points.isEmpty else { return }
        // Clamp to the item's own range; drop points that collapse onto the same time.
        let end = start + dur
        var keyframes: [(RationalTime, Bool)] = []
        for p in points {
            var local = start + (RationalTime.frameAligned(p.t, frameDuration: frameDuration) + sequenceStart - offset)
            if local < start { local = start }
            if end < local { local = end }
            if let last = keyframes.last, last.0 == local { keyframes[keyframes.count - 1] = (local, p.ducked) } else { keyframes.append((local, p.ducked)) }
        }
        setVolume(item, keyframes: keyframes.map { ($0.0, $0.1 ? dB : 0) }, constantOffset: 0)
    }

    /// Sets `adjust-volume` on an item, keeping the user's existing level as the base.
    private func setVolume(_ item: XMLElement, keyframes: [(RationalTime, Double)]?, constantOffset: Double) {
        guard Self.audible.contains(item.name ?? "") else { return }
        let existing = item.child("adjust-volume")
        let base = existing?.attr("amount").flatMap { Double($0.replacingOccurrences(of: "dB", with: "")) } ?? 0
        if existing?.child("param") != nil { return } // user already automated volume: leave it alone

        let volume = existing ?? XMLElement(name: "adjust-volume")
        func db(_ v: Double) -> String { String(format: "%.1fdB", max(-96, base + v)) }

        if let keyframes {
            volume.removeAttribute(forName: "amount")
            let param = XMLElement(name: "param")
            param.setAttributesWith(["name": "amount"])
            let animation = XMLElement(name: "keyframeAnimation")
            for (t, v) in keyframes {
                let k = XMLElement(name: "keyframe")
                k.setAttributesWith(["time": t.fcpxmlString, "value": db(v)])
                animation.addChild(k)
            }
            param.addChild(animation)
            volume.addChild(param)
        } else {
            volume.removeAttribute(forName: "amount")
            volume.addAttribute(XMLNode.attribute(withName: "amount", stringValue: db(constantOffset)) as! XMLNode)
        }
        if existing == nil { insertVolume(volume, into: item) }
    }

    /// `adjust-volume` goes after timing and video adjustments, before `adjust-panner` and anchored items.
    private func insertVolume(_ node: XMLElement, into item: XMLElement) {
        let before: (XMLElement) -> Bool = { el in
            let n = el.name ?? ""
            if ["note", "conform-rate", "timeMap", "object-tracker"].contains(n) { return true }
            return n.hasPrefix("adjust-") && n != "adjust-panner"
        }
        let children = item.children ?? []
        let idx = children.firstIndex { ($0 as? XMLElement).map { !before($0) } ?? false } ?? children.count
        item.insertChild(node, at: idx)
    }

    /// Renames the project and drops its uid so FCP imports it as a new project next to the original.
    func markAsCopy(suffix: String) {
        // Re-processing a SubDub copy: replace its suffix instead of stacking another one.
        var base = name
        while let r = base.range(of: #" — (subtitles|dub|subtitles \+ dub) \([^)]*\)$"#, options: .regularExpression) {
            base.removeSubrange(r)
        }
        project.attribute(forName: "name")?.stringValue = "\(base) \(suffix)"
        project.removeAttribute(forName: "uid")
        project.removeAttribute(forName: "modDate")
    }

    private lazy var usedIDs: Set<String> = {
        let nodes = (try? document.nodes(forXPath: "//@id")) ?? []
        return Set(nodes.compactMap(\.stringValue))
    }()

    /// Next free ID with the prefix: projects that already went through SubDub keep their IDs.
    private func uniqueID(_ prefix: String, counter: inout Int) -> String {
        repeat { counter += 1 } while usedIDs.contains("\(prefix)\(counter)")
        let id = "\(prefix)\(counter)"
        usedIDs.insert(id)
        return id
    }

    func xmlData() -> Data {
        document.isStandalone = false
        document.characterEncoding = "UTF-8"
        return document.xmlData(options: [.nodePrettyPrint, .nodeCompactEmptyElement])
    }

    private func maxAnchoredLane(in items: [XMLElement]) -> Int {
        var maxLane = 0
        for item in items {
            for child in item.childElements {
                if let l = child.attr("lane").flatMap(Int.init) { maxLane = max(maxLane, l) }
            }
        }
        return maxLane
    }

    /// Children that must come after anchored items according to the FCPXML DTD.
    private static let afterAnchored: Set<String> = [
        "marker", "chapter-marker", "rating", "keyword", "analysis-marker", "hidden-clip-marker",
        "audio-channel-source", "audio-role-source", "sync-source",
        "filter-video", "filter-video-mask", "filter-audio", "metadata", "reserved",
    ]

    private func insertAnchored(_ node: XMLElement, into parent: XMLElement) {
        let children = parent.children ?? []
        if let idx = children.firstIndex(where: { ($0 as? XMLElement).map { Self.afterAnchored.contains($0.name ?? "") } ?? false }) {
            parent.insertChild(node, at: idx)
        } else {
            parent.addChild(node)
        }
    }
}

// MARK: - XMLElement helpers

extension XMLElement {
    var childElements: [XMLElement] { (children ?? []).compactMap { $0 as? XMLElement } }
    func child(_ name: String) -> XMLElement? { childElements.first { $0.name == name } }
    func children(_ name: String) -> [XMLElement] { childElements.filter { $0.name == name } }
    func attr(_ name: String) -> String? { attribute(forName: name)?.stringValue }
    func rational(_ name: String) -> RationalTime? { RationalTime(fcpxml: attr(name)) }
    func time(_ name: String) -> Double? { rational(name)?.seconds }

    func setAttributesWith(_ dict: [String: String]) {
        // Stable attribute order makes the output easier to diff.
        for key in dict.keys.sorted(by: { Self.attrOrder($0) < Self.attrOrder($1) }) {
            addAttribute(XMLNode.attribute(withName: key, stringValue: dict[key]!) as! XMLNode)
        }
    }

    private static func attrOrder(_ key: String) -> Int {
        ["id", "ref", "kind", "lane", "offset", "name", "start", "duration", "role", "audioRole", "hasAudio", "audioSources", "audioChannels", "audioRate", "src", "time", "value", "font", "fontSize", "fontFace", "fontColor", "backgroundColor"]
            .firstIndex(of: key) ?? 99
    }
}
