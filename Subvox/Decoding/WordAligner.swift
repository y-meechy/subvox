import Foundation

/// One word recognized from the microphone, placed on the same clock as `MotionSample.t`
/// (seconds since boot).
struct TimedWord: Hashable, Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval

    var duration: TimeInterval { end - start }
}

/// Turns "I said this word between t0 and t1" into a labelled motion segment.
/// This is what lets reading a passage out loud produce training data without
/// holding Space for every word.
enum WordAligner {
    /// Lowercased, letters/digits/apostrophes only, so "Next," and "next" are the same label.
    static func normalize(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let kept = lowered.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "'" || $0 == "’"
        }
        return String(String.UnicodeScalarView(kept))
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
    }

    /// Every distinct normalized word in a passage, in first-seen order.
    static func words(in text: String) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for token in text.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "—" }) {
            let word = normalize(String(token))
            guard !word.isEmpty, seen.insert(word).inserted else { continue }
            ordered.append(word)
        }
        return ordered
    }

    /// Motion samples covering `word`, widened by `padding` on both sides and shifted by
    /// `offset` (positive = motion arrives later than audio). Returns nil when the slice is
    /// too short to be a usable template.
    static func slice(_ samples: [MotionSample], for word: TimedWord,
                      padding: TimeInterval = 0.12, offset: TimeInterval = 0,
                      minDuration: TimeInterval = 0.15, minSamples: Int = 5) -> [MotionSample]? {
        let lo = word.start - padding + offset
        let hi = word.end + padding + offset
        let slice = samples.filter { $0.t >= lo && $0.t <= hi }
        guard slice.count >= minSamples,
              let first = slice.first, let last = slice.last,
              last.t - first.t >= minDuration else { return nil }
        return slice
    }
}

/// Keeps the last few seconds of motion so words can be cut out after the recognizer
/// finalizes them (which happens a second or more after they were spoken).
struct MotionHistory {
    var seconds: TimeInterval = 90
    private(set) var samples: [MotionSample] = []

    mutating func append(_ sample: MotionSample) {
        samples.append(sample)
        // Trim in chunks so we don't shift the array on every sample.
        if let first = samples.first, sample.t - first.t > seconds * 1.25 {
            let cutoff = sample.t - seconds
            samples.removeAll { $0.t < cutoff }
        }
    }

    mutating func removeAll() { samples.removeAll() }
}
