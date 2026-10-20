# Development

How to build Silly MIDI Tools, run its tests, add a model, and cut a release.

## Build from source

Requirements: macOS 26 or later, Xcode 26 or later, `xcodegen`, `cmake` and `ninja`.

```sh
git clone --recurse-submodules https://github.com/Sillybit-io/silly-midi-tools.git
cd silly-midi-tools
scripts/build-engine.sh
xcodegen generate
xcodebuild -project SillyMIDITools.xcodeproj -scheme SillyMIDITools -destination 'platform=macOS' build CODE_SIGN_IDENTITY=-
```

The Xcode project is generated from `project.yml` and is not checked in, so run `xcodegen generate` after cloning and after editing `project.yml`. Builds are for the host architecture only and are ad-hoc signed. Building from source is also the way to run the app on an Intel Mac.

Debug builds have a **Debug** menu, with **Simulate Crash**, to check that the debug log records each kind of crash. `open SillyMIDITools.app --args -SimulateCrash swift` does the same without the menu; the other kinds are `exception` and `memory`.

## Tests

To run the tests, replace `build` with `test` and keep `CODE_SIGN_IDENTITY=-`, as the CI workflow does: the tests that create real security-scoped bookmarks need the app's entitlements, which an unsigned build (`CODE_SIGNING_ALLOWED=NO`) leaves out.

- The end-to-end piano tests need the model, which `scripts/fetch-piano-onnx.sh` downloads.
- The end-to-end drum tests need `build/models/adtof_frame_rnn.onnx` and `oaf_drums.onnx` (from `scripts/convert-drums.sh`) and `htdemucs_ft_drums.onnx` for the separator; each skips when its file is missing.
- The end-to-end Beat This! tests need `build/models/beat_this.onnx` (from `scripts/convert-beat-this.sh`) and skip when it is missing. The test that downloads it from the catalogue (82 MB) runs only with `TEST_RUNNER_SILLY_MIDI_NETWORK_TESTS=1` in the environment of `xcodebuild test`.
- The end-to-end hand percussion tests read two Wikimedia Commons darbuka recordings (CC BY-SA 4.0, test input only) that `scripts/fetch-darbuka-clips.sh` downloads into `build/percussion`, and skip without them.

## Adding a model

1. Add a `ModelEntry` to `App/Models/ModelCatalog.swift`: the Hugging Face repo, a pinned revision, the file's size and SHA-256, the `access` policy, the statements to tick (none for open models), the licence kind and texts. The access policies are described in [Models](MODELS.md#how-a-model-asks-for-access).
2. Put the licence text and an attribution notice in `App/Resources/Licenses`, add a section to `THIRD_PARTY_NOTICES.md` and a matching name and entry in `App/Models/ThirdPartyComponents.swift`.
3. Give the engine an export notice, and wire it into `AudioScreenModel.launch` and the picker in `AudioInspectorView`.

The tests check that every entry's licence text resolves and names its licence, and that every download is pinned.

## The drum models

The two drum models are converted from the authors' checkpoints (ADTOF's Keras checkpoint, Magenta's E-GMD TensorFlow checkpoint) to ONNX with the audio frontend inside the graph. `scripts/convert-drums.sh` rebuilds both files and the test fixtures, and asserts that each matches the authors' own pipeline (ADTOF to 2e-6, OaF to 4e-5). They are hosted at `thebluescreen/adtof-drums-onnx` and `thebluescreen/oaf-drums-onnx`, and the catalogue pins each to a revision. `scripts/publish-drum-models.sh HF_USERNAME` uploads a rebuilt pair (it needs a Hugging Face token that can write), checks the download byte for byte, and re-pins the catalogue.

## The beat tracker model

Beat This! is converted from the authors' `final0` checkpoint (upstream commit `b95c8ab0c58c2d9fcfd40508ae8dffbc05ac4f5c`, checkpoint SHA-256 `8c328b45f59d8dd3dff219253ff6a8d6482be57d0133a29140e2febbf8eb8331`) to one ONNX file with the log-mel front end inside the graph. The graph takes the waveform around a run of spectrogram frames and the number of zero frames to pad, so it follows the reference's chunking exactly. `scripts/convert-beat-this.sh` rebuilds `build/models/beat_this.onnx` and the fixtures in `Tests/Fixtures/BeatThis`, and fails, removing the model, unless the front end and the logits match the PyTorch pipeline to 1e-4 on a short, a 10 s, a 30 s and a 45 s piece (the 30 s and 45 s pieces cover the 1500-frame chunks and their seam). It needs `uv` and network access. `scripts/publish-beat-this.sh HF_USERNAME` uploads the model to `HF_USERNAME/beat-this-onnx` (it needs a Hugging Face token that can write), downloads it back from the pinned revision, compares it byte for byte and then rewrites the lines marked `beat-this-models` in `App/Models/ModelCatalog.swift`; `--dry-run` stages the files under `build/beat-this/publish` and changes nothing. The catalogue lists Beat This! only once those lines are pinned. The published model is at `thebluescreen/beat-this-onnx`, revision `92842057ebb781a31fcf0d638f04a098fb887313`.

## Releasing

1. Raise `CFBundleShortVersionString` and `CFBundleVersion` in `project.yml`.
2. Write the release notes in `.github/release/notes/<version>.md`. Without that file the release lists commit subjects instead. The install steps and the zip's SHA-256 are added for you.
3. Push to `main` and wait for CI to pass.
4. On GitHub, open Actions, Release, **Run workflow** on `main`. Tick **draft** to review the release before it goes public.

The workflow builds the Apple silicon app on a runner, checks its version, architecture and signature, tags the commit `v<version>`, and attaches `SillyMIDITools-<version>-macOS-arm64.zip`, its `.sha256` and `SillyMIDITools-<version>-macOS-arm64.dSYM.zip` to the release. It refuses to run if the version is already tagged or CI hasn't passed on the commit.

The dSYM holds the debug symbols of that exact build. To turn an address in a crash stack into a function, file and line, take the app's load address from the **Images** list at the top of the debug log:

```sh
atos -o SillyMIDITools.app.dSYM/Contents/Resources/DWARF/SillyMIDITools -arch arm64 -l <load address> <address>
```

Names already in the stack are mangled Swift; `xcrun swift-demangle` makes them readable.
