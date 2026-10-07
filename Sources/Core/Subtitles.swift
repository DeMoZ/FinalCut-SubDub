import Foundation
import NaturalLanguage

/// Groups recognised words into readable subtitle cues.
enum Segmenter {
    static let maxCharsPerLine = 42
    static let maxLines = 2
    static let maxDuration = 6.0
    static let minDuration = 1.0
    static let pauseBreak = 0.8

    static func cues(from rawWords: [TimedWord], language: String?) -> [CaptionCue] {
        let words = punctuateIfNeeded(explode(rawWords), language: language)
        var cues: [CaptionCue] = []
        var current: [TimedWord] = []

        let separator = language.map { LineWrapper.noSpaceLanguages.contains(String($0.prefix(2))) } == true ? "" : " "

        func emit(_ group: ArraySlice<TimedWord>) {
            guard let first = group.first, let last = group.last else { return }
            let text = group.map(\.text).joined(separator: separator)
            cues.append(CaptionCue(start: first.start, end: max(last.end, first.start + 0.3), text: text))
        }

        func flush() {
            emit(current[...])
            current = []
        }

        /// The cue is full mid-phrase: cut at the longest pause in its second part
        /// (later cut wins ties) and carry the rest over into the next cue.
        func splitAtBestPause() {
            guard current.count >= 3 else { return flush() }
            var best = current.count
            var bestGap = -Double.infinity
            for k in max(1, current.count / 3)..<current.count {
                let gap = current[k].start - current[k - 1].end
                if gap >= bestGap { bestGap = gap; best = k }
            }
            emit(current[..<best])
            current = Array(current[best...])
        }

        let lineLimit = LineWrapper.lineLimit(for: language)
        let maxChars = lineLimit * maxLines
        for word in words {
            if let last = current.last {
                let length = current.reduce(0) { $0 + $1.text.count + 1 } + word.text.count
                let gap = word.start - last.end
                let lastText = last.text
                let sentenceEnd = lastText.last.map { ".?!…。？！".contains($0) } ?? false
                let clauseEnd = lastText.last.map { ",;:—，、".contains($0) } ?? false
                let curLen = length - word.text.count

                if gap > pauseBreak || (sentenceEnd && curLen >= 15) || (clauseEnd && curLen >= lineLimit) {
                    flush()
                } else if length > maxChars || word.end - current[0].start > maxDuration {
                    splitAtBestPause()
                }
            }
            current.append(word)
        }
        flush()

        // Give short cues enough reading time without overlapping the next one.
        for i in cues.indices {
            let nextStart = i + 1 < cues.count ? cues[i + 1].start : .infinity
            if cues[i].end - cues[i].start < minDuration {
                cues[i].end = min(cues[i].start + minDuration, nextStart)
            }
            // Close tiny gaps so captions don't flicker.
            if nextStart - cues[i].end < 0.25 && nextStart > cues[i].end { cues[i].end = nextStart }
            cues[i].end = min(cues[i].end, nextStart)
        }
        return cues.map { CaptionCue(start: $0.start, end: $0.end, text: LineWrapper.wrap($0.text, language: language)) }
    }

    /// Some on-device models (e.g. Russian dictation) return no punctuation at all.
    /// In that case end sentences at long pauses so cues and translations read naturally.
    static let sentencePause = 0.45

    private static func punctuateIfNeeded(_ words: [TimedWord], language: String?) -> [TimedWord] {
        let terminators: Set<Character> = [".", "?", "!", "…", "。", "？", "！"]
        guard words.count > 3, !words.contains(where: { $0.text.last.map(terminators.contains) ?? false }) else { return words }
        if let l = language, LineWrapper.noSpaceLanguages.contains(String(l.prefix(2))) { return words }

        var out = words
        var capitalizeNext = true
        for i in out.indices {
            if capitalizeNext, let first = out[i].text.first, first.isLowercase {
                out[i].text = first.uppercased() + out[i].text.dropFirst()
            }
            let isLast = i == out.count - 1
            capitalizeNext = isLast || out[i + 1].start - out[i].end >= sentencePause
            if capitalizeNext, let last = out[i].text.last, last.isLetter || last.isNumber {
                out[i].text += "."
            }
        }
        return out
    }

    /// Tokens that contain several words get split with interpolated timing.
    private static func explode(_ words: [TimedWord]) -> [TimedWord] {
        words.flatMap { w -> [TimedWord] in
            let parts = w.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count > 1 else { return [w] }
            let total = Double(parts.reduce(0) { $0 + $1.count })
            var t = w.start
            return parts.map { p in
                let d = (w.end - w.start) * Double(p.count) / total
                defer { t += d }
                return TimedWord(text: p, start: t, end: t + d)
            }
        }
    }
}

/// Breaks subtitle text into at most two balanced lines.
enum LineWrapper {
    /// Languages written without spaces between words.
    static let noSpaceLanguages: Set<String> = ["th", "zh", "ja", "lo", "km", "my"]

    static func lineLimit(for language: String?) -> Int {
        switch language?.prefix(2) {
        case "zh", "ja": return 18
        case "ko": return 24
        case "th": return 35
        default: return Segmenter.maxCharsPerLine
        }
    }

    static func wrap(_ text: String, language: String?) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let limit = lineLimit(for: language)
        guard flat.count > limit else { return flat }

        let noSpaces = language.map { noSpaceLanguages.contains(String($0.prefix(2))) } ?? false
        let tokens = noSpaces ? wordUnits(flat, language: language!) : flat.split(separator: " ").map { String($0) + " " }

        // Find the split point that balances both lines best.
        var best = (score: Int.max, index: tokens.count / 2)
        var left = 0
        let total = tokens.reduce(0) { $0 + $1.count }
        for i in 1..<max(tokens.count, 2) where i < tokens.count {
            left += tokens[i - 1].count
            let score = abs(total - 2 * left)
            if score < best.score { best = (score, i) }
        }
        let line1 = tokens[..<best.index].joined().trimmingCharacters(in: .whitespaces)
        let line2 = tokens[best.index...].joined().trimmingCharacters(in: .whitespaces)
        return line2.isEmpty ? line1 : "\(line1)\n\(line2)"
    }

    /// Word units for scripts without spaces, keeping the original characters (including spaces).
    private static func wordUnits(_ text: String, language: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(NLLanguage(rawValue: String(language.prefix(2))))
        var units: [String] = []
        var cursor = text.startIndex
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            // Attach any skipped characters (spaces, punctuation) to the previous unit.
            if cursor < range.lowerBound {
                let gap = String(text[cursor..<range.lowerBound])
                if units.isEmpty { units.append(gap) } else { units[units.count - 1] += gap }
            }
            units.append(String(text[range]))
            cursor = range.upperBound
            return true
        }
        if cursor < text.endIndex {
            let tail = String(text[cursor...])
            if units.isEmpty { units.append(tail) } else { units[units.count - 1] += tail }
        }
        return units
    }
}

enum SRTWriter {
    static func srt(_ cues: [CaptionCue]) -> String {
        var out = ""
        for (i, cue) in cues.enumerated() {
            out += "\(i + 1)\n\(stamp(cue.start)) --> \(stamp(cue.end))\n\(cue.text)\n\n"
        }
        return out
    }

    private static func stamp(_ t: Double) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }
}
