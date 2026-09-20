# Security boundaries and reporting

Free Hand can control applications with the privileges the user grants through
macOS Accessibility. It is not sandboxed from the current desktop. Use the
default per-action review and only grant access on a trusted machine.

Local inference protects against intentionally sending desktop content to a
remote model provider. It does not protect against compromised dependencies,
malicious custom widgets, prompt injection in screen text, or an incorrect model
prediction. Auto-navigation risk classification is heuristic, not authorization.

Never assume the model has made a sensitive operation safe. Review all purchases,
deletions, transmissions, account changes, terminal input and permission prompts
yourself. Quoted commands may be entered only as explicitly supplied text after
approval; the model has no command-generation or shell-execution tool.

The application validates target IDs, supported action types, focused windows,
stale observations, finite output probabilities, context budgets and bounded
IPC. Cancellation invalidates pending work. Secure native fields are omitted
from accessibility state; OCR fallback should not be used on sensitive windows.
No application logs intentionally contain goals, screenshots, UI values or typed
text. Application names in the in-memory session list are not written to disk.

For a suspected vulnerability, avoid public reports containing private screen
data, credentials, or a working exploit against third-party applications. Use
GitHub's private vulnerability reporting when enabled, or contact the repository
owner privately. Include the commit, macOS version, mode, and a synthetic
reproduction using the Playground where possible.
