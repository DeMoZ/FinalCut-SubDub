import Foundation

/// FCPXML time value: a rational number of seconds, e.g. "1001/30000s" or "5s".
struct RationalTime: Comparable, Hashable, CustomStringConvertible {
    var num: Int64
    var den: Int64

    static let zero = RationalTime(num: 0, den: 1)

    init(num: Int64, den: Int64) {
        precondition(den != 0)
        let sign: Int64 = den < 0 ? -1 : 1
        let g = Swift.max(RationalTime.gcd(Swift.abs(num), Swift.abs(den)), 1)
        self.num = sign * num / g
        self.den = sign * den / g
    }

    /// Parses "1001/30000s", "5s", "0s". Returns nil for malformed values.
    init?(fcpxml string: String?) {
        guard var s = string?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasSuffix("s") { s.removeLast() }
        let parts = s.split(separator: "/")
        if parts.count == 1, let n = Int64(parts[0]) {
            self.init(num: n, den: 1)
        } else if parts.count == 2, let n = Int64(parts[0]), let d = Int64(parts[1]), d != 0 {
            self.init(num: n, den: d)
        } else {
            return nil
        }
    }

    var seconds: Double { Double(num) / Double(den) }

    var fcpxmlString: String { den == 1 ? "\(num)s" : "\(num)/\(den)s" }

    var description: String { fcpxmlString }

    /// Nearest frame boundary for `seconds` with the given frame duration.
    static func frameAligned(_ seconds: Double, frameDuration fd: RationalTime) -> RationalTime {
        let frames = (seconds / fd.seconds).rounded()
        return RationalTime(num: Int64(frames) * fd.num, den: fd.den)
    }

    static func + (a: RationalTime, b: RationalTime) -> RationalTime {
        let l = lcm(a.den, b.den)
        return RationalTime(num: a.num * (l / a.den) + b.num * (l / b.den), den: l)
    }

    static func - (a: RationalTime, b: RationalTime) -> RationalTime {
        a + RationalTime(num: -b.num, den: b.den)
    }

    static func < (a: RationalTime, b: RationalTime) -> Bool {
        let l = lcm(a.den, b.den)
        return a.num * (l / a.den) < b.num * (l / b.den)
    }

    private static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var (a, b) = (a, b)
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    private static func lcm(_ a: Int64, _ b: Int64) -> Int64 {
        a / gcd(a, b) * b
    }
}
