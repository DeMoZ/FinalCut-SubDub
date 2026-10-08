// Re-voices a SubDub dub track with a Siri voice.
//
// macOS only exposes Siri voices to Apple-signed processes, so SubDub itself can't use them.
// Run through the Swift interpreter (`swift siri-revoice.swift …`, needs Xcode): it is Apple-signed
// and sees the Siri voices downloaded in System Settings ▸ Accessibility ▸ Read & Speak.
//
// usage: swift siri-revoice.swift <SubDub output folder> <language> <Male|Female|voice-id>
//        swift siri-revoice.swift --list
import AVFoundation

let sampleRate = 48_000.0
let maxSpeedUp = 1.35

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func siriVoices() -> [AVSpeechSynthesisVoice] {
    AVSpeechSynthesisVoice.speechVoices().filter { $0.identifier.contains("gryphon") || $0.identifier.contains(".siri.") }
}

let args = CommandLine.arguments.dropFirst()
if args.first == "--list" || args.isEmpty {
    print("Siri voices available to this tool:")
    for v in siriVoices() {
        let g = v.gender == .male ? "Male" : v.gender == .female ? "Female" : "-"
        print("  \(v.language)\t\(g)\t\(v.name)\t\(v.identifier)")
    }
    if args.isEmpty { print("\nusage: siri-revoice <SubDub output folder> <language> <Male|Female|voice-id>") }
    exit(0)
}
guard args.count >= 3 else { fail("usage: siri-revoice <SubDub output folder> <language> <Male|Female|voice-id>") }
let folder = URL(fileURLWithPath: args[args.startIndex])
let language = args[args.startIndex + 1]
let voiceArg = args[args.startIndex + 2]

// MARK: Voice

let wanted = Locale.Language(identifier: language)
let candidates = siriVoices().filter { Locale.Language(identifier: $0.language).languageCode == wanted.languageCode }
let voice: AVSpeechSynthesisVoice
if let v = AVSpeechSynthesisVoice(identifier: voiceArg) {
    voice = v
} else {
    let gender: AVSpeechSynthesisVoiceGender = voiceArg.lowercased() == "male" ? .male : .female
    guard let v = candidates.first(where: { $0.gender == gender }) ?? candidates.first else {
        fail("no Siri voice for \(language). Download one in System Settings ▸ Accessibility ▸ Read & Speak, then run --list.")
    }
    if v.gender != gender { print("note: no \(voiceArg.lowercased()) Siri voice for \(language), using \(v.name)") }
    voice = v
}
print("voice: \(voice.name) (\(voice.identifier))")

// MARK: Cues from the SRT SubDub wrote

struct Cue { var start: Double; var end: Double; var text: String }

func parseTime(_ s: Substring) -> Double {
    let p = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
    guard p.count == 3, let h = Double(p[0]), let m = Double(p[1]), let sec = Double(p[2]) else { return 0 }
    return h * 3600 + m * 60 + sec
}

let srtURL = folder.appendingPathComponent("\(language).srt")
guard let srt = try? String(contentsOf: srtURL, encoding: .utf8) else {
    fail("\(srtURL.lastPathComponent) not found in \(folder.path). Run SubDub with \(language) selected first.")
}
var cues: [Cue] = []
for block in srt.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n\n") {
    let lines = block.split(separator: "\n", omittingEmptySubsequences: true)
    guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
    let times = lines[timeIndex].components(separatedBy: "-->")
    // SubDub wraps long lines; scripts without spaces between words (Thai, Chinese, …) join without one.
    let noSpaces = ["th", "zh", "ja", "lo", "km", "my"].contains(String(language.prefix(2)))
    let text = lines[(timeIndex + 1)...].joined(separator: noSpaces ? "" : " ")
    guard times.count == 2, !text.isEmpty else { continue }
    cues.append(Cue(start: parseTime(Substring(times[0])), end: parseTime(Substring(times[1])), text: text))
}
guard !cues.isEmpty else { fail("no cues in \(srtURL.lastPathComponent)") }

// MARK: Synthesis

let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
let synthesizer = AVSpeechSynthesizer()

func speak(_ text: String, rate: Float) -> AVAudioPCMBuffer {
    let u = AVSpeechUtterance(string: text)
    u.voice = voice
    u.rate = rate
    u.preUtteranceDelay = 0
    u.postUtteranceDelay = 0
    var pieces: [AVAudioPCMBuffer] = []
    var done = false
    synthesizer.write(u) { buffer in
        guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { done = true; return }
        pieces.append(pcm)
    }
    while !done { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    return trimSilence(convert(pieces))
}

func convert(_ pieces: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer {
    guard let first = pieces.first, let converter = AVAudioConverter(from: first.format, to: format) else {
        return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
    }
    let frames = pieces.reduce(0) { $0 + Int($1.frameLength) }
    let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(frames) * sampleRate / first.format.sampleRate) + 4096)!
    var index = 0
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
        guard index < pieces.count else { status.pointee = .endOfStream; return nil }
        status.pointee = .haveData
        defer { index += 1 }
        return pieces[index]
    }
    return out
}

func trimSilence(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
    guard let d = b.floatChannelData?[0], b.frameLength > 0 else { return b }
    let n = Int(b.frameLength), pad = Int(sampleRate * 0.02)
    var s = 0, e = n
    while s < n && abs(d[s]) < 0.003 { s += 1 }
    while e > s && abs(d[e - 1]) < 0.003 { e -= 1 }
    s = max(0, s - pad); e = min(n, e + pad)
    guard e > s else { return b }
    let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(e - s))!
    out.frameLength = AVAudioFrameCount(e - s)
    memcpy(out.floatChannelData![0], d + s, (e - s) * MemoryLayout<Float>.size)
    return out
}

func duration(_ b: AVAudioPCMBuffer) -> Double { Double(b.frameLength) / sampleRate }

// MARK: Render, keeping the original file's length so it stays in sync on the timeline

let output = folder.appendingPathComponent("dub-\(language).wav")
let backup = folder.appendingPathComponent("dub-\(language).apple.wav")
var totalFrames = AVAudioFramePosition((cues.last!.end + 1) * sampleRate)
if let existing = try? AVAudioFile(forReading: output) {
    totalFrames = AVAudioFramePosition(Double(existing.length) * sampleRate / existing.fileFormat.sampleRate)
    if !FileManager.default.fileExists(atPath: backup.path) {
        try? FileManager.default.copyItem(at: output, to: backup)
        print("original Apple-voice dub kept as \(backup.lastPathComponent)")
    }
}

let temp = folder.appendingPathComponent(".dub-\(language).siri.tmp.wav")
try? FileManager.default.removeItem(at: temp)
let file = try! AVAudioFile(forWriting: temp, settings: [
    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
], commonFormat: .pcmFormatFloat32, interleaved: false)

func writeSilence(_ frames: AVAudioFramePosition) {
    var left = frames
    while left > 0 {
        let n = AVAudioFrameCount(min(left, 65_536))
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
        b.frameLength = n
        memset(b.floatChannelData![0], 0, Int(n) * MemoryLayout<Float>.size)
        try! file.write(from: b)
        left -= AVAudioFramePosition(n)
    }
}

var written: AVAudioFramePosition = 0
for (i, cue) in cues.enumerated() {
    let slotEnd = i + 1 < cues.count ? cues[i + 1].start : max(cue.end, Double(totalFrames) / sampleRate)
    // Measure the slot from where this line can actually start, so lines catch up after an overrun.
    let actualStart = max(cue.start, Double(written) / sampleRate)
    let slot = max(0.3, slotEnd - actualStart)
    // The last line has nothing after it to spill into: allow a bit more speed-up there.
    let limit = i + 1 < cues.count ? maxSpeedUp : 1.6
    var speech = speak(cue.text, rate: AVSpeechUtteranceDefaultSpeechRate)
    if duration(speech) > slot * 1.02 {
        // Binary-search the slowest rate whose measured length fits: `rate` maps to speed differently per voice.
        let target = max(slot, duration(speech) / limit)
        var lo = AVSpeechUtteranceDefaultSpeechRate, hi = Float(0.85)
        var best = speech
        for _ in 0..<5 {
            let mid = (lo + hi) / 2
            let attempt = speak(cue.text, rate: mid)
            if duration(attempt) > target * 1.02 {
                lo = mid
                if duration(attempt) < duration(best) { best = attempt }
            } else {
                hi = mid
                best = attempt
            }
        }
        speech = best
    }
    let start = max(AVAudioFramePosition(cue.start * sampleRate), written)
    if start > written { writeSilence(start - written) }
    try! file.write(from: speech)
    written = start + AVAudioFramePosition(speech.frameLength)
    print("  \(i + 1)/\(cues.count)  \(String(format: "%.1f", Double(start) / sampleRate)) s  \(cue.text.prefix(40))")
}
if totalFrames > written { writeSilence(totalFrames - written) }
if Double(written - totalFrames) / sampleRate > 0.05 { print("note: the Siri dub runs \(String(format: "%.1f", Double(written - totalFrames) / sampleRate)) s past the original end") }

file.close() // finalizes the WAV header
try? FileManager.default.removeItem(at: output)
try! FileManager.default.moveItem(at: temp, to: output)
print("✓ \(output.path)")
