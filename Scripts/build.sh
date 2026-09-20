#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
DEVELOPMENT=false
INSTALL=false
for argument in "$@"; do
  case "$argument" in
    --development) DEVELOPMENT=true ;;
    --install) INSTALL=true ;;
    *) echo "Usage: $0 [--development] [--install]" >&2; exit 1 ;;
  esac
done
IDENTITY_FILE="$ROOT/.freehand-signing-identity"
if $DEVELOPMENT; then
  IDENTITY="-"
  echo "Explicit development build: ad-hoc signed, NOT notarized; macOS permissions may need re-granting." >&2
else
  IDENTITY="${FREEHAND_SIGNING_IDENTITY:-}"
  if [[ -z "$IDENTITY" && -f "$IDENTITY_FILE" ]]; then IDENTITY="$(cat "$IDENTITY_FILE")"; fi
  if [[ -z "$IDENTITY" || "$IDENTITY" == - ]]; then
    echo "Set FREEHAND_SIGNING_IDENTITY to your Apple certificate, or explicitly use --development for local testing." >&2; exit 1
  fi
  security find-identity -v -p codesigning | grep -Fq -- "$IDENTITY" || { echo "Signing identity unavailable." >&2; exit 1; }
fi
if [[ -f "$IDENTITY_FILE" && "$(cat "$IDENTITY_FILE")" != "$IDENTITY" ]]; then
  echo "Signing identity differs from this installation. Stopped to preserve permissions. See docs/DEVELOPMENT.md." >&2; exit 1
fi
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="$ROOT/.build/Free Hand.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Engine/free_hand_engine" "$APP/Contents/Resources/Scripts" "$APP/Contents/Resources/ThirdParty"
cp "$BIN/FreeHand" "$APP/Contents/MacOS/FreeHand"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp engine/pyproject.toml engine/uv.lock "$APP/Contents/Resources/Engine/"
cp engine/free_hand_engine/*.py "$APP/Contents/Resources/Engine/free_hand_engine/"
cp Scripts/setup-runtime.sh "$APP/Contents/Resources/Scripts/"
cp ThirdParty/* LICENSE NOTICE "$APP/Contents/Resources/ThirdParty/"
if [[ ! -f Resources/AppIcon.icns ]]; then swift Scripts/make-icon.swift; fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if $DEVELOPMENT; then codesign --force --sign - "$APP"
else codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"; fi
codesign --verify --strict "$APP"
INSTALLED="$ROOT/Free Hand.app"
if [[ -d "$INSTALLED" && "$IDENTITY" != - ]]; then
  REQUIREMENT="$(codesign -d -r- "$INSTALLED" 2>&1 | sed -n 's/^designated => //p')"
  [[ -n "$REQUIREMENT" ]] && codesign --verify --strict -R "=$REQUIREMENT" "$APP"
fi
if $INSTALL; then
  STAGE="$(mktemp -d "$ROOT/.build/install.XXXXXX")"
  ditto "$APP" "$STAGE/Free Hand.app"
  codesign --verify --strict "$STAGE/Free Hand.app"
  # Match the executable path, not a command-line regex: launch arguments such
  # as --capture-preview must not leave an old app running after replacement.
  installed_pids() {
    while read -r PID COMMAND; do
      if [[ "$COMMAND" == "$INSTALLED/Contents/MacOS/FreeHand" ]]; then printf '%s\n' "$PID"; fi
    done < <(ps -axo pid=,comm=)
    return 0
  }
  PIDS="$(installed_pids)"
  if [[ -n "$PIDS" ]]; then
    kill $PIDS
    for ((attempt=0; attempt<50; attempt++)); do
      if [[ -z "$(installed_pids)" ]]; then break; fi
      sleep 0.1
    done
    if [[ -n "$(installed_pids)" ]]; then echo "App is still running; install cancelled." >&2; exit 1; fi
  fi
  if [[ -d "$INSTALLED" ]]; then mv "$INSTALLED" "$STAGE/Previous Free Hand.app"; fi
  if ! mv "$STAGE/Free Hand.app" "$INSTALLED"; then
    if [[ -d "$STAGE/Previous Free Hand.app" ]]; then mv "$STAGE/Previous Free Hand.app" "$INSTALLED"; fi
    exit 1
  fi
  printf '%s\n' "$IDENTITY" > "$IDENTITY_FILE"
  echo "Installed: $INSTALLED"
else echo "Built: $APP (use --install before launching)"; fi
