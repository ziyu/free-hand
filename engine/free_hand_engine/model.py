"""Explicit, pinned download path. Normal inference never downloads a model."""

import hashlib
import json
import os
from pathlib import Path

MODEL_ID = "aac6fef/laya-multilingual-mlx"
MODEL_REVISION = "ba40c87fcb357f1643d04d71323af9cdc3b9e591"
WEIGHTS_SHA256 = "7fc5834af4d8fdfb268d272a9d1a66e5819a0daac98241651c4c888cc43adff1"


def support_dir() -> Path:
    return Path(os.environ.get("FREEHAND_HOME", Path.home() / "Library/Application Support/Free Hand"))


def model_dir() -> Path:
    return support_dir() / "models" / MODEL_REVISION


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download() -> Path:
    from huggingface_hub import snapshot_download

    dest = model_dir()
    snapshot_download(repo_id=MODEL_ID, revision=MODEL_REVISION, local_dir=dest, token=False)
    if sha256(dest / "model.safetensors") != WEIGHTS_SHA256:
        raise ValueError("Model checksum mismatch. The checkpoint will not be used.")
    # Record every inference input, not just weights. No mutable 'main' revision.
    files = {str(p.relative_to(dest)): sha256(p) for p in sorted(dest.rglob("*"))
             if p.is_file() and ".cache" not in p.parts and not p.name.startswith("freehand-manifest.")}
    manifest = {"model": MODEL_ID, "revision": MODEL_REVISION, "files": files}
    temporary = dest / "freehand-manifest.tmp"
    temporary.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    temporary.replace(dest / "freehand-manifest.json")
    return dest


def verify(path: Path) -> None:
    manifest = json.loads((path / "freehand-manifest.json").read_text(encoding="utf-8"))
    if manifest.get("model") != MODEL_ID or manifest.get("revision") != MODEL_REVISION:
        raise ValueError("Unexpected model provenance. Reinstall the local engine.")
    files = manifest.get("files", {})
    required = {"model.safetensors", "rl_agent_config.json", "encoder/config.json", "tokenizer/tokenizer.json"}
    if not isinstance(files, dict) or not required.issubset(files):
        raise ValueError("Incomplete model manifest.")
    if files["model.safetensors"] != WEIGHTS_SHA256:
        raise ValueError("Unexpected model weight checksum.")
    for relative, expected in files.items():
        candidate = path / relative
        if not candidate.resolve().is_relative_to(path.resolve()) or not candidate.is_file():
            raise ValueError("Invalid model manifest path.")
        if sha256(candidate) != expected:
            raise ValueError("Model integrity check failed. Reinstall the local engine.")
