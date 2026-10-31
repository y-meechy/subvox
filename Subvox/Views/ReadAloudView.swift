import SwiftUI

/// Read a passage out loud; every recognized word becomes a labelled motion take.
/// Then mouth words on Decode and correct mistakes so it adapts to silent mouthing.
struct ReadAloudView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                intro
                passagePanel
                readingPanel
                HStack(alignment: .top, spacing: 16) {
                    vocabularyPanel
                    TransferPanel()
                }
            }
            .padding(20)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("1. Read the passage out loud at a normal pace, head still. Each word the mic recognizes is cut out of the motion stream and saved as a take.")
            Text("2. Go to Decode and mouth the same words silently. When it guesses wrong, tap the right word: that adds a mouthed take and it adapts to you.")
            Text("Speaking and mouthing move your jaw differently, so expect the first mouthed guesses to be rough. The transfer check below shows how well it carries over.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    // MARK: Passage

    private var passagePanel: some View {
        @Bindable var model = model
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Menu("Practice passages") {
                        ForEach(Passages.all) { passage in
                            Button(passage.title) { model.selectPassage(passage) }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    Text("Paste any text you like, too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextEditor(text: $model.passage)
                    .font(.system(size: 20, design: .rounded))
                    .lineSpacing(6)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 160)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

                Toggle("Only learn these words:", isOn: $model.learnOnlyTargets)
                    .toggleStyle(.checkbox)
                TextField("yes, no, next…", text: $model.targetWordsText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!model.learnOnlyTargets)
                HStack {
                    Button("Use every word in this passage") {
                        model.targetWordsText = WordAligner.words(in: model.passage).joined(separator: ", ")
                    }
                    Button("Reset to command words") {
                        model.targetWordsText = Passages.targetWords.joined(separator: ", ")
                    }
                }
                .font(.caption)
                .disabled(!model.learnOnlyTargets)
            }
            .padding(6)
        }
    }

    // MARK: Reading

    private var readingPanel: some View {
        @Bindable var model = model
        let ready = model.motion.status == .streaming
        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    Button {
                        Task { await model.toggleReadAloud() }
                    } label: {
                        Label(model.isReadingAloud ? "Stop reading" : "Start reading",
                              systemImage: model.isReadingAloud ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(model.isReadingAloud ? .red : .accentColor)
                    .disabled(!ready && !model.isReadingAloud)

                    LevelMeter(value: Double(model.audio.level), tint: model.isReadingAloud ? .red : .green)
                        .frame(maxWidth: 200)

                    VStack(alignment: .leading) {
                        Text("\(model.learnedThisSession)")
                            .font(.title2.bold().monospacedDigit())
                        Text("takes this session").font(.caption).foregroundStyle(.secondary)
                    }
                }

                if !ready {
                    Label("\(model.motion.status.label). Connect AirPods as the Mac's audio output.", systemImage: "airpodspro")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let error = model.audio.error ?? model.transcriber.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }

                heardText
                    .font(.system(size: 18, design: .rounded))
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                Text("Green words became takes. Grey words were heard but skipped (not in your list, or too short).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                LabeledContent("Motion/audio offset") {
                    Slider(value: $model.alignmentOffset, in: -0.3...0.3).frame(width: 180)
                    Text(String(format: "%+.2f s", model.alignmentOffset)).monospacedDigit().frame(width: 60)
                }
                .font(.callout)
                .help("Shift if the AirPods motion lags the mic. Positive = motion arrives later.")
                Text("Tip: the built-in Mac mic works best. Picking the AirPods mic switches them to a lower-quality call profile.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }

    private var heardText: Text {
        guard !model.heardWords.isEmpty else {
            return Text(model.isReadingAloud ? "Listening… words appear after each pause." : "Words you read will appear here.")
                .foregroundColor(.secondary)
        }
        return model.heardWords.suffix(80).reduce(Text("")) { text, word in
            text + Text(word.text + " ").foregroundColor(word.learned ? Color.green : Color.secondary.opacity(0.6))
        }
    }

    // MARK: Vocabulary

    private var vocabularyPanel: some View {
        let words = model.dataset.vocabulary
            .map { ($0, model.takeCounts(for: $0)) }
            .filter { $0.1.voiced + $0.1.mouthed > 0 }
            .sorted { ($0.1.voiced + $0.1.mouthed) > ($1.1.voiced + $1.1.mouthed) }
        return GroupBox("Takes per word") {
            VStack(alignment: .leading, spacing: 6) {
                if words.isEmpty {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        GridRow {
                            Text("word"); Text("read aloud"); Text("mouthed")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        ForEach(words.prefix(40), id: \.0) { entry in
                            GridRow {
                                Text(entry.0)
                                Text("\(entry.1.voiced)").monospacedDigit()
                                Text("\(entry.1.mouthed)").monospacedDigit()
                                    .foregroundStyle(entry.1.mouthed == 0 ? .secondary : .primary)
                            }
                        }
                    }
                }
                Text("Decode uses words with at least \(model.minTakes) takes (change on Decode).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Delete all read-aloud takes", role: .destructive, action: model.clearVoicedTakes)
                    .font(.caption)
                    .disabled(words.allSatisfy { $0.1.voiced == 0 })
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}

/// Train on read-aloud takes only, test on mouthed takes: does speaking teach it to read mouthing?
struct TransferPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GroupBox("Does reading aloud transfer to mouthing?") {
            VStack(alignment: .leading, spacing: 10) {
                Button("Check transfer", action: model.evaluateTransfer)
                if let result = model.transfer {
                    HStack(spacing: 24) {
                        metric("Mouthed accuracy", percent(result.accuracy), highlight: true)
                        metric("Chance", percent(result.chance))
                        metric("Mouthed tested", "\(result.tested)")
                    }
                    Text(verdict(result))
                        .font(.callout)
                        .foregroundStyle(result.accuracy > result.chance * 2 ? .green : .orange)
                } else {
                    Text("Needs read-aloud takes for at least 2 words, plus some mouthed takes of those words (from Train or from corrections on Decode). It recognizes each mouthed take using only the read-aloud takes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func verdict(_ result: TransferEvaluation) -> String {
        if result.tested < 10 {
            "Only \(result.tested) mouthed takes; mouth a few more on Decode for a reliable number."
        } else if result.accuracy > result.chance * 2 {
            "Reading aloud helps: mouthed words are recognized well above chance."
        } else {
            "Little transfer so far. Keep correcting on Decode: mouthed takes are what it learns from best."
        }
    }

    private func metric(_ title: String, _ value: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(highlight ? .title2.bold().monospacedDigit() : .title3.monospacedDigit())
        }
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}
