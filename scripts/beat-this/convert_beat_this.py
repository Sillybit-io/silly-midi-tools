"""Export Beat This! with a dynamic waveform-to-logits interface and prove upstream parity.

Usage: convert_beat_this.py SOURCE_DIR FINAL0.ckpt OUT.onnx FIXTURES_DIR
Only the upstream checkout and environment pinned in scripts/convert-beat-this.sh are supported.
"""

import csv
import hashlib
import json
import sys
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
import soundfile as sf
import torch
from torch import nn

source, checkpoint, out_path, fixtures = map(Path, sys.argv[1:5])
sys.path.insert(0, str(source))
from beat_this.inference import aggregate_prediction, load_model, split_piece  # noqa: E402
from beat_this.model.postprocessor import Postprocessor, deduplicate_peaks  # noqa: E402
from beat_this.preprocessing import LogMelSpect  # noqa: E402

SAMPLE_RATE = 22050
HOP = 441
FFT = 1024
BORDER = 6
CHUNK = 1500
CHECKPOINT_SHA = "8c328b45f59d8dd3dff219253ff6a8d6482be57d0133a29140e2febbf8eb8331"
UPSTREAM_COMMIT = "b95c8ab0c58c2d9fcfd40508ae8dffbc05ac4f5c"
torch.set_num_threads(4)


def waveform_context(piece: np.ndarray, first_frame: int, end_frame: int) -> np.ndarray:
    """Build [a*441-512, (b-1)*441+511] from ORIGINAL mono samples.

    Reflect only across true piece boundaries, like torch.stft(center=True,
    pad_mode='reflect'). The last inclusive sample is center+511 because the
    1024-point window is even (the requested total is (b-a-1)*441+1024).
    No chunk-boundary reflection and no spectrogram zero padding here.
    """
    if not 0 <= first_frame < end_frame or len(piece) < 2:
        raise ValueError("invalid waveform context range")
    positions = np.arange(first_frame * HOP - FFT // 2, (end_frame - 1) * HOP + FFT // 2, dtype=np.int64)
    period = 2 * (len(piece) - 1)
    wrapped = positions % period
    reflected = np.where(wrapped < len(piece), wrapped, period - wrapped)
    return np.ascontiguousarray(piece[reflected], dtype=np.float32)


class DynamicRotary(nn.Module):
    """The pinned RotaryEmbedding's uncached lang mode, without its tracing-time cache.

    Use the same learned/nonlearned frequency tensor from the original module.
    torch.arange(t.shape[-2]) must export to ONNX Shape -> Range, not a fixed
    1500-position initializer. Interleaved pairs match rotate_half exactly.
    """

    def __init__(self, original):
        super().__init__()
        self.register_buffer("freqs", original.freqs.detach().clone())

    def rotate_queries_or_keys(self, t):
        positions = torch.arange(t.shape[-2], device=t.device, dtype=self.freqs.dtype)
        phases = positions[:, None] * self.freqs[None, :]
        angles = torch.stack((phases, phases), dim=-1).reshape(-1, 32)
        rotated = torch.stack((-t[..., 1::2], t[..., ::2]), dim=-1).flatten(-2)
        return t * angles.cos()[None, None] + rotated * angles.sin()[None, None]


class FusedFrontend(nn.Module):
    def __init__(self, upstream_mel):
        super().__init__()
        self.register_buffer("window", upstream_mel.spect_class.spectrogram.window.detach().clone())
        self.register_buffer("mel_fb", upstream_mel.spect_class.mel_scale.fb.detach().clone())

    def forward(self, waveform, pad_frames):
        # center=False: caller provides the actual full-piece 512-sample halo.
        stft = torch.stft(waveform, n_fft=FFT, hop_length=HOP, win_length=FFT,
                          window=self.window, center=False, normalized=True, return_complex=False)
        magnitude = torch.sqrt(stft[..., 0] ** 2 + stft[..., 1] ** 2)
        mel = torch.log1p(1000.0 * (magnitude.transpose(1, 2) @ self.mel_fb))
        # Create dynamic-length zero MEL frames, NOT audio zeros: upstream zeropad.
        left = torch.zeros((1, pad_frames[0], 128), dtype=mel.dtype, device=mel.device)
        right = torch.zeros((1, pad_frames[1], 128), dtype=mel.dtype, device=mel.device)
        return torch.cat((left, mel, right), dim=1)


class FusedBeatThis(nn.Module):
    def __init__(self, frontend, network):
        super().__init__()
        self.mel = frontend
        self.network = network

    def forward(self, waveform, pad_frames):
        result = self.network(self.mel(waveform, pad_frames))
        return result["beat"], result["downbeat"]


def synthetic_piece():
    """Deterministic quiet noise with short clicks at accented 4/4 and 3/4 bars."""
    rng = np.random.RandomState(20261020)
    n = 45 * SAMPLE_RATE
    x = rng.normal(0, 0.0015, n).astype(np.float32)
    pos = 0.16
    bar = 0
    while pos < 45:
        beats_in_bar = 4 if bar % 9 < 5 else 3
        for beat in range(beats_in_bar):
            idx = round((pos + beat * 0.5) * SAMPLE_RATE)
            if idx >= n:
                break
            pulse = np.arange(min(900, n - idx), dtype=np.float32)
            amplitude = 0.78 if beat == 0 else 0.47
            x[idx:idx + len(pulse)] += amplitude * np.exp(-pulse / (90 if beat == 0 else 48)) * np.cos(
                pulse * (2 * np.pi * (110 if beat == 0 else 220) / SAMPLE_RATE))
        pos += beats_in_bar * 0.5
        bar += 1
    # The exact PCM samples used by all reference paths are those stored in the WAV.
    pcm = np.round(np.clip(x, -1, 1) * 32767).astype("<i2")
    return pcm, (pcm.astype(np.float32) / 32768.0)


def options(session):
    return [{"name": x.name, "type": x.type, "shape": x.shape} for x in session]


def verify_rotary(reference):
    original = next(m.rotary_embed for m in reference.modules() if hasattr(m, "rotary_embed") and m.rotary_embed is not None)
    replacement = DynamicRotary(original)
    for length in (16, 163, 513, 1500):
        rng = torch.Generator().manual_seed(length)
        q = torch.randn((1, 2, length, 32), generator=rng)
        diff = (original.rotate_queries_or_keys(q) - replacement.rotate_queries_or_keys(q)).abs().max().item()
        assert diff < 2e-6, f"rotary parity at {length}: {diff}"
    for module in reference.modules():
        if hasattr(module, "rotary_embed") and module.rotary_embed is original:
            module.rotary_embed = replacement


def replace_export_rearranges(network):
    """Use explicit dynamic reshape/permute in place of einops' traced shape arithmetic.

    The original model remains untouched. Numerical equivalence of the adapter is
    checked at 163, 513, and 1500 frames before exporting the fused graph.
    """
    import types
    from beat_this.model.beat_tracker import PartialFTTransformer, SumHead
    from beat_this.model.roformer import Attention

    def partial(self, x):
        batch, channels, freqs, time = x.shape
        x = x.permute(0, 3, 2, 1).reshape(batch * time, freqs, channels)
        x = x + self.attnF(x)
        x = x + self.ffF(x)
        x = x.reshape(batch, time, freqs, channels).permute(0, 2, 1, 3).reshape(batch * freqs, time, channels)
        x = x + self.attnT(x)
        x = x + self.ffT(x)
        return x.reshape(batch, freqs, time, channels).permute(0, 3, 1, 2)

    def attention(self, x):
        x = self.norm(x)
        batch, time, _ = x.shape
        qkv = self.to_qkv(x).reshape(batch, time, 3, self.heads, -1).permute(2, 0, 3, 1, 4)
        q, k, v = qkv[0], qkv[1], qkv[2]
        if self.rotary_embed is not None:
            q = self.rotary_embed.rotate_queries_or_keys(q)
            k = self.rotary_embed.rotate_queries_or_keys(k)
        out = self.attend(q, k, v)
        if self.to_gates is not None:
            out = out * self.to_gates(x).permute(0, 2, 1).unsqueeze(-1).sigmoid()
        return self.to_out(out.permute(0, 2, 1, 3).reshape(batch, time, -1))

    def sum_head(self, x):
        both = self.beat_downbeat_lin(x)
        beat = both[..., 0]
        downbeat = both[..., 1]
        return {"beat": beat.float() + downbeat.float(), "downbeat": downbeat}

    for module in network.modules():
        if isinstance(module, PartialFTTransformer):
            module.forward = types.MethodType(partial, module)
        elif isinstance(module, Attention):
            module.forward = types.MethodType(attention, module)
        elif isinstance(module, SumHead):
            module.forward = types.MethodType(sum_head, module)


def export(frontend, reference):
    # Trace at a short length; other lengths must be built by dynamic ONNX ops.
    example = torch.zeros(1, (163 - 12 - 1) * HOP + FFT, dtype=torch.float32)
    pads = torch.tensor([6, 6], dtype=torch.int64)
    dynamic = {"waveform": {1: "samples"}, "beat": {1: "frames"}, "downbeat": {1: "frames"}}
    debug_path = out_path.parent / "beat_this_frontend_debug.onnx"
    torch.onnx.export(frontend, (example, pads), str(debug_path), opset_version=17,
                      input_names=["waveform", "pad_frames"], output_names=["mel"],
                      dynamic_axes={"waveform": {1: "samples"}, "mel": {1: "frames"}})
    # torch 2.2.2's native shape inference SIGSEGVs on this network, both in
    # per-node Transpose inference and in its final graph inference. ONNX's
    # independent checker and ORT still validate and run the exported graph.
    # Public export forcibly resets the shape-inference flag to True. This
    # pinned Torch version exposes the same exporter with the flag in utils.
    from torch.onnx import utils as onnx_utils
    onnx_utils._export(FusedBeatThis(frontend, reference), (example, pads), str(out_path), opset_version=17,
                       input_names=["waveform", "pad_frames"], output_names=["beat", "downbeat"],
                       dynamic_axes=dynamic, do_constant_folding=True, onnx_shape_inference=False)
    graph = onnx.load(str(out_path))
    for key, value in {
        "source": f"CPJKU/beat_this @ {UPSTREAM_COMMIT}, final0.ckpt SHA-256 {CHECKPOINT_SHA}",
        "license": "MIT", "sample_rate": str(SAMPLE_RATE),
        "interface": "waveform [1,N] float32; pad_frames [left,right] int64; beat/downbeat [1,T] float32 logits",
    }.items():
        prop = graph.metadata_props.add()
        prop.key, prop.value = key, value
    onnx.checker.check_model(graph)
    onnx.save(graph, str(out_path))
    shape_nodes = [node for node in graph.graph.node if node.op_type == "Range"]
    assert shape_nodes, "rotary position Range was baked into the ONNX graph"
    return debug_path


def run():
    assert hashlib.sha256(checkpoint.read_bytes()).hexdigest() == CHECKPOINT_SHA
    fixtures.mkdir(parents=True, exist_ok=True)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    oracle_model = load_model(str(checkpoint))
    upstream_mel = LogMelSpect()
    frontend = FusedFrontend(upstream_mel).eval()
    # Keep the original model pristine as the oracle; export a second loaded copy.
    export_model = load_model(str(checkpoint))
    verify_rotary(export_model)
    replace_export_rearranges(export_model)
    with torch.inference_mode():
        for length in (163, 513, 1500):
            test_mel = torch.rand((1, length, 128), generator=torch.Generator().manual_seed(length)) * 3
            expected = oracle_model(test_mel)
            actual = export_model(test_mel)
            for key in ("beat", "downbeat"):
                drift = (expected[key] - actual[key]).abs().max().item()
                assert drift < 2e-5, f"network adapter {length} {key}: {drift}"
    debug_path = export(frontend, export_model)
    ort_options = ort.SessionOptions()
    ort_options.intra_op_num_threads = 4
    ort_options.inter_op_num_threads = 1
    frontend_session = ort.InferenceSession(str(debug_path), ort_options, providers=["CPUExecutionProvider"])
    session = ort.InferenceSession(str(out_path), ort_options, providers=["CPUExecutionProvider"])
    inputs, outputs = options(session.get_inputs()), options(session.get_outputs())
    assert [(x["name"], x["type"]) for x in inputs] == [("waveform", "tensor(float)"), ("pad_frames", "tensor(int64)")]
    assert [(x["name"], x["type"]) for x in outputs] == [("beat", "tensor(float)"), ("downbeat", "tensor(float)")]
    print(f"ONNX inputs: {inputs}; outputs: {outputs}", flush=True)

    pcm, full = synthetic_piece()
    sf.write(fixtures / "beat_this_fixture.wav", pcm, SAMPLE_RATE, subtype="PCM_16")
    # Verify round-trip; soundfile writes integer PCM without changing its samples.
    loaded, sr = sf.read(fixtures / "beat_this_fixture.wav", dtype="float32")
    assert sr == SAMPLE_RATE and np.array_equal(loaded, full)
    data = {"upstream_commit": UPSTREAM_COMMIT, "checkpoint_sha256": CHECKPOINT_SHA,
            "versions": {"python": sys.version.split()[0], "torch": torch.__version__,
                         "torchaudio": __import__("torchaudio").__version__, "numpy": np.__version__,
                         "onnx": onnx.__version__, "onnxruntime": ort.__version__,
                         "einops": __import__("einops").__version__,
                         "rotary_embedding_torch": __import__("rotary_embedding_torch").__version__ if hasattr(__import__("rotary_embedding_torch"), "__version__") else "0.8.9",
                         "soxr": __import__("soxr").__version__, "soundfile": sf.__version__},
            "inputs": inputs, "outputs": outputs, "fixtures": {}}
    rows = []
    postprocess = Postprocessor(type="minimal")
    # Regression facts for the Swift minimal decoder, including nonadjacent ties.
    assert np.array_equal(deduplicate_peaks([8, 9], width=1), [8.5])
    assert np.array_equal(deduplicate_peaks([8, 10], width=1), [8, 10])
    data["postprocessing"] = {"fps": 50, "max_pool_width": 7, "strict_positive_logit": True,
                              "adjacent_peak_examples": {"8,9": [8.5], "8,10": [8, 10]},
                              "downbeats": "nearest beat, then unique"}

    with torch.inference_mode():
        for name, seconds in (("short3", 3), ("short10", 10), ("full30", 30), ("seam45", 45)):
            piece = np.ascontiguousarray(full[:seconds * SAMPLE_RATE])
            spect = upstream_mel(torch.from_numpy(piece))
            frames = spect.shape[0]
            assert frames == seconds * 50 + 1
            upstream_chunks, starts = split_piece(spect, CHUNK, border_size=BORDER, avoid_short_end=True)
            if name == "short10":
                assert [len(x) for x in upstream_chunks] == [513]
            if name == "full30":
                assert frames == 1501 and starts.tolist() == [-6, 7]
            if name == "seam45":
                assert len(starts) == 2 and starts[-1] == frames - (CHUNK - BORDER)
            reference_chunks, ort_chunks, plans = [], [], []
            largest_mel = 0.0
            for index, (start, upstream_chunk) in enumerate(zip(starts, upstream_chunks)):
                start = int(start)
                first = max(start, 0)
                end = min(start + CHUNK, frames)
                left = max(0, -start)
                right = max(0, min(BORDER, start + CHUNK - frames))
                context = waveform_context(piece, first, end)
                assert len(context) == (end - first - 1) * HOP + FFT
                feeds = {"waveform": context[None], "pad_frames": np.asarray([left, right], dtype=np.int64)}
                got_mel = frontend_session.run(None, feeds)[0][0]
                expected_mel = upstream_chunk.numpy()
                assert got_mel.shape == expected_mel.shape
                mel_diff = float(np.max(np.abs(got_mel - expected_mel)))
                largest_mel = max(largest_mel, mel_diff)
                assert mel_diff < 1e-4, f"{name} chunk {index} mel diff {mel_diff}"
                # Oracle is the ORIGINAL upstream model and original rotary module.
                reference = oracle_model(upstream_chunk.unsqueeze(0))
                got_beat, got_downbeat = session.run(None, feeds)
                assert got_beat.shape == got_downbeat.shape == (1, len(upstream_chunk))
                beat_diff = float(np.max(np.abs(got_beat[0] - reference["beat"][0].numpy())))
                downbeat_diff = float(np.max(np.abs(got_downbeat[0] - reference["downbeat"][0].numpy())))
                assert max(beat_diff, downbeat_diff) < 1e-4, f"{name} chunk {index} logits {beat_diff}, {downbeat_diff}"
                print(f"{name} chunk {index} start {start}: mel max abs {mel_diff:.9g}, "
                      f"beat max abs {beat_diff:.9g}, downbeat max abs {downbeat_diff:.9g}", flush=True)
                reference_chunks.append({k: v[0] for k, v in reference.items()})
                ort_chunks.append({"beat": torch.from_numpy(got_beat[0]), "downbeat": torch.from_numpy(got_downbeat[0])})
                plans.append({"start": start, "nonzero_frame_range": [first, end],
                              "left_zero_frames": left, "right_zero_frames": right,
                              "context_samples": len(context), "transformer_frames": len(upstream_chunk),
                              "mel_max_abs_diff": mel_diff, "beat_max_abs_diff": beat_diff,
                              "downbeat_max_abs_diff": downbeat_diff})

            def aggregate(chunks):
                return aggregate_prediction(chunks, starts, frames, CHUNK, BORDER, "keep_first", "cpu")

            oracle_beat, oracle_downbeat = aggregate(reference_chunks)
            got_beat, got_downbeat = aggregate(ort_chunks)
            whole_diff = max((oracle_beat - got_beat).abs().max().item(),
                             (oracle_downbeat - got_downbeat).abs().max().item())
            assert whole_diff < 1e-4, f"{name} aggregate drift {whole_diff}"
            # Also run the real end-to-end upstream splitter and aggregator.
            from beat_this.inference import split_predict_aggregate
            official = split_predict_aggregate(spect, CHUNK, BORDER, "keep_first", oracle_model)
            assert torch.equal(oracle_beat, official["beat"])
            assert torch.equal(oracle_downbeat, official["downbeat"])
            reference_times = postprocess(oracle_beat, oracle_downbeat)
            actual_times = postprocess(got_beat, got_downbeat)
            assert all(np.array_equal(a, b) for a, b in zip(reference_times, actual_times)), f"{name} peak drift"
            beat_times, downbeat_times = reference_times
            for kind, times in (("beat", beat_times), ("downbeat", downbeat_times)):
                rows.extend((name, kind, repr(float(t)), repr(round(float(t * 50), 9))) for t in times)
            np.concatenate((oracle_beat.numpy(), oracle_downbeat.numpy())).astype("<f4").tofile(
                fixtures / f"reference_logits_{name}.f32")
            data["fixtures"][name] = {"samples": len(piece), "frames": frames, "chunk_starts": starts.tolist(),
                                      "chunks": plans, "mel_max_abs_diff": largest_mel,
                                      "aggregate_max_abs_diff": whole_diff,
                                      "beat_count": len(beat_times), "downbeat_count": len(downbeat_times)}
            print(f"{name}: {frames} frames, aggregate max abs {whole_diff:.9g}, "
                  f"{len(beat_times)} beats, {len(downbeat_times)} downbeats", flush=True)

    with (fixtures / "reference_beats.csv").open("w", newline="") as file:
        writer = csv.writer(file, lineterminator="\n")
        writer.writerow(("fixture", "kind", "time", "frame"))
        writer.writerows(rows)
    (fixtures / "beat_this_manifest.json").write_text(json.dumps(data, indent=2) + "\n")
    # Debug export is deliberately NOT shipped; the one fused graph is the only artifact.
    debug_path.unlink()
    print(f"wrote {out_path} ({out_path.stat().st_size} bytes)", flush=True)


if __name__ == "__main__":
    run()
