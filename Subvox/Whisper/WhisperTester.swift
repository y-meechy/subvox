import AVFoundation
import Observation
import Speech

/// One whispered take of a target sentence, scored by Parakeet and (optionally) Apple.
struct WhisperAttempt: Identifiable, Hashable {
    let id = UUID()
    var number: Int
    var target: String
    var duration: TimeInterval
    var loudness: LoudnessStats
    var parakeetText: String?
    var parakeetAccuracy: Double?
    var appleText: String?
    var appleAccuracy: Double?
    var error: String?
}

/// Hold to whisper, release to score: how quietly can you go before the words stop coming through?
@MainActor @Observable
final class WhisperTester {
    let parakeet = ParakeetService()

    var language: WhisperSentences.Language = .english {
        didSet {
            guard oldValue != language else { return }
            sentenceIndex = 0
            target = WhisperSentences.all(language)[0]
        }
    }
    var target = WhisperSentences.english[0]
    var compareWithApple = true

    private(set) var isRecording = false
    private(set) var isScoring = false
    private(set) var attempts: [WhisperAttempt] = []
    private(set) var error: String?

    @ObservationIgnored private let audio: AudioService
    @ObservationIgnored private let box = CaptureBox()
    @ObservationIgnored private var sinkID: UUID?
    @ObservationIgnored private var sentenceIndex = 0
    @ObservationIgnored private var recordingStarted: TimeInterval = 0

    init(audio: AudioService) {
        self.audio = audio
    }

    var canRecord: Bool {
        audio.isRunning && parakeet.state == .ready && !isScoring
    }

    var latest: WhisperAttempt? { attempts.last }

    func nextSentence() {
        let sentences = WhisperSentences.all(language)
        sentenceIndex = (sentenceIndex + 1) % sentences.count
        target = sentences[sentenceIndex]
    }

    func toggleMic() async {
        if audio.isRunning {
            detach()
            audio.stop()
        } else {
            await audio.start()
        }
    }

    func clearAttempts() {
        attempts.removeAll()
    }

    // MARK: Capture

    func begin() {
        guard canRecord, !isRecording else { return }
        error = nil
        if sinkID == nil {
            sinkID = audio.sink.add { [box] buffer, _ in box.append(buffer) }
        }
        box.start()
        recordingStarted = ProcessInfo.processInfo.systemUptime
        isRecording = true
    }

    func end() {
        guard isRecording else { return }
        isRecording = false
        let buffers = box.stop()
        let duration = ProcessInfo.processInfo.systemUptime - recordingStarted
        guard duration >= 0.3, let format = buffers.first?.format else {
            error = "Too short. Hold while you whisper the whole sentence."
            return
        }
        Task { await score(buffers: buffers, format: format, duration: duration) }
    }

    /// Stops listening to the mic (the mic itself is shared with the other screens).
    func detach() {
        if isRecording { _ = box.stop(); isRecording = false }
        if let sinkID { audio.sink.remove(sinkID) }
        sinkID = nil
    }

    // MARK: Scoring

    private func score(buffers: [AVAudioPCMBuffer], format: AVAudioFormat, duration: TimeInterval) async {
        isScoring = true
        defer { isScoring = false }

        let samples = Self.mono(buffers)
        let target = target
        var attempt = WhisperAttempt(
            number: (attempts.last?.number ?? 0) + 1,
            target: target,
            duration: duration,
            loudness: LoudnessStats.measure(samples, sampleRate: format.sampleRate))

        let useApple = compareWithApple
        let locale = language.localeIdentifier
        async let apple: String? = useApple ? Self.appleTranscription(buffers, locale: locale) : nil

        do {
            let text = try await parakeet.transcribe(samples, sampleRate: format.sampleRate)
            attempt.parakeetText = text
            attempt.parakeetAccuracy = WordErrorRate.accuracy(reference: target, hypothesis: text)
        } catch {
            attempt.error = error.localizedDescription
        }

        if let text = await apple {
            attempt.appleText = text
            attempt.appleAccuracy = WordErrorRate.accuracy(reference: target, hypothesis: text)
        }
        attempts.append(attempt)
    }

    /// Channel 0 of every buffer, concatenated.
    nonisolated private static func mono(_ buffers: [AVAudioPCMBuffer]) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(buffers.reduce(0) { $0 + Int($1.frameLength) })
        for buffer in buffers {
            guard let data = buffer.floatChannelData?[0] else { continue }
            out.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }
        return out
    }

    /// Apple's recognizer on the same audio, on-device when available, for comparison.
    /// Returns nil if it isn't authorized or available; "" if it heard nothing.
    nonisolated private static func appleTranscription(_ buffers: [AVAudioPCMBuffer], locale: String) async -> String? {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
              recognizer.isAvailable else { return nil }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        for buffer in buffers { request.append(buffer) }
        request.endAudio()

        let once = OnceBox()
        return await withCheckedContinuation { continuation in
            _ = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    if once.claim() { continuation.resume(returning: result.bestTranscription.formattedString) }
                } else if error != nil {
                    // "No speech detected" arrives as an error: count it as an empty transcript.
                    if once.claim() { continuation.resume(returning: "") }
                }
            }
        }
    }
}

/// Copies mic buffers while recording. Tap buffers are reused by the engine, so each is copied.
private final class CaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var recording = false
    private var buffers: [AVAudioPCMBuffer] = []

    func start() {
        lock.withLock {
            buffers.removeAll()
            recording = true
        }
    }

    func stop() -> [AVAudioPCMBuffer] {
        lock.withLock {
            recording = false
            defer { buffers.removeAll() }
            return buffers
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard lock.withLock({ recording }), let copy = Self.copy(buffer) else { return }
        lock.withLock { if recording { buffers.append(copy) } }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let src = buffer.floatChannelData, let dst = copy.floatChannelData else { return nil }
        copy.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
        let channels = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
        for channel in 0..<channels {
            dst[channel].update(from: src[channel], count: frames * stride)
        }
        return copy
    }
}

/// Resumes a continuation exactly once, whichever callback gets there first.
private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}
