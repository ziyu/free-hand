# Validation record

## 0.1.1 — conversation entry and shortcut fix

Local validation: **2026-09-20**, Apple Silicon / arm64, macOS 27.0 (26A428),
Swift 6.3.3, Python 3.12.9. App deployment target remains macOS 14.

| Check | Actual result / scope |
| --- | --- |
| `swift test` | 81 discovered: 79 passed, 2 explicitly opt-in model tests skipped, 0 failures |
| Python engine tests | 44 passed; engine protocol unchanged by the entry fix |
| Real local-engine round-trip/reload | Separately rerun with `FREEHAND_LIVE_TESTS=1`: 1 passed; actual MLX, no desktop input |
| New native conversation tests | Real setup button opens the window without a loaded engine; close/reopen reuses the window and preserves the draft |
| Target/run state tests | Own app excluded, PID reuse rejected, missing target not silently replaced, no double submission, late callbacks cannot change a newer turn |
| Shortcut lifecycle tests | Default/saved choices, disabled state, system conflict, registration failure/retry, press-repeat suppression, stale-event rejection |
| Actual Carbon registration test | Exclusive duplicate registration rejected; after unregistering, the same chord is available again |
| Actual Carbon callback test | Pressed/released events sent to the test app's own event target reached the callback; no desktop keystrokes injected |
| Release app | Built, installed at canonical repository-root path, and signature verified |
| Packaged-app button test | Native `NSButton.performClick` opened the real conversation; draft preservation and window reuse passed |
| Installed app diagnostics | Version 0.1.1, bundle ID `com.feibai.freehand`, local engine `ready` |
| Installed shortcut state | Control–Shift–Space registered successfully despite Accessibility being disabled |
| Installed permissions | Accessibility **false**, Screen Recording **false** at validation time |
| Other-app desktop input | **Not executed**; permission was not bypassed |
| Physical keyboard/remapper path | **Not verified**; native registration/callback checks are not a physical-keypress test |
| Apple notarization | **Not performed**; this is an explicitly ad-hoc signed developer build |

The packaged application was launched with `--ui-smoke-test`, which clicks the
same real native button as the user. It does not directly invoke a fake dialogue
or make a model produce a desired answer. The recorded booleans were:

```json
{
  "buttonFound": true,
  "buttonEnabled": true,
  "conversationOpened": true,
  "sameWindowReused": true,
  "draftPreserved": true,
  "noTaskStarted": true,
  "selfExcludedFromTargets": true,
  "shortcutRegistered": true,
  "accessibility": false,
  "engine": "ready"
}
```

Both setup and conversation screenshots were rendered from the application's
own NSView, not by capturing the user's desktop. The hotkey was registered by the
real installed application; no external app's keybinding was modified.

## Model and automation limitations

The runtime uses MLX 0.32.2 / `mlx-metal` 0.32.2, float16, with the checkpoint
`aac6fef/laya-multilingual-mlx` at revision
`ba40c87fcb357f1643d04d71323af9cdc3b9e591`. Its fixed weight SHA-256 is
`7fc5834af4d8fdfb268d272a9d1a66e5819a0daac98241651c4c888cc43adff1`.
Exact dependency versions are in `engine/uv.lock`.

The initial development encountered model-only accuracy failures: wrong target
selection, abstention despite available controls, and premature completion.
A four-case smoke test passed at an intermediate revision but regressed after
matching production ordering/state more closely. That intermediate result is
**not** the final product's accuracy result or a reliability guarantee.

Explicit, unambiguous click/type/search commands therefore use a deterministic
observed-control path before inference. They retain all input validation,
approval and post-action checks. These command tests are **not model accuracy
tests**. The real-model transport test exercises the Swift → Python → MLX round
trip and worker reload independently of literal command routing.

`Scripts/smoke-model.py` and `testExperimentalModelOnlyAccuracy` remain executable
diagnostics with known failures; the shortcut/conversation fix does not claim to
resolve model planning. Open-ended planning should be treated as experimental.

```bash
# Controller/entry tests and pure engine protocol tests.
swift test
uv run --project engine --extra dev pytest engine/tests

# Explicitly run the real local-engine transport/reload check.
FREEHAND_LIVE_TESTS=1 swift test --filter testRealModelRoundTripAndReload

# Retained experimental accuracy diagnostics; may exit nonzero.
uv run --project engine python Scripts/smoke-model.py
FREEHAND_EXPERIMENTAL_ACCURACY=1 swift test --filter testExperimentalModelOnlyAccuracy
```

## Remaining user-approved acceptance

Open the conversation using the new button. Enable Accessibility for the
repository-root **Free Hand.app** via the inline button, select the Playground
or another intended app, and send an explicit instruction. No task is queued by
permission changes; the user must press Send again.

Confirm single text entry, single click, search submission and their visible
results in Playground with per-action review enabled. Also check a physical
shortcut, rejecting an approval, changing apps during planning, closing the
target application, and stopping a running task. Actual third-party application
control and sensitive workflows are not certified by the entry tests.
