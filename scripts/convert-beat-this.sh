#!/bin/zsh
# Rebuild the fused Beat This! ONNX model and its deterministic upstream-reference fixtures.
# Requires uv, network access and Intel macOS. Never run at app runtime.
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

root="${0:A:h:h}"
work="$root/build/beat-this"
model="$root/build/models/beat_this.onnx"
fixtures="$root/Tests/Fixtures/BeatThis"
commit=b95c8ab0c58c2d9fcfd40508ae8dffbc05ac4f5c
checkpoint_sha=8c328b45f59d8dd3dff219253ff6a8d6482be57d0133a29140e2febbf8eb8331
checkpoint_url=https://cloud.cp.jku.at/public.php/dav/files/7ik4RrBKTS273gp/final0.ckpt
python="$work/venv/bin/python"

mkdir -p "$work" "$root/build/models" "$fixtures"
if [[ ! -x "$python" ]]; then
  uv venv --clear --python 3.11 "$work/venv" >/dev/null
  uv pip install --python "$python" 'torch==2.2.2' 'torchaudio==2.2.2' 'numpy==1.26.4' \
    'onnx==1.16.2' 'onnxruntime==1.19.2' 'einops==0.8.1' \
    'rotary-embedding-torch==0.8.9' 'soxr==1.0.0' 'soundfile==0.13.1' >/dev/null
fi
if [[ ! -d "$work/src/.git" ]]; then git clone -q https://github.com/CPJKU/beat_this "$work/src"; fi
git -C "$work/src" checkout -q "$commit"
[[ "$(git -C "$work/src" rev-parse HEAD)" == "$commit" ]] || { echo 'upstream commit mismatch' >&2; exit 1; }

checkpoint="$work/final0.ckpt"
if [[ ! -f "$checkpoint" || "$(shasum -a 256 "$checkpoint" | cut -d' ' -f1)" != "$checkpoint_sha" ]]; then
  curl -fL --retry 3 "$checkpoint_url" -o "$checkpoint.part"
  mv "$checkpoint.part" "$checkpoint"
fi
[[ "$(shasum -a 256 "$checkpoint" | cut -d' ' -f1)" == "$checkpoint_sha" ]] || { echo 'checkpoint checksum mismatch' >&2; exit 1; }

rm -f "$model"
# A model that failed any parity check must never be left behind for scripts/publish-beat-this.sh to upload.
"$python" "$root/scripts/beat-this/convert_beat_this.py" "$work/src" "$checkpoint" "$model" "$fixtures" \
  || { rm -f "$model"; echo 'conversion or parity check failed; beat_this.onnx removed' >&2; exit 1; }
[[ -f "$model" ]] || { echo 'beat_this.onnx was not written' >&2; exit 1; }
echo "beat_this.onnx  $(stat -f%z "$model") bytes  sha256 $(shasum -a 256 "$model" | cut -d' ' -f1)"
