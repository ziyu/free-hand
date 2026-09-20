# Free Hand architecture

## Product boundary

Free Hand is a macOS menu-bar assistant for short, supervised tasks in the
frontmost application. It is not a cloud service, generic agent hosting platform,
LLM writing assistant, isolated desktop, or background input virtualization layer.
The first release targets Apple Silicon and macOS 14+.

Third Hand supplies the native control foundation. Laya-MLX supplies the typed
decision model. Free Hand owns the product shell, private process protocol,
model lifecycle, bounded decision adapter, review policy, and result semantics.

```text
Start conversation button / menu / optional Control–Shift–Space
    ↓ permission-independent entry; select an explicit application identity
Native task conversation (draft, app picker, in-memory results)
    ↓ explicit user goal
TaskRunner ──────── Stop / timeout / focus changed → cancel, no further input
    ↓
Accessibility snapshot → optional on-device Vision OCR
    ↓ rank observed controls, remove secure fields
DecisionClient
    ├ strict literal command + unambiguous observed target → same approval/validator
    └ experimental semantic path: choose operation, then an offered target
    ↓ extract only supplied text
LocalEngine (Swift Process)
    ⇅ bounded JSONL over private stdin/stdout, unique request IDs
free_hand_engine (Python, no input capabilities)
    ↓ verify complete task/options fit the real tokenizer budget
Pinned multilingual Laya model → MLX → Metal
    ↓ finite probabilities and an allowed choice, or explicit error
SafetyPolicy → nonactivating “Allow once” panel
    ↓ cancellation/focus/window/control checks repeated after approval
InputController / Accessibility actions
    ↓ observe again and verify the action
Repeat, or separate completion question on a fresh observation
```

## Runtime ownership

The native application is the only component that can send input. The model
process receives text-only state and fixed typed questions, and cannot call
desktop APIs, execute model-produced code, select an executable, or invent new
tool types. Its answers are suggestions until the native validator and review
policy allow a specific action.

Explicit literal commands are parsed before inference by `LiteralCommand`.
An exact unique click label, unique/focused text field, or unique search field
does not require the classifier to re-interpret the user's instruction. No
model refusal is overridden after the fact. Ambiguity returns control to the
semantic path; all literal actions retain identical review and execution checks.
Known-empty field values are preserved rather than represented as missing data.
The strict search state machine fills, focuses, submits once, then requests a
fresh completion check; it never repeatedly submits. A single literal command
ends after its effect is verified, without asking the model for an extra action.

One app instance owns one resident worker and allows one model request at a time.
The worker loads once, not once per decision. A generation token prevents old
process callbacks from being applied to a replacement worker. Each request has
a fresh UUID; response IDs must match outstanding requests exactly. EOF,
invalid frames, timeouts, model errors and cancellation cannot authorize input.
Startup has a 90-second deadline; requests have a 20-second deadline. An
unresponsive worker is terminated, then killed after a grace period if needed.

There is no HTTP server, socket listener, provider URL, API key, or remote model
fallback. Runtime flags disable Hugging Face online behavior and telemetry;
models are loaded from an already verified local directory. This is application
behavior, not an OS-enforced network sandbox. Offline mode does not make a
compromised dependency harmless.

## Protocol v1

Requests and responses are UTF-8 newline-delimited JSON. `predict`, `ping`, and
`shutdown` are the only methods. Input frames are limited to 128 KiB, output
frames to 64 KiB. An oversized input closes the stream instead of draining an
unbounded payload. Requests carry at most three questions, up to 12 choices per
question, and up to 160 observation rows. The native adapter currently sends
one question per call and at most 16 rows.

An optional `option_order` array must contain exactly the offered keys, with no
duplicates. The native client sends it explicitly so Swift/Python dictionary
sorting cannot silently change the model's option order. No fallback is removed,
and the adapter never retries permutations until it obtains a desired answer.
Observation rows are rendered as bounded textual descriptions, including whether
an editable field is actually empty, rather than leaving absent values ambiguous.

```json
{
  "version": 1,
  "id": "unique-request-id",
  "method": "predict",
  "params": {
    "state": {
      "task": "Click Settings",
      "app": "Playground",
      "elements": [{"id": "1", "role": "button", "label": "Settings"}]
    },
    "questions": {
      "target": {
        "type": "choice",
        "instructions": "Which control is the target of this action?",
        "criteria": {"1": "Settings", "__none__": "none of these controls"}
      }
    }
  }
}
```

Responses carry `result` or a redacted `error` and echo the ID. A startup `ready`
event precedes requests. Choice outputs must refer to offered options and have
finite normalized distributions. Boolean outputs must be finite numbers in
`[0,1]`. Exceptions never echo the goal, screen, typed text, or malformed input.

## Adapting a small typed model

The cloud-oriented upstream could offer hundreds of controls and send a much
larger state. Simply replacing its URL would silently degrade local inference:
Laya's question construction has a separate head budget and can truncate both
instructions and options before truncating the state.

Free Hand therefore asks for the operation first, then asks only for the target
of that operation. Target questions include four ranked observed controls plus
an explicit “none” choice. Ranking considers goal/label matches, focus, evidence,
and text fields, with deterministic tie-breaking. No selected ID can escape the
shortlist or target-role constraints.

Before inference the Python adapter counts actual tokenizer output. An
instruction or option that would be truncated is rejected. The whole goal must
fit; it is not silently rewritten. Recent attempts and screen rows are packed
within the remaining budget and omissions are counted. Long/dense screens,
ambiguous labels, and complex tasks can therefore produce an explicit refusal.
The real-model smoke test checks our prefix accounting against the pinned
upstream implementation.

The 0.35 selected-choice threshold is an abstention policy, **not** an accuracy
claim. Likewise the 0.85 completion threshold is a product policy, not proof of
task success. Model confidence needs broader real-world calibration.

## Execution, approval, and verification

Opening the conversation requires neither Accessibility nor a loaded model.
Application choices contain PID, bundle ID and launch date, without reading UI
contents. On send, the selected process is re-resolved and its identity checked;
permissions and engine state are checked again. Free Hand and protected system
processes are excluded. Expired selections are not silently switched during
refresh. The target is captured from this explicit selection, never from the
frontmost Free Hand conversation window. Our windows hide before execution;
opening them during a task synchronously cancels input before activation.
The runner checks the frontmost process and target window before observation,
after model latency, after approval, and immediately before input. Targeted
actions re-observe and rematch the control; changed or ambiguous controls are
not blindly clicked. Non-targeted keyboard actions also check the fresh snapshot.
Text input must establish and retain field focus. Password/secure accessibility
fields are excluded; Return is blocked when a secure native field has focus.

The approval panel does not activate Free Hand or take keyboard focus. Each
approval is consumed for one specific action, not retained across retries.
Default mode asks about every mutation. Optional navigation auto mode uses
heuristic label screening and must not be treated as a permission boundary.

Action verification uses changed observations and exact field values where
available. Completion uses a new observation and a separate question that does
not invite another action. A failed confirmation or exhausted recovery throws
a stopped/not-completed outcome. This corrects upstream paths that could show
success after inconclusive verification. A model can still misjudge visual
evidence: the user remains the final authority.

There are 30 action slots, 40 planning iterations and a three-minute task
deadline including review. Validation and settling may take multiple observations
inside one planning iteration. Repeated ineffective actions are stopped. OCR is a
single explicit recovery stage, requires Screen Recording permission, and does
not turn every text label into a proven interactive control.

## Lifecycle and storage

The app bundles engine source, lockfile, licenses and setup script, not Python
or model weights. Setup copies the engine into Application Support, provisions
Python 3.12 via uv, installs pinned dependencies, explicitly downloads a pinned
checkpoint, verifies its fixed weight SHA-256, and records a file manifest.
Worker startup verifies the manifest again and never repairs itself online.

App preferences persist review mode and the selected shortcut. Task goals,
observations, input text and screenshots are not logged. The conversation holds
a draft and at most 40 instruction/result turns in memory; each has a run ID to
reject late callbacks. Opening, closing and reusing the window preserves the
draft, while failed prerequisite checks never enqueue a task. Conversation
messages are not implicitly supplied as the authority for a later task.
OSLog receives operational metadata.
Model and package caches remain until the user removes them.

## Intended extensions

Additional execution backends should keep the observation/action/approval
contracts rather than reuse foreground CGEvents for hidden desktop claims.
Broader autonomous navigation needs a representative desktop benchmark, better
target retrieval, explicit application-specific safety policies, and calibrated
completion checks. These are not claimed as implemented in v0.1.1.

## Hotkey lifecycle

`HotkeyManager` owns a permission-independent native Carbon registration, with
enabled system symbolic bindings checked first and exclusive-registration errors
displayed in settings. It registers only on launch or an explicit selection/retry,
not on the Accessibility polling timer. A new selection unregisters the old
binding; a generation ID rejects queued old events. Press/release tracking stops
key autorepeat from immediately cancelling a newly opened conversation. The UI
distinguishes registration status from the timestamp of an actually received
event. There is no universal detection of third-party event-tap interception;
the primary button/menu entry is always available.
