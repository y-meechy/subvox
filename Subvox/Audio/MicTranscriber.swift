import AVFoundation
import Observation
import Speech

/// Continuous speech-to-text from the microphone. Used as the reference ("ground truth")
/// next to the motion decoder, and to test whether whispering is enough for input.
@MainActor @Observable
final class MicTranscriber {
    private(set) var isRunning = false
    private(set) var text = ""
    private(set) var isOnDevice = false
    private(set) var error: String?

    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    @ObservationIgnored private let box = RequestBox()
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var sinkID: UUID?
    @ObservationIgnored private weak var sink: AudioSink?
    @ObservationIgnored private var finalized = ""
    @ObservationIgnored private var generation = 0

    /// Called with every word of a finalized result, timed on the motion clock.
    /// Used by Read Aloud to cut labelled motion segments.
    @ObservationIgnored var onWords: (([TimedWord]) -> Void)?

    func start(sink: AudioSink) async {
        guard !isRunning else { return }
        error = nil

        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else {
            error = "Speech recognition not authorized."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            error = "Speech recognizer unavailable."
            return
        }

        self.sink = sink
        sinkID = sink.add { [box] buffer, time in box.append(buffer, at: time) }
        isRunning = true
        startTask()
    }

    func stop() {
        isRunning = false
        generation += 1
        if let sinkID { sink?.remove(sinkID) }
        sinkID = nil
        box.set(nil)
        task?.cancel()
        task = nil
    }

    func clear() {
        finalized = ""
        text = ""
    }

    private func startTask() {
        guard isRunning, let recognizer else { return }
        generation += 1

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        isOnDevice = recognizer.supportsOnDeviceRecognition
        request.requiresOnDeviceRecognition = isOnDevice
        box.set(request)
        let startTime: @Sendable () -> TimeInterval? = { [box, id = ObjectIdentifier(request)] in box.startTime(of: id) }

        task?.cancel()
        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler(
            owner: self, generation: generation, startTime: startTime))
    }

    private func handle(generation: Int, partial: String?, isFinal: Bool, failed: Bool, words: [TimedWord]) {
        guard generation == self.generation, isRunning else { return }
        if isFinal, !words.isEmpty { onWords?(words) }
        if let partial {
            text = finalized + partial
        }
        if isFinal || failed {
            if let partial, !partial.isEmpty { finalized += partial + " " }
            text = finalized
            // Recognition tasks end on silence/timeout; keep listening with a fresh one.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(failed ? 500 : 50))
                self?.startTask()
            }
        }
    }

    nonisolated private static func resultHandler(owner: MicTranscriber, generation: Int,
                                                  startTime: @escaping @Sendable () -> TimeInterval?)
        -> (SFSpeechRecognitionResult?, Error?) -> Void
    {
        { [weak owner] result, error in
            let partial = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            // Segment timestamps are relative to the first audio appended to this request.
            var words: [TimedWord] = []
            if isFinal, let result, let t0 = startTime() {
                words = result.bestTranscription.segments.compactMap { segment in
                    guard segment.duration > 0 else { return nil }
                    let start = t0 + segment.timestamp
                    return TimedWord(text: segment.substring, start: start, end: start + segment.duration)
                }
            }
            Task { @MainActor in
                owner?.handle(generation: generation, partial: partial, isFinal: isFinal, failed: failed, words: words)
            }
        }
    }
}

/// The current recognition request, appended to from the audio thread. Also remembers when
/// each request received its first audio, so word timestamps can be put on the motion clock.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var starts: [ObjectIdentifier: TimeInterval] = [:]

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.withLock {
            self.request?.endAudio()
            self.request = request
            // Old requests can still deliver a final result, so keep a few recent starts.
            if starts.count > 8 { starts.removeAll() }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        lock.withLock {
            guard let request else { return }
            let id = ObjectIdentifier(request)
            if starts[id] == nil {
                starts[id] = time.isHostTimeValid
                    ? AVAudioTime.seconds(forHostTime: time.hostTime)
                    : ProcessInfo.processInfo.systemUptime
            }
            request.append(buffer)
        }
    }

    func startTime(of id: ObjectIdentifier) -> TimeInterval? {
        lock.withLock { starts[id] }
    }
}
