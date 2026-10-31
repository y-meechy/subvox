import XCTest
@testable import Subvox

final class DecodingTests: XCTestCase {
    /// A synthetic "word": a burst of rotation at `frequency` cycles over the segment.
    private func take(_ frequency: Double, axis: Int, frames: Int = 30, noise: Double = 0.01) -> [MotionSample] {
        (0..<frames).map { i in
            let t = Double(i) / 25
            let envelope = sin(Double.pi * Double(i) / Double(frames - 1))
            let v = 0.2 * envelope * sin(2 * .pi * frequency * Double(i) / Double(frames))
            let jitter = { Double.random(in: -noise...noise) }
            var rotation = (jitter(), jitter(), jitter())
            switch axis {
            case 0: rotation.0 += v
            case 1: rotation.1 += v
            default: rotation.2 += v
            }
            return MotionSample(t: t, rotation: rotation)
        }
    }

    func testDTWIdenticalIsZeroAndWarpTolerant() {
        let a = MotionFeatures.frames(take(2, axis: 0, noise: 0), set: .rotation)
        let stretched = MotionFeatures.frames(take(2, axis: 0, frames: 40, noise: 0), set: .rotation)
        let other = MotionFeatures.frames(take(2, axis: 1, noise: 0), set: .rotation)
        XCTAssertEqual(DTW.distance(a, a), 0, accuracy: 1e-12)
        XCTAssertLessThan(DTW.distance(a, stretched), DTW.distance(a, other))
    }

    func testClassifierSeparatesDistinctWords() throws {
        var templates: [Template] = []
        for _ in 0..<6 {
            templates.append(Template(label: "yes", samples: take(2, axis: 0)))
            templates.append(Template(label: "no", samples: take(3, axis: 1)))
        }
        let classifier = try XCTUnwrap(TemplateClassifier(templates: templates, featureSet: .all))
        let prediction = classifier.predict(take(3, axis: 1), maxDistance: 10, minConfidence: 0)
        XCTAssertEqual(prediction.best?.label, "no")
        XCTAssertTrue(prediction.accepted)
    }

    func testEvaluationBeatsChanceOnlyWhenSignalExists() throws {
        var real: [Template] = []
        var noise: [Template] = []
        for _ in 0..<8 {
            real.append(Template(label: "yes", samples: take(2, axis: 0)))
            real.append(Template(label: "no", samples: take(3, axis: 2)))
            noise.append(Template(label: "yes", samples: take(0, axis: 0, noise: 0.05)))
            noise.append(Template(label: "no", samples: take(0, axis: 0, noise: 0.05)))
        }
        let signal = try XCTUnwrap(Evaluation.run(templates: real, featureSet: .all, permutations: 200))
        XCTAssertGreaterThan(signal.accuracy, 0.9)
        XCTAssertLessThan(signal.pValue, 0.01)

        let null = try XCTUnwrap(Evaluation.run(templates: noise, featureSet: .all, permutations: 200))
        XCTAssertGreaterThan(null.pValue, 0.01)
    }

    func testTrimDropsQuietPadding() {
        let quiet = (0..<20).map { MotionSample(t: Double($0) / 25) }
        let burst = take(2, axis: 0, noise: 0).map { s -> MotionSample in
            var s = s; s.t += 0.8; return s
        }
        let trimmed = MotionFeatures.trim(quiet + burst + quiet.map { var s = $0; s.t += 2; return s })
        XCTAssertLessThan(trimmed.count, 40)
        XCTAssertGreaterThanOrEqual(trimmed.count, 20)
    }

    // MARK: Read aloud

    func testNormalizeStripsPunctuationAndCase() {
        XCTAssertEqual(WordAligner.normalize("Next,"), "next")
        XCTAssertEqual(WordAligner.normalize("\"Stop!\""), "stop")
        XCTAssertEqual(WordAligner.normalize("Don’t"), "don't")
        XCTAssertEqual(WordAligner.normalize("..."), "")
        XCTAssertEqual(WordAligner.words(in: "Play. Pause, play again — STOP"), ["play", "pause", "again", "stop"])
    }

    func testSliceCutsTheSpokenWordWithPadding() throws {
        let stream = (0..<250).map { MotionSample(t: 100 + Double($0) / 25) } // 10 s at 25 Hz
        let word = TimedWord(text: "next", start: 103.0, end: 103.4)
        let slice = try XCTUnwrap(WordAligner.slice(stream, for: word, padding: 0.1))
        XCTAssertGreaterThanOrEqual(slice.first!.t, 102.9 - 1e-9)
        XCTAssertLessThanOrEqual(slice.last!.t, 103.5 + 1e-9)
        XCTAssertTrue((15...16).contains(slice.count), "0.6 s at 25 Hz, ±1 for float edges")

        let shifted = try XCTUnwrap(WordAligner.slice(stream, for: word, padding: 0.1, offset: 0.2))
        XCTAssertGreaterThanOrEqual(shifted.first!.t, 103.1 - 1e-9)

        let blip = TimedWord(text: "a", start: 105.0, end: 105.01)
        XCTAssertNil(WordAligner.slice(stream, for: blip, padding: 0))
        let outside = TimedWord(text: "late", start: 200, end: 200.5)
        XCTAssertNil(WordAligner.slice(stream, for: outside))
    }

    func testOldDatasetsDecodeWithoutSource() throws {
        let old = #"{"id":"9C1B7F2E-3D7B-4B8A-9E43-2B1C5A6D7E8F","label":"yes","samples":[],"createdAt":0}"#
        let template = try JSONDecoder().decode(Template.self, from: Data(old.utf8))
        XCTAssertNil(template.source)
        XCTAssertFalse(template.isVoiced)
    }

    func testTransferUsesOnlyVoicedTakesForTraining() throws {
        var templates: [Template] = []
        for _ in 0..<5 {
            templates.append(Template(label: "yes", samples: take(2, axis: 0), source: .voiced))
            templates.append(Template(label: "no", samples: take(3, axis: 1), source: .voiced))
        }
        // Mouthed takes that resemble the voiced ones: transfer should work.
        for _ in 0..<4 {
            templates.append(Template(label: "yes", samples: take(2, axis: 0), source: .mouthed))
            templates.append(Template(label: "no", samples: take(3, axis: 1), source: .mouthed))
        }
        let result = try XCTUnwrap(TransferEvaluation.run(templates: templates, featureSet: .all))
        XCTAssertEqual(result.tested, 8)
        XCTAssertEqual(result.voicedTakes, 10)
        XCTAssertGreaterThan(result.accuracy, 0.8)
        XCTAssertEqual(result.chance, 0.5, accuracy: 1e-9)

        // No mouthed takes → nothing to test.
        XCTAssertNil(TransferEvaluation.run(templates: templates.filter(\.isVoiced), featureSet: .all))
    }

    // MARK: Whisper test

    func testWordErrorRate() {
        XCTAssertEqual(WordErrorRate.compute(reference: "Set a timer for twenty minutes.", hypothesis: "set a timer for twenty minutes"), 0)
        // One substitution out of six words.
        XCTAssertEqual(WordErrorRate.compute(reference: "set a timer for twenty minutes", hypothesis: "set a timer for thirty minutes"), 1.0 / 6, accuracy: 1e-9)
        // Deletion and insertion.
        XCTAssertEqual(WordErrorRate.compute(reference: "please turn it down", hypothesis: "turn it down now"), 0.5, accuracy: 1e-9)
        XCTAssertEqual(WordErrorRate.compute(reference: "hello there", hypothesis: ""), 1)
        XCTAssertEqual(WordErrorRate.accuracy(reference: "yes", hypothesis: "no no no"), 0)
        XCTAssertEqual(WordErrorRate.compute(reference: "Mach die Musik leiser.", hypothesis: "mach die musik leiser"), 0)
    }

    func testLoudnessSeparatesWhisperFromRoom() {
        let rate = 16_000.0
        // 1 s of quiet room noise (~-60 dBFS) then 1 s of a louder tone (~-23 dBFS).
        let quiet = (0..<16_000).map { _ in Float.random(in: -0.001...0.001) }
        let tone = (0..<16_000).map { i in Float(0.1 * sin(2 * Double.pi * 300 * Double(i) / rate)) }
        let stats = LoudnessStats.measure(quiet + tone, sampleRate: rate)
        XCTAssertEqual(stats.speechDB, -23, accuracy: 1.5)
        XCTAssertLessThan(stats.noiseDB, -55)
        XCTAssertGreaterThan(stats.signalToNoise, 30)
        XCTAssertEqual(LoudnessStats.measure([], sampleRate: rate).speechDB, LoudnessStats.silenceDB)
    }
}
