import AppKit
import Foundation

enum EnginePaths {
    static var home: URL {
        if let override = ProcessInfo.processInfo.environment["FREEHAND_HOME"] { return URL(fileURLWithPath: override) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Free Hand")
    }
    static var python: URL {
        if let override = ProcessInfo.processInfo.environment["FREEHAND_PYTHON"] { return URL(fileURLWithPath: override) }
        return home.appendingPathComponent("engine/.venv/bin/python")
    }
    static var installed: Bool { FileManager.default.isExecutableFile(atPath: python.path) }
}

@MainActor
final class LocalEngine: ObservableObject, DecisionTransport {
    enum Phase: String { case stopped, loading, ready, failed }
    @Published private(set) var phase: Phase = .stopped
    @Published private(set) var detail = "Local model not loaded"
    @Published private(set) var latencyMs: Double = 0
    @Published private(set) var decisions = 0
    @Published private(set) var omittedRows = 0
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var errors: Pipe?
    private var buffer = Data()
    private var generation = UUID()
    private var readyWaiter: CheckedContinuation<Void, Error>?
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]

    func start() async throws {
        if phase == .ready { return }
        guard process == nil else { throw EngineError(code: "E_BUSY", message: "The local model is already loading.") }
        guard EnginePaths.installed else { throw EngineError(code: "E_INSTALL", message: "Install the local engine from Free Hand’s setup window first.") }
        phase = .loading
        detail = "Verifying and loading the local model…"
        generation = UUID()
        let token = generation
        let child = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = EnginePaths.python
        child.arguments = ["-I", "-u", "-m", "free_hand_engine", "serve"]
        // Do not pass API keys, user PYTHONPATH, or arbitrary interpreter flags to the worker.
        child.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "TMPDIR": NSTemporaryDirectory(),
            "FREEHAND_HOME": EnginePaths.home.path, "HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1",
            "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1", "TOKENIZERS_PARALLELISM": "false"]
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        input = stdin; output = stdout; errors = stderr; process = child
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor in self?.receive(data, token: token) }
        }
        // Drain diagnostics without persisting potentially private third-party exception text.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token, self.process != nil else { return }
                self.stop(error: EngineError(code: "E_EXIT", message: "The local engine stopped. Reload it to continue."))
            }
        }
        do {
            try child.run()
            try await AsyncTimeout.run(seconds: 90, message: "Model startup timed out. Check the engine installation.", onTimeout: {
                self.stop(error: EngineError(code: "E_TIMEOUT", message: "Model startup timed out."))
            }) {
                if self.phase == .ready { return }
                guard self.phase == .loading else { throw EngineError(code: "E_START", message: self.detail) }
                try await withCheckedThrowingContinuation { self.readyWaiter = $0 }
            }
        } catch { stop(error: error); throw error }
    }

    func predict(state: [String: Any], questions: [String: Any]) async throws -> [String: Any] {
        guard phase == .ready, pending.isEmpty else {
            throw EngineError(code: "E_NOT_READY", message: "The local engine is unavailable or busy.")
        }
        let id = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "id": id, "method": "predict",
            "params": ["state": state, "questions": questions]], options: [.sortedKeys])
        guard data.count < 128 * 1024 else { throw EngineError(code: "E_SIZE", message: "The request is too large.") }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await AsyncTimeout.run(seconds: 20, message: "Local decision timed out.", onTimeout: {
                self.stop(error: EngineError(code: "E_TIMEOUT", message: "Local decision timed out."))
            }) {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    self.pending[id] = continuation
                    do {
                        guard let writer = self.input?.fileHandleForWriting else { throw EngineError(code: "E_PIPE", message: "Engine pipe closed.") }
                        try writer.write(contentsOf: data + Data([10]))
                    } catch { self.stop(error: error) }
                }
            }
        } onCancel: { Task { @MainActor in self.stop(error: CancellationError()) } }
    }

    private func receive(_ data: Data, token: UUID) {
        guard generation == token, process != nil else { return }
        guard !data.isEmpty else { return }
        buffer.append(data)
        guard buffer.count <= 128 * 1024 else {
            stop(error: EngineError(code: "E_PROTOCOL", message: "Engine output exceeded the protocol limit.")); return
        }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard line.count <= 64 * 1024, let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  value["version"] as? Int == 1 else {
                stop(error: EngineError(code: "E_PROTOCOL", message: "Invalid engine response.")); return
            }
            if value["event"] as? String == "ready" {
                guard phase == .loading else { continue }
                phase = .ready; detail = "Laya multilingual · entirely on this Mac"
                let waiter = readyWaiter; readyWaiter = nil; waiter?.resume()
                continue
            }
            if value["event"] as? String == "failed" {
                stop(error: EngineError(code: "E_START", message: "The local model could not load. Reinstall the engine.")); return
            }
            guard let id = value["id"] as? String, let waiter = pending.removeValue(forKey: id) else {
                stop(error: EngineError(code: "E_PROTOCOL", message: "Unexpected engine response ID.")); return
            }
            if let error = value["error"] as? [String: String] {
                waiter.resume(throwing: EngineError(code: error["code"] ?? "E_ENGINE", message: error["message"] ?? "Local decision failed."))
            } else if let result = value["result"] as? [String: Any] {
                if let metrics = result["metrics"] as? [String: Any] {
                    latencyMs = metrics["latency_ms"] as? Double ?? 0
                    omittedRows = metrics["omitted_rows"] as? Int ?? 0
                }
                decisions += 1
                waiter.resume(returning: result)
            } else { waiter.resume(throwing: EngineError(code: "E_PROTOCOL", message: "Missing engine result.")) }
        }
    }

    func stop(error: Error = CancellationError()) {
        generation = UUID()
        let child = process
        process = nil
        output?.fileHandleForReading.readabilityHandler = nil
        errors?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        input = nil; output = nil; errors = nil; buffer.removeAll()
        if let child, child.isRunning {
            child.terminate()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        let waiter = readyWaiter; readyWaiter = nil; waiter?.resume(throwing: error)
        let outstanding = pending; pending.removeAll()
        for continuation in outstanding.values { continuation.resume(throwing: error) }
        phase = error is CancellationError ? .stopped : .failed
        detail = error is CancellationError ? "Local model unloaded" : error.localizedDescription
    }
}
