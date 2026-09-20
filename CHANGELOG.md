# Changelog

## 0.1.2

- Replaced the single Accessibility boolean with same-process evidence: the
  nonprompting trust query, a bounded external-window-reference read, and event
  synthesis preflight. Actual API denial overrides cached positive state; actual
  read access alone cannot authorize input.
- Refreshed authorization on app activation, return from System Settings, wake,
  target changes, and a common-run-loop timer. Submission, runner startup, and
  input execution share the same decision rules; changes never auto-send a draft.
- Replaced “you haven't enabled Accessibility” with effective-process diagnostics.
  Added **重新检测**, **连接当前版本**, and exact running-app path/signature details.
- Added a Launch Services-compatible `--permission-check <report.json>` mode and
  accurate ad-hoc build-identity warnings. Kept existing bundle ID/signing mode;
  no TCC reset, certificate change, or permission bypass is performed.

## 0.1.1

- Added an always-available **开始对话** button, menu entry and reusable native task
  conversation window with app selection, draft retention, send and result history.
- Decoupled opening the interface from Accessibility and model readiness. Failed
  prerequisites preserve the draft and never silently queue an action.
- Replaced the permission-gated global event tap with native hotkey registration.
  Default: **Control–Shift–Space**. Added alternate chords, disable/retry controls,
  system/exclusive-registration conflict messages and last-received diagnostics.
- Captured the explicitly selected app by PID, bundle ID and launch date instead
  of accidentally using Free Hand as the frontmost target after clicking a button.
- Cancelled active input before bringing conversation/settings forward, preserved
  existing approval/focus checks, and rejected late updates to completed turns.
- Updated installation to stop the exact previous executable even when it was
  launched with diagnostic arguments.

The language-model planning path remains experimental. This release fixes entry
and interaction usability, not all model accuracy or third-party application
compatibility issues. It remains a local developer build without Apple notarization.
