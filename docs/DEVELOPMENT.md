# Development, packaging and troubleshooting

## Layout

`Sources/FreeHand` is the native app. `engine/free_hand_engine` is the Python
adapter; `engine/uv.lock` pins its dependencies and upstream Git commit.
`Tests/FreeHandTests` and `engine/tests` contain the native and pure-Python tests.
`examples/Playground` is a benign native target app. `ThirdParty` and `NOTICE`
contain all upstream attributions. `.upstream`, models, environments, app bundles,
logs and generated test output are ignored by Git.

## Build and run

```bash
uv sync --project engine --extra dev --python 3.12
swift test
uv run --project engine pytest engine/tests
uv run --project engine ruff check engine Scripts/smoke-model.py
bash Scripts/setup-runtime.sh
bash Scripts/build.sh --development --install
open "Free Hand.app"
```

The runtime installation uses `uv sync --frozen --no-dev --no-editable`, so the
installed application doesn't depend on the development environment or checkout.
The app-bundled installer gets an explicit source directory, without shell
interpolation of model input. A GUI-launched app finds uv in standard Homebrew
and system paths. The setup script refuses unsupported hardware or missing uv.

Normal inference uses the installed executable at
`~/Library/Application Support/Free Hand/engine/.venv/bin/python`. Developers may
set `FREEHAND_PYTHON` to a controlled alternative. `FREEHAND_HOME` isolates an
entire test installation. These are launch-time operator overrides, not user-task
parameters or model-controlled paths.

## Signing and identity continuity

The `.freehand-signing-identity` value `-` pins a *mode*, not a stable developer
identity. Ad-hoc code has a cdhash-based designated requirement; rebuilding code
changes it. An identity-changing ad-hoc installation now fails before stopping
or replacing the installed app. To intentionally accept a new development build,
use `--development --install --allow-adhoc-identity-change`; this explicit flag
does not reset TCC or grant authorization. Identical-identity reinstalls and
build-only runs do not require it. Unreadable signing requirements fail closed.
It never relaxes the requirement to a bundle-ID-only match or silently imports a
new certificate. The permission panel shows the exact currently running path,
version and hash so an old enabled row is not mistaken for an effective grant.

`python3 Scripts/test-build-guard.py` tests these gates with fake build/signing
tools in temporary directories; it never signs, launches or replaces the real app.
Do not re-extract a downloaded ZIP over the canonical local build while debugging
permissions. An extraction utility can attach quarantine metadata, and Launch
Services can then run a translocated copy. The diagnostic report's `bundlePath`
identifies where the process actually runs; a requested launch path is not proof.

`--development` explicitly requests an ad-hoc local developer build. This is not
notarization, and macOS permissions may have to be granted again after updates.
It is not suitable as a polished public download.

For certificate signing:

```bash
security find-identity -v -p codesigning
FREEHAND_SIGNING_IDENTITY="YOUR_CERTIFICATE_FINGERPRINT" \
  bash Scripts/build.sh --install
```

On installation the chosen identity is pinned in `.freehand-signing-identity`,
which is never committed. Subsequent builds cannot silently switch between
ad-hoc and certificate identities or between certificates. Certificate updates
must satisfy the previous installed app's designated requirement. The bundle
identifier is permanently `com.feibai.freehand`.

To intentionally migrate a *development-only* installation to your certificate,
quit Free Hand, retain a backup of the old app and identity file, then move the
identity file aside and create the new certificate-signed installation. This is
an explicit identity migration: expect to grant Accessibility/Screen Recording
again. Never reset or edit TCC databases. Notarization and public binary
distribution require your own Apple Developer credentials and are not performed
by this repository's CI.

The build script stages and verifies before replacing the canonical repository
root `Free Hand.app`; previous copies are retained under `.build/install.*`.
Do not launch `.build/Free Hand.app` or a second copy with the same bundle ID.

## Diagnosing setup

```bash
"Free Hand.app/Contents/MacOS/FreeHand" --doctor
"$HOME/Library/Application Support/Free Hand/engine/.venv/bin/python" \
  -I -m free_hand_engine doctor
```

The native doctor reports permissions for the actual installed signed app, its
bundle ID and whether the configured Python executable exists. The Python doctor
reports hardware and checkpoint installation metadata. Neither doctor output is
a full UI automation test. Worker startup performs actual file verification and
model loading.

For authorization reports, prefer launching the same app via Launch Services:

```bash
mkdir -p .build
open -n -g -W -a "$PWD/Free Hand.app" --args \
  --permission-check "$PWD/.build/permissions.json"
```

This reports current-process trust, event-posting preflight, external window-
reference read/error, and the actual executable's signing identity. It does not
read TCC databases or infer a checkbox's state. A positive unit-test fixture or
helper's authorization is never evidence that the installed app is authorized.

If model loading fails, use Repair or rerun setup. No inference path downloads
missing files silently. If a task is cancelled during an inference request, the
worker is terminated to discard stale responses: use Load before the next task.
If uv is unavailable in the GUI environment, install it in a standard path or
run setup in the shell.

Accessibility and Screen Recording must be enabled by the user in macOS System
Settings. The app does not bypass denied permission. If the shortcut is
unavailable despite permission, quit and reopen the canonical app and check
whether another utility intercepted the configured shortcut. The new default is
Control–Shift–Space. The button/menu conversation entry and hotkey registration
do not require Accessibility; only executing a task does. Settings offer alternate
combinations, a disable option and explicit registration/conflict diagnostics.

## Reproducible test scopes

`swift test` exercises validators, permissions-independent controller helpers,
field focus, stale observations, literal text, Unicode, cancellation and timeout
semantics. One local perception test uses Apple Vision on a generated text image,
not a screenshot of user content. Real-model tests are opt-in.

```bash
uv run --project engine python Scripts/smoke-model.py
FREEHAND_LIVE_TESTS=1 FREEHAND_PYTHON="$PWD/engine/.venv/bin/python" \
  swift test --filter LiveEngineTests
```

These tests run the real checkpoint/Metal backend but operate on synthetic screen
rows. They do not grant macOS permissions or prove arbitrary application control.
Playground acceptance needs a user-approved application permission and one-time
action approvals. See VALIDATION.md for the checklist and actual execution log.

To capture the app's own setup view without capturing the desktop, quit it first,
then run:

```bash
"Free Hand.app/Contents/MacOS/FreeHand" --capture-preview "$PWD/.build/setup-preview.png"
```

Only the app's own NSView is rendered. This flag does not take a system screenshot.

The packaged entry regression can click the app's real native launch button,
close/reopen its conversation and check draft preservation without sending any
input to another application. Quit the current copy before running it:

```bash
open "Free Hand.app" --args --ui-smoke-test "$PWD/.build/entry-smoke.json"
```

It records only booleans and operational diagnostics (no target list, user draft,
or screen contents), and renders the app's own conversation to a sibling PNG.
`HotkeyTests` also exercises native registration, conflicts, unregistration and
pressed/released events dispatched only to the test app's event target. This is
not a claim that a physical keypress passes through every external remapper.

## Removing the installation

Quit the app and remove its bundle. The runtime and checkpoint are under
`~/Library/Application Support/Free Hand/`; deleting that directory removes both.
uv caches and its managed Python may be shared with other projects; do not delete
them blindly. Remove Free Hand's permission entries through System Settings when
appropriate. The app installs no launch daemon, login item or privileged helper.
