import AppKit
import Observation

struct DecodedWord: Identifiable, Hashable {
    let id = UUID()
    var prediction: Prediction
    /// Set when you tell the decoder what you actually mouthed.
    var corrected: String?
    var text: String { corrected ?? prediction.best?.label ?? "?" }
    var isAccepted: Bool { corrected != nil || prediction.accepted }
}

/// A word the recognizer heard while reading aloud, and whether it became a training take.
struct HeardWord: Identifiable, Hashable {
    let id = UUID()
    var text: String
    var learned: Bool
}

@MainActor @Observable
final class AppModel {
    enum Screen: String, CaseIterable, Identifiable {
        case sensors = "Sensors"
        case readAloud = "Read Aloud"
        case whisper = "Whisper Test"
        case train = "Train"
        case decode = "Decode"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .sensors: "waveform.path.ecg"
            case .readAloud: "text.book.closed"
            case .whisper: "ear"
            case .train: "square.stack.3d.up"
            case .decode: "text.bubble"
            }
        }
    }

    let motion = HeadphoneMotionService()
    let audio = AudioService()
    let transcriber = MicTranscriber()
    let capture = CaptureController()
    let recorder = SessionRecorder()
    @ObservationIgnored lazy var whisper = WhisperTester(audio: audio)

    var screen: Screen = .train {
        didSet { syncCaptureMode() }
    }

    // MARK: Training

    private(set) var dataset = TemplateStore.load()
    var selectedWord: String?
    var featureSet: FeatureSet = .all {
        didSet { rebuildClassifier() }
    }
    private(set) var classifier: TemplateClassifier?
    private(set) var evaluation: Evaluation?
    private(set) var transfer: TransferEvaluation?
    private(set) var isEvaluating = false
    private(set) var lastTemplateID: Template.ID?

    // MARK: Decoding

    var decodeMode: CaptureController.Mode = .hold {
        didSet { syncCaptureMode() }
    }
    var maxDistance: Double = 1.5
    var minConfidence: Double = 0.05
    private(set) var decoded: [DecodedWord] = []
    private(set) var lastSegment: [MotionSample] = []
    /// Use takes cut from reading aloud when decoding mouthed words.
    var includeVoiced = true {
        didSet { rebuildClassifier() }
    }
    /// Words with fewer takes than this are left out of decoding (one-off words from a
    /// passage only add confusion).
    var minTakes = 3 {
        didSet { rebuildClassifier() }
    }

    // MARK: Read aloud

    var passage = Passages.all[0].text
    /// Comma/space separated list of words to learn. Empty = learn every word heard.
    var targetWordsText = Passages.targetWords.joined(separator: ", ")
    var learnOnlyTargets = true
    /// Seconds to shift motion relative to audio when cutting a word (positive = motion later).
    var alignmentOffset: Double = 0.05
    private(set) var isReadingAloud = false
    private(set) var heardWords: [HeardWord] = []
    private(set) var learnedThisSession = 0
    @ObservationIgnored private var motionHistory = MotionHistory()
    @ObservationIgnored private var startedMicForReading = false

    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var started = false

    init() {
        selectedWord = dataset.vocabulary.first
        rebuildClassifier()
    }

    func start() {
        guard !started else { return }
        started = true
        motion.onSample = { [weak self] sample in self?.ingest(sample) }
        capture.onSegment = { [weak self] segment in self?.handleSegment(segment) }
        motion.start()
        audio.refreshDevices()
        installKeyMonitor()
    }

    private func ingest(_ sample: MotionSample) {
        capture.ingest(sample)
        recorder.record(sample)
        motionHistory.append(sample)
    }

    private func syncCaptureMode() {
        capture.autoEnabled = screen == .decode && decodeMode == .auto
    }

    private func handleSegment(_ segment: [MotionSample]) {
        lastSegment = segment
        switch screen {
        case .train:
            guard let word = selectedWord else { return }
            addTemplate(Template(label: word, samples: segment, source: .mouthed))
            recorder.logEvent(segment, kind: "train", label: word, confidence: nil)
        case .decode:
            guard let classifier else { return }
            let prediction = classifier.predict(segment, maxDistance: maxDistance, minConfidence: minConfidence)
            decoded.append(DecodedWord(prediction: prediction))
            recorder.logEvent(segment, kind: prediction.accepted ? "decode" : "reject",
                              label: prediction.best?.label ?? "", confidence: prediction.confidence)
        case .sensors:
            recorder.logEvent(segment, kind: "segment", label: recorder.prompt, confidence: nil)
        case .readAloud, .whisper:
            break
        }
    }

    // MARK: Space bar = hold to capture

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard event.keyCode == 49 else { return event }
            let isDown = event.type == .keyDown
            let isRepeat = isDown && event.isARepeat
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if self.screen == .whisper {
                    // Space = hold to whisper (unless typing in the sentence field).
                    if NSApp.keyWindow?.firstResponder is NSText { return false }
                    guard self.whisper.canRecord || self.whisper.isRecording else { return false }
                    if !isDown { self.whisper.end() } else if !isRepeat { self.whisper.begin() }
                    return true
                }
                guard self.spaceCapturesMotion else { return false }
                if !isDown {
                    self.capture.end()
                } else if !isRepeat {
                    self.capture.begin()
                }
                return true
            }
            return consumed ? nil : event
        }
    }

    private var spaceCapturesMotion: Bool {
        // Let text fields keep the space bar.
        if NSApp.keyWindow?.firstResponder is NSText { return false }
        switch screen {
        case .train: return selectedWord != nil
        case .decode: return decodeMode == .hold && classifier != nil
        case .sensors: return recorder.isRecording
        case .readAloud, .whisper: return false
        }
    }

    // MARK: Dataset editing

    func templates(for word: String) -> [Template] {
        dataset.templates.filter { $0.label == word }
    }

    func addWord(_ raw: String) {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !word.isEmpty, !dataset.vocabulary.contains(word) else { return }
        dataset.vocabulary.append(word)
        selectedWord = word
        persist()
    }

    func removeWord(_ word: String) {
        dataset.vocabulary.removeAll { $0 == word }
        dataset.templates.removeAll { $0.label == word }
        if selectedWord == word { selectedWord = dataset.vocabulary.first }
        persist()
    }

    func addTemplate(_ template: Template) {
        dataset.templates.append(template)
        lastTemplateID = template.id
        persist()
    }

    func deleteTemplate(_ id: Template.ID) {
        dataset.templates.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        TemplateStore.save(dataset)
        rebuildClassifier()
    }

    /// Templates the decoder matches against, after the voiced and min-takes filters.
    var decodingTemplates: [Template] {
        let pool = includeVoiced ? dataset.templates : dataset.templates.filter { !$0.isVoiced }
        let counts = Dictionary(grouping: pool, by: \.label).mapValues(\.count)
        return pool.filter { counts[$0.label, default: 0] >= minTakes }
    }

    var decodingVocabulary: [String] {
        Array(Set(decodingTemplates.map(\.label))).sorted()
    }

    func takeCounts(for word: String) -> (voiced: Int, mouthed: Int) {
        let takes = templates(for: word)
        let voiced = takes.filter(\.isVoiced).count
        return (voiced, takes.count - voiced)
    }

    private func rebuildClassifier() {
        classifier = TemplateClassifier(templates: decodingTemplates, featureSet: featureSet)
        evaluation = nil
        transfer = nil
    }

    func evaluateTransfer() {
        let templates = dataset.templates
        let featureSet = featureSet
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                TransferEvaluation.run(templates: templates, featureSet: featureSet)
            }.value
            self.transfer = result
        }
    }

    func evaluate() {
        guard !isEvaluating else { return }
        isEvaluating = true
        // Leave-one-out needs at least two takes of each word.
        let counts = Dictionary(grouping: dataset.templates, by: \.label).mapValues(\.count)
        let templates = dataset.templates.filter { counts[$0.label, default: 0] >= 2 }
        let featureSet = featureSet
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Evaluation.run(templates: templates, featureSet: featureSet)
            }.value
            self.evaluation = result
            self.isEvaluating = false
        }
    }

    // MARK: Decode transcript

    var transcript: String {
        decoded.filter(\.isAccepted).map(\.text).joined(separator: " ")
    }

    /// "That was <word>": fixes the transcript and stores the last segment as a mouthed
    /// take, so the decoder adapts from read-aloud motion to your silent mouthing.
    func correctLast(to word: String) {
        guard !lastSegment.isEmpty, let index = decoded.indices.last else { return }
        decoded[index].corrected = word
        if !dataset.vocabulary.contains(word) { dataset.vocabulary.append(word) }
        addTemplate(Template(label: word, samples: lastSegment, source: .mouthed))
        recorder.logEvent(lastSegment, kind: "correct", label: word, confidence: nil)
    }

    func clearDecoded() {
        decoded.removeAll()
        lastSegment = []
    }

    // MARK: Read aloud

    var targetWords: Set<String> {
        Set(targetWordsText.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { WordAligner.normalize(String($0)) }
            .filter { !$0.isEmpty })
    }

    func selectPassage(_ passage: Passages.Passage) {
        self.passage = passage.text
    }

    func toggleReadAloud() async {
        if isReadingAloud {
            stopReadAloud()
        } else {
            await startReadAloud()
        }
    }

    private func startReadAloud() async {
        heardWords.removeAll()
        learnedThisSession = 0
        transcriber.onWords = { [weak self] words in self?.learn(from: words) }
        if !audio.isRunning {
            await audio.start()
            guard audio.isRunning else { return }
            startedMicForReading = true
        }
        if !transcriber.isRunning { await transcriber.start(sink: audio.sink) }
        isReadingAloud = transcriber.isRunning
    }

    private func stopReadAloud() {
        isReadingAloud = false
        transcriber.onWords = nil
        if startedMicForReading {
            transcriber.stop()
            audio.stop()
            startedMicForReading = false
        }
    }

    private func learn(from words: [TimedWord]) {
        guard isReadingAloud else { return }
        let targets = learnOnlyTargets ? targetWords : []
        var added = false
        for word in words {
            let label = WordAligner.normalize(word.text)
            guard !label.isEmpty else { continue }
            var learned = false
            if targets.isEmpty || targets.contains(label),
               let samples = WordAligner.slice(motionHistory.samples, for: word, offset: alignmentOffset) {
                if !dataset.vocabulary.contains(label) { dataset.vocabulary.append(label) }
                dataset.templates.append(Template(label: label, samples: samples, source: .voiced))
                recorder.logEvent(samples, kind: "voiced", label: label, confidence: nil)
                learned = true
                added = true
                learnedThisSession += 1
            }
            heardWords.append(HeardWord(text: label, learned: learned))
        }
        if heardWords.count > 300 { heardWords.removeFirst(heardWords.count - 300) }
        if added { persist() }
    }

    func clearVoicedTakes() {
        dataset.templates.removeAll(where: \.isVoiced)
        persist()
    }

    // MARK: Mic

    func toggleMic() async {
        if isReadingAloud {
            let ownedMic = startedMicForReading
            stopReadAloud()
            if ownedMic { return }
        }
        if audio.isRunning {
            transcriber.stop()
            audio.stop()
        } else {
            await audio.start()
            if audio.isRunning { await transcriber.start(sink: audio.sink) }
        }
    }
}
