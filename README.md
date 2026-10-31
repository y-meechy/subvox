# Subvox

A macOS prototype that tests whether AirPods Pro head-motion data (`CMHeadphoneMotionManager`) carries enough information to turn **silently mouthed words into text**.

It doesn't use a language model. It's a small-vocabulary template recognizer plus a statistical test that tells you whether the signal is real.

## Build & run

```sh
brew install xcodegen   # once
xcodegen generate
open Subvox.xcodeproj   # ⌘R
```

Or from the command line:

```sh
xcodebuild -project Subvox.xcodeproj -scheme Subvox -derivedDataPath build -allowProvisioningUpdates build
open build/Build/Products/Debug/Subvox.app
xcodebuild -project Subvox.xcodeproj -scheme Subvox -derivedDataPath build test
```

Requires macOS 14+, AirPods Pro or another headphone that supports head tracking, connected as the Mac's audio output. On first launch, grant **Motion**. The mic and speech prompts only appear when you start the mic.

## Screens

| Screen | What it does |
|---|---|
| **Whisper Test** | Hold Space, whisper a sentence, and see how much Parakeet and Apple dictation got right at that loudness. |
| **Read Aloud** | Read a passage out loud; each recognized word is cut from the motion stream and saved as a voiced take. Includes the voiced→mouthed transfer check. |
| **Sensors** | Live plots of user acceleration, rotation rate and attitude, the measured sample rate, a mic input picker and level meter, and a recorder for experiment sessions. |
| **Train** | Pick a word, hold **Space**, mouth it, release. Each take is stored as a template. **Evaluate** runs leave-one-out classification and a 500× label-permutation test, then shows accuracy against chance, a p-value and a confusion matrix. The feature checkboxes (acceleration / rotation / attitude) let you test which channels carry the signal. |
| **Decode** | The motion-to-text screen. Hold Space, or use auto-detect after calibrating the noise floor. Each segment is DTW-matched against your templates and added to the transcript. A live mic transcript runs alongside it for comparison. |

## Whisper Test (Parakeet vs Apple)

How quietly can you whisper and still be understood? Open **Whisper Test**, download Parakeet once (about 500 MB, via [FluidAudio](https://github.com/FluidInference/FluidAudio); runs on the Neural Engine, nothing leaves your Mac), start the mic and hold Space while you whisper the sentence shown.

Each take gets your whisper level (dBFS), how far it stood above the room noise, and the share of words Parakeet and Apple dictation got right on the same audio. The chart plots accuracy against loudness, so the point where it drops off is your threshold. English and German sentences are included; Parakeet detects the language itself.

## Read Aloud (train by speaking, decode mouthing)

Recording 8–10 held-Space takes per word is slow. The **Read Aloud** screen lets you train by reading text out loud instead:

1. Pick a practice passage (or paste your own) and press **Start reading**. Read at a normal pace with your head still.
2. Each word the on-device speech recognizer finalizes comes back with start/end timestamps. Those are put on the motion clock (both use host time) and the matching slice of AirPods motion is saved as a **voiced** take of that word.
3. By default only the words in the target list are kept (the passages repeat a 12-word command set), because 1-NN matching needs several takes per word. Turn the filter off, or use "every word in this passage", to learn everything you say.
4. On **Decode**, mouth the words silently. Under *Last segment*, tap what you actually mouthed: that fixes the transcript and saves the segment as a **mouthed** take, so the decoder adapts from your speaking motion to your mouthing motion.
5. **Does reading aloud transfer to mouthing?** trains only on voiced takes and tests on your mouthed takes, with chance for comparison. This is the honest number: speaking and mouthing move the jaw differently, so expect transfer to be partial and corrections to matter.

Decode settings: *Use read-aloud takes* (on by default) and *Min takes per word* (default 3) control which words the decoder considers. If AirPods motion lags the mic on your setup, adjust *Motion/audio offset*. The built-in Mac mic works best; using the AirPods mic switches them to the HFP call profile.

## How decoding works

1. **Segmentation** (`CaptureController`). Space-hold, or an energy trigger above a calibrated noise floor with pre-roll and hangover.
2. **Features** (`MotionFeatures`). Per frame: user acceleration (3), rotation rate (3), and attitude change since the start of the segment (3). Each channel is mean-centered, and quiet lead-in and lead-out frames are trimmed.
3. **Matching** (`DTW`, `TemplateClassifier`). Each channel is z-scaled across the training set. Matching is 1-nearest-neighbour per word, using dynamic time warping with a Sakoe–Chiba band. A segment is rejected if the best distance is above *max distance* or the margin to the runner-up is below *min confidence*.
4. **Is it real?** (`Evaluation`). The leave-one-out accuracy is compared with the same procedure run on shuffled labels. If p < 0.05, the motion stream distinguishes your words better than chance.

## Experiment protocol

Use **Record Session** in the toolbar or on the Sensors screen. Recordings go to `~/Documents/Subvox/Sessions/<timestamp>-<condition>/`:

- `motion.csv`: every motion sample. `t` is seconds from session start.
- `audio.caf`: microphone audio, if the mic is running.
- `events.csv`: every Space-held segment, with its label or prediction.
- `meta.json`: condition, prompt, and the audio start offset for aligning audio with motion.

Suggested runs: the same 5-word script under **Normal speech**, **Whisper** and **Silent mouthing**, 10 reps each. Then, in Train, compare the Evaluate results across feature sets.

The training set lives at `~/Library/Application Support/Subvox/dataset.json`.

## Known limits

- Headphone motion is processed and low-rate (roughly 25 Hz on AirPods). The speech-detecting accelerometer and the inward mic are not exposed. Expect jaw and head movement, not vocal vibration.
- Templates are user- and session-specific. Re-seating the AirPods can shift the signal.
- Choosing AirPods as the mic input switches them to the Bluetooth headset (HFP) profile.
