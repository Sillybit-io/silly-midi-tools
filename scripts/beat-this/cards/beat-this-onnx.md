# Beat This! (ONNX)

Beat and downbeat tracking: framewise beat and downbeat logits at 50 frames per second for any piece of music, with no fixed
tempo range or meter. A conversion to ONNX of the `final0` checkpoint of
[Beat This!](https://github.com/CPJKU/beat_this) (Foscarin, Schlüter, Widmer, ISMIR 2024), with the log-mel front end fused
into the graph.

- Input `waveform`: `[1, N]` float32, mono, 22.05 kHz, values in [-1, 1], where `N = (frames - 1) * 441 + 1024`. It is the
  audio around a run of `frames` spectrogram frames: the frame at index `i` is centred on sample `i * 441`, so the run
  `[a, b)` needs samples `a * 441 - 512` to `(b - 1) * 441 + 512`. At the very start and end of a piece, extend by
  reflection (the centred STFT's `reflect` padding); everywhere else use the real neighbouring audio.
- Input `pad_frames`: `[2]` int64, the number of all-zero spectrogram frames to put before and after the run: 6 at the start
  and end of a piece, as the reference does, otherwise 0.
- Outputs `beat` and `downbeat`: `[1, T]` float32 logits, `T = pad_frames[0] + frames + pad_frames[1]`. `beat` already
  includes the downbeat term, as in the PyTorch model.
- Chunking, as in the reference: 1500-frame chunks that overlap by 6 frames on each side, the last chunk moved left to end
  at the end of the piece; drop 6 frames of each chunk's output at both ends and keep the first prediction where chunks
  overlap.
- A beat is a peak of the beat logits over a window of 7 frames with a logit above 0; peaks one frame apart are merged;
  a downbeat is moved to the nearest beat. Matches the PyTorch model to within 1e-4 on the conversion fixtures.

Converted by the [Silly MIDI Tools](https://github.com/Sillybit-io/silly-midi-tools) scripts in `scripts/beat-this/`.
