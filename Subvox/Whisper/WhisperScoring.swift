import Foundation

/// Word error rate: (substitutions + deletions + insertions) / reference words.
/// Case and punctuation are ignored, so "Next, please." matches "next please".
enum WordErrorRate {
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "—" })
            .map { WordAligner.normalize(String($0)) }
            .filter { !$0.isEmpty }
    }

    static func compute(reference: String, hypothesis: String) -> Double {
        let ref = words(reference)
        let hyp = words(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        // Levenshtein distance over words, one row at a time.
        var previous = Array(0...hyp.count)
        for i in 1...ref.count {
            var current = [i] + [Int](repeating: 0, count: hyp.count)
            for j in stride(from: 1, through: hyp.count, by: 1) {
                let cost = ref[i - 1] == hyp[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return Double(previous[hyp.count]) / Double(ref.count)
    }

    /// 0…1, the share of the sentence that came through (1 − WER, floored at 0).
    static func accuracy(reference: String, hypothesis: String) -> Double {
        max(0, 1 - compute(reference: reference, hypothesis: hypothesis))
    }
}

/// How loud a take was. Works on 20 ms frames: the loud end (90th percentile) is your
/// whisper, the quiet end (10th percentile) is the room, and the gap is what the
/// recognizer has to work with.
struct LoudnessStats: Hashable, Sendable {
    /// dBFS of the loudest 10% of frames: how loud the whisper itself was.
    var speechDB: Double
    /// dBFS of the quietest 10% of frames: background noise in the take.
    var noiseDB: Double

    var signalToNoise: Double { speechDB - noiseDB }

    static let silenceDB = -100.0

    static func measure(_ samples: [Float], sampleRate: Double, frameSeconds: Double = 0.02) -> LoudnessStats {
        let frame = max(1, Int(sampleRate * frameSeconds))
        guard samples.count >= frame else {
            let db = decibels(samples[...])
            return LoudnessStats(speechDB: db, noiseDB: db)
        }
        var levels: [Double] = []
        levels.reserveCapacity(samples.count / frame)
        var start = 0
        while start + frame <= samples.count {
            levels.append(decibels(samples[start..<(start + frame)]))
            start += frame
        }
        levels.sort()
        let p = { (q: Double) in levels[min(levels.count - 1, Int(Double(levels.count - 1) * q))] }
        return LoudnessStats(speechDB: p(0.9), noiseDB: p(0.1))
    }

    static func decibels(_ frame: ArraySlice<Float>) -> Double {
        guard !frame.isEmpty else { return silenceDB }
        var sum: Double = 0
        for s in frame { sum += Double(s) * Double(s) }
        let rms = (sum / Double(frame.count)).squareRoot()
        return max(silenceDB, 20 * log10(max(rms, 1e-10)))
    }
}

/// Practice sentences: everyday dictation, a mix of short and long words.
enum WhisperSentences {
    enum Language: String, CaseIterable, Identifiable {
        case english = "English"
        case german = "Deutsch"
        var id: String { rawValue }
        var localeIdentifier: String { self == .english ? "en-US" : "de-DE" }
    }

    static func all(_ language: Language) -> [String] {
        switch language {
        case .english: english
        case .german: german
        }
    }

    static let english = [
        "Remind me to call my sister tomorrow after work.",
        "Can you send the file to Martin before lunch?",
        "I'll be about ten minutes late, sorry.",
        "Add oat milk, bread and two lemons to the shopping list.",
        "The meeting moved to Thursday at three.",
        "Please turn the music down a little.",
        "What's the weather going to be like this weekend?",
        "I think we should take the train instead of driving.",
        "Thanks for your help, that was really useful.",
        "Set a timer for twenty minutes.",
        "Let's meet at the café on the corner at noon.",
        "Could you reply that I agree with the plan?",
    ]

    static let german = [
        "Erinnere mich morgen nach der Arbeit, meine Schwester anzurufen.",
        "Kannst du Martin die Datei vor dem Mittagessen schicken?",
        "Ich komme ungefähr zehn Minuten später, sorry.",
        "Setz Hafermilch, Brot und zwei Zitronen auf die Einkaufsliste.",
        "Das Meeting ist auf Donnerstag um drei verschoben.",
        "Mach die Musik bitte etwas leiser.",
        "Wie wird das Wetter am Wochenende?",
        "Ich finde, wir sollten lieber mit dem Zug fahren.",
        "Danke für deine Hilfe, das war wirklich nützlich.",
        "Stell einen Timer auf zwanzig Minuten.",
        "Lass uns um zwölf im Café an der Ecke treffen.",
        "Kannst du antworten, dass ich mit dem Plan einverstanden bin?",
    ]
}
