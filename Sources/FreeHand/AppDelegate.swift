import AppKit
import ApplicationServices
import SwiftUI

struct RunSummary: Identifiable {
    let id = UUID()
    let app: String
    var status: String
    let started = Date()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, TaskRunnerDelegate, ObservableObject {
    let engine = LocalEngine()
    let installer = EngineInstaller()
    let conversation = ConversationModel()
    lazy var hotkey = HotkeyManager { [weak self] in self?.handleHotkey() }
    private var runner: TaskRunner?
    private var indicator: StatusIndicatorWindow?
    private(set) var setupWindow: NSWindow?
    private(set) var conversationWindow: NSWindow?
    private var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lastExternalApplication: ConversationApplication?
    private var turnID: UUID?
    private var approvalPanel: ApprovalPanel?
    private var approvalWaiter: CheckedContinuation<Void, Error>?
    private var terminating = false
    private let readAccessibility: (pid_t?) -> AccessibilityAccessSnapshot
    @Published private(set) var accessibility = AccessibilityAccessSnapshot.unchecked
    var accessibilityReady: Bool { accessibility.canControl }
    lazy var appIdentity = RunningAppIdentity.current()
    @Published var screenReady = false
    @Published private(set) var activeTask = false
    @Published var lastError: String?
    @Published var history: [RunSummary] = []
    @Published var reviewEveryAction = UserDefaults.standard.object(forKey: "reviewEveryAction") as? Bool ?? true {
        didSet { UserDefaults.standard.set(reviewEveryAction, forKey: "reviewEveryAction") }
    }

    override convenience init() {
        self.init(permissionCheck: { AccessibilityAccess.check(targetPID: $0) })
    }
    init(permissionCheck: @escaping (pid_t?) -> AccessibilityAccessSnapshot) {
        self.readAccessibility = permissionCheck
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let destination = commandArgument("--permission-check") {
            refreshPermissions()
            let report = PermissionDiagnosticReport(identity: appIdentity, evidence: accessibility)
            if let data = try? JSONEncoder().encode(report) { try? data.write(to: destination, options: .atomic) }
            NSApp.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--doctor") {
            refreshPermissions()
            let state: [String: Any] = ["app": "Free Hand", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
                "accessibility": accessibilityReady, "accessibilityTrusted": accessibility.trusted,
                "accessibilityState": accessibility.state.rawValue, "inputPosting": accessibility.eventPosting,
                "accessibilityProbe": accessibility.probeDescription, "screenRecording": screenReady,
                "processID": appIdentity.processID, "bundlePath": appIdentity.bundlePath,
                "codeHash": appIdentity.codeHash ?? "unknown", "adHocSigning": appIdentity.adHoc,
                "engineInstalled": EnginePaths.installed, "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unbundled",
                "model": "aac6fef/laya-multilingual-mlx", "shortcut": ShortcutChoice.saved(in: .standard).title,
                "conversationButton": true]
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            NSApp.terminate(nil)
            return
        }
        rememberFrontmostApplication()
        observeApplications()
        hotkey.start() // Opening our own window never depends on Accessibility permission.
        refreshPermissions()
        let permissionTimer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        timer = permissionTimer
        RunLoop.main.add(permissionTimer, forMode: .common)
        showSetup()
        if EnginePaths.installed { loadEngine() }
        if CommandLine.arguments.contains("--open-conversation") { showConversation() }
        schedulePreview("--capture-preview") { $0.setupWindow }
        schedulePreview("--capture-conversation-preview") { $0.conversationWindow }
        if let destination = commandArgument("--ui-smoke-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.runEntrySmokeTest(to: destination) }
        }
        Log.info("Application launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        stopTask(); engine.stop(); installer.stop(); timer?.invalidate(); hotkey.stop()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showConversation(); return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // System Settings can finish applying a grant after activation arrives.
        // Sample now and again after the next run-loop turns; never retain a
        // previously granted result as an override for a fresh OS denial.
        refreshPermissions()
        for delay in [0.25, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.terminating else { return }
                self.refreshPermissions()
            }
        }
    }

    func showSetup() {
        // Bringing our app forward must invalidate input immediately, not one model call later.
        if activeTask { stopTask() }
        rememberFrontmostApplication()
        if setupWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 780, height: 800),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Free Hand"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SetupView(delegate: self, engine: engine, installer: installer, hotkey: hotkey))
            window.center(); setupWindow = window
        }
        setupWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Shared button/menu/hotkey entry. Always opens, even before engine or TCC setup.
    /// It never changes the selected app into Free Hand after activating our window.
    func showConversation() {
        let interrupted = activeTask
        if interrupted { stopTask() }
        let front = NSWorkspace.shared.frontmostApplication.flatMap(ConversationApplication.init)
        if let front { lastExternalApplication = front }
        let preferred = front?.id ?? (conversation.selected != nil ? conversation.selectedID : lastExternalApplication?.id)
        refreshApplications(preferred: preferred)
        refreshPermissions()
        if conversationWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 660, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Free Hand · 对话"
            window.identifier = NSUserInterfaceItemIdentifier("conversation.window")
            window.minSize = NSSize(width: 580, height: 600)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ConversationView(delegate: self, model: conversation, engine: engine, installer: installer))
            window.center(); conversationWindow = window
        }
        if interrupted { conversation.notice = "已停止上一条任务，可以继续输入新指令。" }
        conversationWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func handleHotkey() {
        if activeTask { stopTask(); return }
        // Repeated presses focus the existing conversation; never throw away a draft.
        showConversation()
    }

    private func rememberFrontmostApplication() {
        if let app = NSWorkspace.shared.frontmostApplication, let value = ConversationApplication(app) {
            lastExternalApplication = value
        }
    }
    private func observeApplications() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in
                if let value = ConversationApplication(app) { self?.lastExternalApplication = value }
            }
        })
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshApplications(); self?.refreshPermissions() }
            })
        }
    }
    func refreshApplications(preferred: String? = nil) {
        conversation.refresh(NSWorkspace.shared.runningApplications.compactMap(ConversationApplication.init), preferred: preferred)
    }

    func refreshPermissions() {
        let previous = accessibility
        accessibility = readAccessibility(conversation.selected?.resolve()?.processIdentifier)
        if accessibility.canControl && !previous.canControl && conversation.notice == previous.message {
            conversation.notice = nil
        }
        if !accessibility.canControl && activeTask { stopTask() }
        screenReady = CGPreflightScreenCaptureAccess()
    }
    func openPrivacy(_ section: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + section) { NSWorkspace.shared.open(url) }
    }
    func enableAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        // Explicitly request for this signed process, not a helper or a URL-only
        // settings visit. Only the user can approve the system prompt.
        if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
        openPrivacy("Privacy_Accessibility")
        refreshPermissions()
    }
    func revealCurrentApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
    func enableScreen() {
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        if !CGPreflightScreenCaptureAccess() { openPrivacy("Privacy_ScreenCapture") }
        refreshPermissions()
    }

    func loadEngine() {
        guard !activeTask, engine.phase != .loading else { return }
        lastError = nil
        Task { do { try await engine.start() } catch { lastError = error.localizedDescription } }
    }
    func installEngine() {
        guard !activeTask, !installer.running, engine.phase != .loading else { return }
        engine.stop(); lastError = nil
        Task {
            do { try await installer.install(); try await engine.start() }
            catch { lastError = error.localizedDescription }
        }
    }
    func unloadEngine() { guard !activeTask else { return }; engine.stop() }

    var submissionBlocker: String? {
        if activeTask { return "任务运行中；打开对话或点击停止后再发送新指令。" }
        if conversation.selected == nil { return "请先选择一个正在运行的目标应用；若应用已退出，请重新选择。" }
        if !accessibilityReady { return accessibility.message }
        if engine.phase != .ready { return "本地引擎尚未就绪：可以先输入指令，加载完成后再发送。" }
        if conversation.draft.utf8.count > 4000 { return "指令太长，请缩短至 4000 字节以内。" }
        return nil
    }
    var canSubmitConversation: Bool {
        submissionBlocker == nil && !conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func sendConversation() {
        refreshPermissions() // Never trust only the published timer value for a write.
        guard canSubmitConversation else {
            conversation.notice = submissionBlocker ?? "请输入要执行的指令。"
            return
        }
        guard let selected = conversation.selected, let application = selected.resolve(),
              let target = AppTarget.capture(application: application) else {
            conversation.notice = "目标应用已退出或发生变化，请重新选择。草稿已保留。"
            refreshApplications()
            return
        }
        let goal = conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        do { turnID = try conversation.begin(goal: goal, application: selected) }
        catch { conversation.notice = error.localizedDescription; return }
        lastError = nil
        let newRunner = TaskRunner(target: target, goal: goal, engine: engine, reviewEveryAction: reviewEveryAction,
            approval: { [weak self] decision, elements in
                guard let self else { throw CancellationError() }
                try await self.approve(target: target, decision: decision, elements: elements)
            })
        newRunner.delegate = self; runner = newRunner; activeTask = true
        history.insert(RunSummary(app: target.name, status: "Running"), at: 0)
        history = Array(history.prefix(12))
        indicator?.dismiss()
        indicator = StatusIndicatorWindow(near: target) { [weak self] in self?.stopTask() }
        // The selected process, not the frontmost Free Hand window, is the target.
        // Hide our key window before TaskRunner activates it and rechecks focus.
        conversationWindow?.orderOut(nil); setupWindow?.orderOut(nil)
        newRunner.start()
    }

    private func approve(target: AppTarget, decision: AgentDecision, elements: [AccessibilityElement]) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                approvalWaiter = continuation
                let label = elements.first { String($0.id) == decision.targetIndex }?.displayLabel ?? "Current window"
                approvalPanel = ApprovalPanel(target: target, decision: decision, label: label) { [weak self] accepted in
                    guard let self else { return }
                    let waiter = self.approvalWaiter; self.approvalWaiter = nil
                    self.approvalPanel?.close(); self.approvalPanel = nil
                    if accepted { waiter?.resume() }
                    else { waiter?.resume(throwing: CancellationError()); self.stopTask() }
                }
                approvalPanel?.orderFrontRegardless()
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancelApproval() } }
    }
    private func cancelApproval() {
        let waiter = approvalWaiter; approvalWaiter = nil
        approvalPanel?.close(); approvalPanel = nil
        waiter?.resume(throwing: CancellationError())
    }
    func stopTask() { cancelApproval(); runner?.cancel() }
    func taskRunner(_ r: TaskRunner, status: String) {
        guard runner === r else { return }
        indicator?.updateStatus(status)
        if let turnID { conversation.update(status, id: turnID) }
    }
    private func finish(_ outcome: ConversationTurn.Outcome, message: String) {
        cancelApproval(); activeTask = false; runner = nil
        if let turnID { conversation.finish(outcome, message: message, id: turnID) }
        turnID = nil
        if !history.isEmpty { history[0].status = message }
        // Show the result without becoming the key application or stealing input.
        if !terminating { conversationWindow?.orderFront(nil) }
    }
    func taskRunnerDone(_ r: TaskRunner) {
        guard runner === r else { return }; indicator?.showDone(); finish(.completed, message: "执行结束，结果已通过当前校验。请确认目标应用中的实际效果。")
    }
    func taskRunnerFailed(_ r: TaskRunner, error: String) {
        guard runner === r else { return }; indicator?.showError(error); lastError = error; finish(.stopped, message: "任务未完成：" + error)
    }
    func taskRunnerCancelled(_ r: TaskRunner) {
        guard runner === r else { return }; indicator?.dismiss(); finish(.cancelled, message: "任务已停止，未继续发送输入。")
    }

    // Only our own views are rendered. These diagnostic flags never send input to another app.
    private func commandArgument(_ flag: String) -> URL? {
        guard let index = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[index + 1])
    }
    private func schedulePreview(_ flag: String, window: @escaping (AppDelegate) -> NSWindow?) {
        guard let destination = commandArgument(flag) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, let view = window(self)?.contentView else { return }
            Self.render(view, to: destination)
        }
    }
    static func render(_ view: NSView, to destination: URL) {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: destination) }
    }
    static func launchButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.identifier?.rawValue == "conversation.open" { return button }
        return view.subviews.lazy.compactMap { launchButton(in: $0) }.first
    }
    private func runEntrySmokeTest(to destination: URL) {
        guard let view = setupWindow?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let button = Self.launchButton(in: view)
        let enabled = button?.isEnabled == true
        button?.performClick(nil)
        let first = conversationWindow
        let opened = first?.isVisible == true
        conversation.draft = "fixture draft · 你好"
        conversationWindow?.performClose(nil)
        button?.performClick(nil)
        let report: [String: Any] = ["scope": "actual native launch button; no external app input",
            "buttonFound": button != nil, "buttonEnabled": enabled, "conversationOpened": opened,
            "sameWindowReused": first != nil && first === conversationWindow,
            "draftPreserved": conversation.draft == "fixture draft · 你好", "noTaskStarted": !activeTask,
            "selfExcludedFromTargets": !conversation.applications.contains { $0.bundleIdentifier == "com.feibai.freehand" },
            "shortcut": hotkey.choice.title, "shortcutRegistered": hotkey.isRunning,
            "shortcutStatus": hotkey.message, "accessibility": accessibilityReady, "engine": engine.phase.rawValue,
            "accessibilityTrusted": accessibility.trusted, "inputPosting": accessibility.eventPosting,
            "accessibilityState": accessibility.state.rawValue, "accessibilityProbe": accessibility.probeDescription]
        conversation.draft = ""
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: destination) }
        if let view = conversationWindow?.contentView { Self.render(view, to: destination.deletingPathExtension().appendingPathExtension("png")) }
    }
}
