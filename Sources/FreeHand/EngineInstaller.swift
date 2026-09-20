import Foundation

@MainActor
final class EngineInstaller: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var message = "One-time download. No API key or account required."
    private var process: Process?
    private var output: Pipe?
    private var waiter: CheckedContinuation<Void, Error>?

    func install() async throws {
        guard !running else { return }
        guard let resources = Bundle.main.resourceURL else {
            throw EngineError(code: "E_BUNDLE", message: "Run the built Free Hand.app to install the engine.")
        }
        let script = resources.appendingPathComponent("Scripts/setup-runtime.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw EngineError(code: "E_BUNDLE", message: "Installer is missing from the app bundle. Rebuild the app.")
        }
        running = true
        message = "Installing isolated Python dependencies and downloading the pinned model…"
        defer { running = false }
        let child = Process(), pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: "/bin/bash")
        child.arguments = [script.path, resources.appendingPathComponent("Engine").path]
        child.environment = ["HOME": NSHomeDirectory(), "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "TMPDIR": NSTemporaryDirectory(), "FREEHAND_HOME": EnginePaths.home.path]
        child.standardOutput = pipe; child.standardError = pipe
        output = pipe; process = child
        // Installer output is deliberately not persisted. Display stages rather than raw package errors.
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                if text.contains("Downloading the pinned") { self?.message = "Downloading multilingual model and verifying its checksum…" }
                if text.contains("Model ready") { self?.message = "Model installed. Loading local inference…" }
            }
        }
        child.terminationHandler = { [weak self] child in
            Task { @MainActor in
                guard let self else { return }
                let waiter = self.waiter; self.waiter = nil
                self.output?.fileHandleForReading.readabilityHandler = nil
                self.output = nil; self.process = nil
                if child.terminationStatus == 0 { waiter?.resume() }
                else {
                    self.message = "Installation failed. Check internet access and run Scripts/setup-runtime.sh for diagnostics."
                    waiter?.resume(throwing: EngineError(code: "E_INSTALL", message: self.message))
                }
            }
        }
        do {
            try await withCheckedThrowingContinuation { continuation in
                waiter = continuation
                do { try child.run() }
                catch { waiter = nil; continuation.resume(throwing: error) }
            }
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            output = nil; process = nil
            message = error.localizedDescription
            throw error
        }
    }

    func stop() {
        if let process, process.isRunning { process.terminate() }
    }
}
