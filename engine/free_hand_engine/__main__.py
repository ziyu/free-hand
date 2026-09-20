import argparse
import contextlib
import json
import os
import platform
import sys

from .model import MODEL_ID, MODEL_REVISION, download, model_dir, verify


def main() -> int:
    parser = argparse.ArgumentParser(description="Free Hand local decision engine")
    parser.add_argument("command", choices=["download", "serve", "doctor"])
    args = parser.parse_args()
    if args.command == "download":
        print("Downloading the pinned multilingual Laya checkpoint; verifying SHA-256.", flush=True)
        download()
        print("Model ready. Future inference runs offline.", flush=True)
        return 0
    if args.command == "doctor":
        result = {"platform": platform.system(), "architecture": platform.machine(),
                  "python": platform.python_version(), "model": MODEL_ID, "revision": MODEL_REVISION,
                  "installed": (model_dir() / "freehand-manifest.json").is_file()}
        print(json.dumps(result, indent=2))
        return 0 if result["installed"] else 1
    from .protocol import emit, serve

    wire = sys.stdout.buffer
    os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1",
                      HF_HUB_DISABLE_IMPLICIT_TOKEN="1", TOKENIZERS_PARALLELISM="false")
    try:
        # Keep third-party prints off the framing channel.
        with contextlib.redirect_stdout(sys.stderr):
            if platform.system() != "Darwin" or platform.machine() != "arm64":
                raise RuntimeError("Apple Silicon is required.")
            verify(model_dir())
            import laya_mlx

            agent = laya_mlx.load(str(model_dir()), dtype="float16", batch_size=3)
        serve(agent, sys.stdin.buffer, wire)
        return 0
    except Exception:
        emit(wire, {"version": 1, "event": "failed", "error": {
            "code": "E_START", "message": "Local model could not load. Run doctor or reinstall the engine."}})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
