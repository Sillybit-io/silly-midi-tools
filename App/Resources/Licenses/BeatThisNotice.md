# Attribution and conditions of use

Model: Beat This! `final0`, the checkpoint of [CPJKU/beat_this](https://github.com/CPJKU/beat_this) at commit
b95c8ab0c58c2d9fcfd40508ae8dffbc05ac4f5c, converted to ONNX for this app. Licensed under the MIT License.

## Attribution

> Francesco Foscarin, Jan Schlüter, Gerhard Widmer.
> **"Beat this! Accurate beat tracking without DBN postprocessing."**
> Proceedings of the 25th International Society for Music Information Retrieval Conference (ISMIR), San Francisco, 2024.

Beat This!: Copyright (c) 2024 Institute of Computational Perception, JKU Linz, Austria, MIT License.

## Changes made

The PyTorch checkpoint was converted to ONNX. The 128-band log-mel front end (22.05 kHz, 1024-sample window, 441-sample
hop, Slaney mel scale) and the six zero frames the reference adds at the ends of a piece are part of the graph, and the
graph takes a waveform of any length. No weights were modified or fine-tuned. The converted file matches the PyTorch
model's beat and downbeat logits to within 1e-4 on the conversion fixtures. Peak picking is done in the app, in the
reference's "minimal" mode; the Dynamic Bayesian Network post-processing and madmom are not used. The conversion scripts
are in `scripts/beat-this/` of the Silly MIDI Tools repository.

## Use in this app

The model finds the beats and downbeats of the recording. The app turns them into tempo and time-signature suggestions
that the user applies explicitly. It is downloaded on demand and is not bundled.

## License

Both the code and the published model weights are released under the MIT License. The authors note that some of the
training files are fully copyrighted or under limited Creative Commons licenses, and that it is up to the user to assess
whether this may impact their use case.
