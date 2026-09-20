#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$ROOT/engine}"
HOME_DIR="${FREEHAND_HOME:-$HOME/Library/Application Support/Free Hand}"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "Free Hand requires Apple Silicon and macOS 14 or newer." >&2; exit 1
fi
UV="$(command -v uv || true)"
if [[ -z "$UV" ]]; then
  echo "uv is required. Install uv, then run this script again. See README.md." >&2; exit 1
fi
[[ -f "$SOURCE/uv.lock" ]] || { echo "Missing engine lockfile." >&2; exit 1; }
mkdir -p "$HOME_DIR/engine"
chmod 700 "$HOME_DIR"
LOCK="$HOME_DIR/.setup-lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "Another installation is running. If it was interrupted, remove $LOCK after checking no installer remains." >&2
  exit 1
fi
CHILD=""
cleanup() {
  if [[ -n "$CHILD" ]]; then kill "$CHILD" 2>/dev/null || true; fi
  rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
run_child() {
  "$@" &
  CHILD=$!
  wait "$CHILD"
  CHILD=""
}
# Copy only source/metadata; never copy another environment, cache, or model weights.
cp "$SOURCE/pyproject.toml" "$SOURCE/uv.lock" "$HOME_DIR/engine/"
mkdir -p "$HOME_DIR/engine/free_hand_engine"
cp "$SOURCE"/free_hand_engine/*.py "$HOME_DIR/engine/free_hand_engine/"
export HF_HUB_DISABLE_TELEMETRY=1 HF_HUB_DISABLE_IMPLICIT_TOKEN=1
run_child "$UV" sync --project "$HOME_DIR/engine" --frozen --no-dev --no-editable --reinstall-package free-hand-engine --python 3.12
run_child "$HOME_DIR/engine/.venv/bin/python" -I -u -m free_hand_engine download
run_child "$HOME_DIR/engine/.venv/bin/python" -I -m free_hand_engine doctor
