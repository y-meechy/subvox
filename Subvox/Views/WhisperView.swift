import Charts
import CoreAudio
import SwiftUI

/// Find out how quietly you can whisper before Parakeet (and Apple) stop understanding you.
struct WhisperView: View {
    @Environment(AppModel.self) private var model

    private var tester: WhisperTester { model.whisper }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                setupPanel
                if tester.parakeet.state == .ready {
                    recordPanel
                    if let latest = tester.latest { LatestAttemptPanel(attempt: latest) }
                    if !tester.attempts.isEmpty { historyPanel }
                }
            }
            .padding(20)
        }
        .task {
            // Load straight away if the model was downloaded before; first download waits for a click.
            if tester.parakeet.wasLoadedBefore { await tester.parakeet.load() }
        }
    }

    // MARK: Setup

    private var setupPanel: some View {
        @Bindable var tester = tester
        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "cpu").font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ParakeetService.modelName).font(.headline)
                        Text(parakeetStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    switch tester.parakeet.state {
                    case .notLoaded, .failed:
                        Button(tester.parakeet.wasLoadedBefore ? "Load model" : "Download model (~500 MB)") {
                            Task { await tester.parakeet.load() }
                        }
                        .buttonStyle(.borderedProminent)
                    case .loading:
                        ProgressView().controlSize(.small)
                    case .ready:
                        Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                if case .failed(let message) = tester.parakeet.state {
                    Text(message).font(.caption).foregroundStyle(.red)
                }

                Divider()

                HStack(spacing: 16) {
                    Button(model.audio.isRunning ? "Stop mic" : "Start mic") {
                        Task { await tester.toggleMic() }
                    }
                    Picker("Mic", selection: Binding(
                        get: { model.audio.selectedDeviceID },
                        set: { model.audio.selectedDeviceID = $0 })) {
                        Text("System default").tag(nil as AudioDeviceID?)
                        ForEach(model.audio.devices) { device in
                            Text(device.name).tag(Optional(device.id))
                        }
                    }
                    .frame(maxWidth: 260)
                    LevelMeter(value: Double(model.audio.level))
                        .frame(maxWidth: 160)
                    Text(model.audio.isRunning ? String(format: "%.0f dB", Double(model.audio.level) * 60 - 60) : "")
                        .font(.caption.monospacedDigit())
                        .frame(width: 50, alignment: .leading)
                }
                HStack(spacing: 16) {
                    Picker("Language", selection: $tester.language) {
                        ForEach(WhisperSentences.Language.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                    Toggle("Compare with Apple dictation", isOn: $tester.compareWithApple)
                        .toggleStyle(.checkbox)
                }
                Text("Choosing your AirPods as the mic tests what you'd really use, but switches them to the call profile. Parakeet detects the language by itself; the picker sets the sentences and Apple's language.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = model.audio.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(6)
        }
    }

    private var parakeetStatus: String {
        switch tester.parakeet.state {
        case .notLoaded: "Runs on your Mac's Neural Engine. Nothing leaves your Mac."
        case .loading: tester.parakeet.wasLoadedBefore ? "Loading…" : "Downloading and compiling, this takes a few minutes the first time…"
        case .ready: "Loaded. 25 European languages, detected automatically."
        case .failed: "Couldn't load."
        }
    }

    // MARK: Record

    private var recordPanel: some View {
        @Bindable var tester = tester
        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Whisper this:").font(.headline)
                    Spacer()
                    Button("Next sentence", systemImage: "arrow.right", action: tester.nextSentence)
                }
                TextField("Sentence", text: $tester.target, axis: .vertical)
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

                HoldToCaptureButton(
                    title: tester.isScoring ? "Transcribing…" : "Whisper the sentence",
                    isCapturing: tester.isRecording,
                    isEnabled: tester.canRecord,
                    onBegin: tester.begin,
                    onEnd: tester.end)

                if !model.audio.isRunning {
                    Label("Start the mic first.", systemImage: "mic.slash").font(.caption).foregroundStyle(.orange)
                }
                if let error = tester.error {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                Text("Start with a normal whisper, then go a bit quieter each take. The chart below shows where accuracy drops off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }

    // MARK: History

    private var historyPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Accuracy vs. how loud you whispered").font(.headline)
                    Spacer()
                    Button("Clear", action: tester.clearAttempts)
                }
                Chart {
                    ForEach(tester.attempts) { attempt in
                        if let accuracy = attempt.parakeetAccuracy {
                            PointMark(x: .value("Whisper level (dB)", attempt.loudness.speechDB),
                                      y: .value("Words right (%)", accuracy * 100))
                                .foregroundStyle(by: .value("Recognizer", "Parakeet"))
                                .symbol(by: .value("Recognizer", "Parakeet"))
                        }
                        if let accuracy = attempt.appleAccuracy {
                            PointMark(x: .value("Whisper level (dB)", attempt.loudness.speechDB),
                                      y: .value("Words right (%)", accuracy * 100))
                                .foregroundStyle(by: .value("Recognizer", "Apple"))
                                .symbol(by: .value("Recognizer", "Apple"))
                        }
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXAxisLabel("Whisper level (dBFS, louder →)")
                .chartYAxisLabel("Words right (%)")
                .frame(height: 220)

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text("#"); Text("Level"); Text("Above room"); Text("Parakeet"); Text("Apple")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach(tester.attempts.reversed()) { attempt in
                        GridRow {
                            Text("\(attempt.number)").monospacedDigit()
                            Text(String(format: "%.0f dB", attempt.loudness.speechDB)).monospacedDigit()
                            Text(String(format: "%.0f dB", attempt.loudness.signalToNoise)).monospacedDigit()
                            Text(percent(attempt.parakeetAccuracy)).monospacedDigit()
                            Text(percent(attempt.appleAccuracy)).monospacedDigit()
                        }
                    }
                }
                Text("Level is how loud your whisper reached the mic. \"Above room\" is how far it stood out from the background noise in that take.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }

    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", $0 * 100) } ?? "–"
    }
}

private struct LatestAttemptPanel: View {
    var attempt: WhisperAttempt

    var body: some View {
        GroupBox("Take \(attempt.number)") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 24) {
                    metric("Whisper level", String(format: "%.0f dB", attempt.loudness.speechDB))
                    metric("Above room noise", String(format: "%.0f dB", attempt.loudness.signalToNoise))
                    metric("Length", String(format: "%.1f s", attempt.duration))
                }
                result("Parakeet", text: attempt.parakeetText, accuracy: attempt.parakeetAccuracy)
                if attempt.appleText != nil {
                    result("Apple", text: attempt.appleText, accuracy: attempt.appleAccuracy)
                }
                if let error = attempt.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func result(_ name: String, text: String?, accuracy: Double?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(name).font(.caption.weight(.semibold)).frame(width: 64, alignment: .leading)
            Text(accuracy.map { String(format: "%.0f%%", $0 * 100) } ?? "–")
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(color(accuracy))
                .frame(width: 56, alignment: .leading)
            Text(text.map { $0.isEmpty ? "(heard nothing)" : $0 } ?? "–")
                .textSelection(.enabled)
                .foregroundStyle(text?.isEmpty == false ? .primary : .secondary)
        }
    }

    private func color(_ accuracy: Double?) -> Color {
        guard let accuracy else { return .secondary }
        return accuracy >= 0.9 ? .green : accuracy >= 0.6 ? .orange : .red
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit())
        }
    }
}
