# Free Hand development

Free Hand is a local-first macOS application, not Third Hand or UserBox.

- Read README.md and docs/ARCHITECTURE.md before changing the runtime.
- Run `swift test` and `uv run --project engine --extra dev pytest engine/tests`.
- Never claim real desktop control from fixture or model-only tests.
- No cloud fallback, API keys, listening sockets, shell execution tool, or generated commands.
- Never read or alter TCC databases. Permissions must be granted by the user.
- Preserve the application bundle ID and pinned signing identity on updates.
- Development ad-hoc builds require the explicit `--development` flag and are not distribution builds.
- The only runnable installation is repository-root `Free Hand.app`. Do not launch build-directory copies.
- Do not store prompts, screen contents, typed text, or private application values in logs.
- Preserve third-party license notices and pinned source/model provenance.
- Stop, timeout, failed verification, and blocked are not successful completion.
