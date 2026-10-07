import AVFoundation

enum AudioMixdownError: LocalizedError {
    case noAudio
    case readerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudio: return "No audio found on the timeline (or media files are offline)."
        case .readerFailed(let m): return "Audio read error: \(m)"
        }
    }
}

/// Mixes every audible piece of the timeline into a single mono file that matches
/// the project timeline 1:1 (file time 0 = first frame of the sequence).
enum AudioMixdown {
    static let sampleRate: Double = 16_000

    static func render(pieces: [AudioPiece], totalDuration: Double, to outputURL: URL,
                       progress: @escaping (Double) -> Void) async throws {
        let composition = AVMutableComposition()
        var lanes: [(track: AVMutableCompositionTrack, end: Double)] = []
        var assets: [URL: AVURLAsset] = [:]
        var inserted = 0

        for piece in pieces {
            let asset = assets[piece.url] ?? AVURLAsset(url: piece.url)
            assets[piece.url] = asset
            guard let sourceTracks = try? await asset.loadTracks(withMediaType: .audio), !sourceTracks.isEmpty else { continue }
            let assetDuration = (try? await asset.load(.duration))?.seconds ?? .infinity

            let srcStart = max(0, piece.sourceStart)
            let dur = min(piece.duration - (srcStart - piece.sourceStart), assetDuration - srcStart)
            guard dur > 0.01 else { continue }
            let range = CMTimeRange(start: CMTime(seconds: srcStart, preferredTimescale: 48_000),
                                    duration: CMTime(seconds: dur, preferredTimescale: 48_000))
            let at = piece.timelineStart + (srcStart - piece.sourceStart)

            for src in sourceTracks {
                // Composition tracks can't overlap themselves: reuse a lane that is free at `at`.
                let laneIndex: Int
                if let free = lanes.firstIndex(where: { $0.end <= at + 0.0001 }) {
                    laneIndex = free
                } else {
                    guard let t = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                    lanes.append((t, 0))
                    laneIndex = lanes.count - 1
                }
                do {
                    try lanes[laneIndex].track.insertTimeRange(range, of: src, at: CMTime(seconds: at, preferredTimescale: 48_000))
                    lanes[laneIndex].end = at + dur
                    inserted += 1
                } catch {
                    continue
                }
            }
        }
        guard inserted > 0 else { throw AudioMixdownError.noAudio }

        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: lanes.map(\.track), audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw AudioMixdownError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        try? FileManager.default.removeItem(at: outputURL)
        let file = try AVAudioFile(forWriting: outputURL, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)

        var writtenFrames: AVAudioFramePosition = 0
        let totalFrames = AVAudioFramePosition(totalDuration * sampleRate)

        func writeSilence(_ count: AVAudioFramePosition) throws {
            var remaining = count
            while remaining > 0 {
                let n = AVAudioFrameCount(min(remaining, 65_536))
                let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
                buf.frameLength = n
                memset(buf.floatChannelData![0], 0, Int(n) * MemoryLayout<Float>.size)
                try file.write(from: buf)
                remaining -= AVAudioFramePosition(n)
            }
            writtenFrames += count
        }

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let expected = AVAudioFramePosition(pts * sampleRate)
            if expected > writtenFrames + 1 { try writeSilence(expected - writtenFrames) }

            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { continue }
            buf.frameLength = AVAudioFrameCount(frames)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList)
            guard status == noErr else { continue }
            try file.write(from: buf)
            writtenFrames += AVAudioFramePosition(frames)
            if totalFrames > 0 { progress(min(1, Double(writtenFrames) / Double(totalFrames))) }
        }
        if reader.status == .failed {
            throw AudioMixdownError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }
        if totalFrames > writtenFrames { try writeSilence(totalFrames - writtenFrames) }
        progress(1)
    }
}
