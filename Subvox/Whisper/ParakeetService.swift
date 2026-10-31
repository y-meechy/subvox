import FluidAudio
import Foundation
import Observation

/// Runs NVIDIA Parakeet locally (CoreML on the Neural Engine) through FluidAudio.
/// FluidAudio is only imported here so its type names can't clash with the app's.
@MainActor @Observable
final class ParakeetService {
    enum State: Equatable {
        case notLoaded
        case loading
        case ready
        case failed(String)
    }

    /// Multilingual Parakeet (25 European languages incl. German, auto-detected).
    /// "ultra" is FluidAudio's recommended v3-family model: same speed, better accuracy.
    static let modelName = "Parakeet TDT 0.6B (ultra)"
    static let sampleRate = 16_000.0
    private static let minimumSeconds = 0.5
    private static let loadedBeforeKey = "parakeetLoadedBefore"

    private(set) var state: State = .notLoaded

    /// True once the model has been downloaded on this Mac, so it can load without asking.
    var wasLoadedBefore: Bool {
        UserDefaults.standard.bool(forKey: Self.loadedBeforeKey)
    }

    @ObservationIgnored private var manager: AsrManager?
    @ObservationIgnored private let converter = AudioConverter(sampleRate: ParakeetService.sampleRate)

    func load() async {
        switch state {
        case .loading, .ready: return
        default: break
        }
        state = .loading
        do {
            let models = try await AsrModels.downloadAndLoad(version: .ultra)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            self.manager = manager
            UserDefaults.standard.set(true, forKey: Self.loadedBeforeKey)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Transcribes mono Float32 samples recorded at `sampleRate`.
    func transcribe(_ samples: [Float], sampleRate: Double) async throws -> String {
        guard let manager else { throw ParakeetError.notLoaded }
        var audio = try converter.resample(samples, from: sampleRate)
        // Very short takes are padded with silence rather than rejected.
        let minimum = Int(Self.sampleRate * Self.minimumSeconds)
        if audio.count < minimum { audio += [Float](repeating: 0, count: minimum - audio.count) }
        var decoderState = TdtDecoderState.make()
        let result = try await manager.transcribe(audio, decoderState: &decoderState)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum ParakeetError: LocalizedError {
        case notLoaded
        var errorDescription: String? { "Parakeet isn't loaded yet." }
    }
}
