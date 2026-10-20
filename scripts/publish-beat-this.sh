#!/bin/zsh
# Uploads the converted Beat This! model to your Hugging Face account and pins the catalogue to what was uploaded.
#   <user>/beat-this-onnx   beat_this.onnx  MIT
# The repository gets the model, the licence text, the attribution notice and a model card. It stays public and ungated.
# Until this has run, the catalogue does not list Beat This!, so the app never offers a download that does not exist.
#
# Run scripts/convert-beat-this.sh first. Then log in once with a token that can write (huggingface.co/settings/tokens):
#   uvx --from huggingface_hub hf auth login
# Usage: scripts/publish-beat-this.sh HF_USERNAME [--dry-run]
#   --dry-run  stages the repository under build/beat-this/publish and prints what would happen; uploads and edits nothing.
set -euo pipefail

root="${0:A:h:h}"
user="${1:?usage: scripts/publish-beat-this.sh HF_USERNAME [--dry-run]}"
dry=false; [[ "${2:-}" == "--dry-run" ]] && dry=true
models="$root/build/models"
name=beat-this-onnx
stage="$root/build/beat-this/publish/$name"
catalogue="$root/App/Models/ModelCatalog.swift"
licenses="$root/App/Resources/Licenses"
hfcli() { if whence -p hf >/dev/null; then command hf "$@"; else uvx --from huggingface_hub hf "$@"; fi }

[[ -f "$models/beat_this.onnx" ]] || { echo "$models/beat_this.onnx is missing; run scripts/convert-beat-this.sh" >&2; exit 1; }
rm -rf "$stage" && mkdir -p "$stage"
cp "$models/beat_this.onnx" "$stage/beat_this.onnx"
cp "$licenses/MIT-BeatThis.txt" "$stage/LICENSE"
cp "$licenses/BeatThisNotice.md" "$stage/NOTICE.md"
{
  echo "---"
  echo "license: mit"
  echo "library_name: onnxruntime"
  echo "tags: [onnx, onnxruntime, beat-tracking, downbeat-tracking, music-information-retrieval, audio-to-midi]"
  echo "---"
  echo
  cat "$root/scripts/beat-this/cards/beat-this-onnx.md"
  echo
  echo "See NOTICE.md for the attribution and the changes made, and LICENSE for the licence text."
} > "$stage/README.md"

if $dry; then
  echo "dry run: staged"; find "$stage" -type f | sort | sed "s|$root/||"
  echo "beat_this.onnx  $(stat -f%z "$models/beat_this.onnx") bytes  sha256 $(shasum -a 256 "$models/beat_this.onnx" | cut -d' ' -f1)"
  echo "would create $user/$name, upload the staged files, read back the revision, download beat_this.onnx from it and compare, then pin $catalogue"
  exit 0
fi

revision() { curl -fsSL "https://huggingface.co/api/models/$1" | python3 -c "import sys, json; print(json.load(sys.stdin)['sha'])"; }
hfcli repos create "$user/$name" --repo-type model --public --exist-ok >/dev/null
hfcli upload "$user/$name" "$stage" . --repo-type model --commit-message "Publish $name" >/dev/null
rev="$(revision "$user/$name")"
echo "$name pinned at $rev"

# Download the file back from its pinned revision, exactly as the app will, and compare.
url="https://huggingface.co/$user/$name/resolve/$rev/beat_this.onnx"
tmp="$(mktemp)"
curl -fL --retry 3 -s "$url" -o "$tmp"
if [[ "$(shasum -a 256 "$tmp" | cut -d' ' -f1)" != "$(shasum -a 256 "$models/beat_this.onnx" | cut -d' ' -f1)" ]]; then
  echo "downloaded beat_this.onnx differs from the file that was uploaded" >&2; rm -f "$tmp"; exit 1
fi
rm -f "$tmp"; echo "beat_this.onnx downloads intact from $url"

"$root/scripts/beat-this/pin_catalogue.py" "$catalogue" "$user" "$rev" "$models"
echo "ModelCatalog.swift now lists $user/$name at $rev. Run the tests and commit it."
