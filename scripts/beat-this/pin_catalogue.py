#!/usr/bin/env python3
"""Points App/Models/ModelCatalog.swift at the uploaded Beat This! model and switches the helper on.

Usage: pin_catalogue.py CATALOGUE.swift HF_USER REVISION MODELS_DIR

Rewrites every line that carries a `// beat-this-models:<marker>` comment: the owner, the revision, the size and SHA-256
of beat_this.onnx in MODELS_DIR, and the flag that lists the helper in the catalogue. Called by
scripts/publish-beat-this.sh after the upload.
"""
import hashlib
import pathlib
import re
import sys

MARKERS = ("published", "owner", "revision", "size", "sha")


def pin(text, user, revision, models):
    path = pathlib.Path(models) / "beat_this.onnx"
    sha, size = hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_size
    lines = {
        "published": "private static let beatThisPublished = true",
        "owner": f'private static let beatThisOwner = "{user}"',
        "revision": f'private static let beatThisRevision = "{revision}"',
        "size": f"byteSize: {size:_},",
        "sha": f'sha256: "{sha}",',
    }
    for marker in MARKERS:
        pattern = re.compile(r"^([ \t]*)\S.*// beat-this-models:" + re.escape(marker) + r".*$", re.M)
        if len(pattern.findall(text)) != 1:
            raise SystemExit(f"expected exactly one line marked beat-this-models:{marker}")
        text = pattern.sub(lambda m: m.group(1) + lines[marker] + " // beat-this-models:" + marker, text)
    return text


if __name__ == "__main__":
    catalogue, user, revision, models = sys.argv[1:5]
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise SystemExit(f"{revision!r} is not a 40-character commit hash")
    path = pathlib.Path(catalogue)
    path.write_text(pin(path.read_text(), user, revision, models))
