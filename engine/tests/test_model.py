import json

import pytest

from free_hand_engine.model import MODEL_ID, MODEL_REVISION, WEIGHTS_SHA256, model_dir, sha256, verify


def test_model_paths_respect_explicit_test_home(monkeypatch, tmp_path):
    monkeypatch.setenv("FREEHAND_HOME", str(tmp_path))
    assert model_dir() == tmp_path / "models" / MODEL_REVISION


def test_sha256_is_streamed_and_deterministic(tmp_path):
    path = tmp_path / "bytes"
    path.write_bytes(b"abc")
    assert sha256(path) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"


def test_missing_manifest_fails_closed(tmp_path):
    with pytest.raises(FileNotFoundError):
        verify(tmp_path)


@pytest.mark.parametrize("manifest", [
    {"model": "other", "revision": MODEL_REVISION},
    {"model": MODEL_ID, "revision": "main"},
    {"model": MODEL_ID, "revision": MODEL_REVISION, "files": {}},
    {"model": MODEL_ID, "revision": MODEL_REVISION, "files": {"model.safetensors": WEIGHTS_SHA256}},
])
def test_unpinned_or_incomplete_manifests_fail(manifest, tmp_path):
    (tmp_path / "freehand-manifest.json").write_text(json.dumps(manifest))
    with pytest.raises(ValueError):
        verify(tmp_path)
