import AppKit

/// Metadata only: selecting an app does not read its UI or require Accessibility.
struct ConversationApplication: Identifiable, Equatable {
    let pid: pid_t
    let bundleIdentifier: String
    let name: String
    let launched: Date?
    var id: String { "\(pid):\(bundleIdentifier):\(launched?.timeIntervalSince1970 ?? 0)" }

    @MainActor static func allowed(_ application: NSRunningApplication) -> Bool {
        AppTarget.isAllowed(application) && application.activationPolicy == .regular
    }
    @MainActor init?(_ application: NSRunningApplication) {
        guard Self.allowed(application), let bundle = application.bundleIdentifier else { return nil }
        self.init(pid: application.processIdentifier, bundleIdentifier: bundle,
                  name: application.localizedName ?? bundle, launched: application.launchDate)
    }
    init(pid: pid_t, bundleIdentifier: String, name: String, launched: Date?) {
        self.pid = pid; self.bundleIdentifier = bundleIdentifier; self.name = name; self.launched = launched
    }
    @MainActor func resolve() -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: pid), Self.allowed(app),
              app.bundleIdentifier == bundleIdentifier, app.launchDate == launched else { return nil }
        return app
    }
}

struct ConversationTurn: Identifiable, Equatable {
    enum Outcome: String { case running, completed, stopped, cancelled }
    let id: UUID
    let goal: String
    let application: String
    var status: String
    var outcome: Outcome
}

/// Session-only UI state. No conversation is written to disk or supplied as
/// implicit authority for a subsequent task. Each send has its own target/run ID.
@MainActor
final class ConversationModel: ObservableObject {
    @Published var draft = ""
    @Published var selectedID = ""
    @Published private(set) var applications: [ConversationApplication] = []
    @Published private(set) var turns: [ConversationTurn] = []
    @Published private(set) var activeID: UUID?
    @Published var notice: String?
    var selected: ConversationApplication? { applications.first { $0.id == selectedID } }
    var isRunning: Bool { activeID != nil }

    func refresh(_ applications: [ConversationApplication], preferred: String? = nil) {
        self.applications = applications.sorted { $0.name == $1.name ? $0.pid < $1.pid : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let preferred, self.applications.contains(where: { $0.id == preferred }), !isRunning {
            selectedID = preferred
        }
        // A disappeared selected process is not silently replaced with another app.
    }
    func begin(goal: String, application: ConversationApplication) throws -> UUID {
        guard activeID == nil else { throw ControllerError.invalid("已有任务在运行，请先停止。") }
        let text = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 4000 else { throw ControllerError.invalid("请输入 1–4000 字节的简短指令。") }
        guard selected?.id == application.id else { throw ControllerError.invalid("目标应用已变化，请重新选择。") }
        let id = UUID()
        turns.append(ConversationTurn(id: id, goal: text, application: application.name, status: "准备执行…", outcome: .running))
        turns = Array(turns.suffix(40))
        activeID = id; notice = nil; draft = ""
        return id
    }
    func update(_ status: String, id: UUID) {
        guard activeID == id, let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[index].status = String(status.prefix(1000))
    }
    func finish(_ outcome: ConversationTurn.Outcome, message: String, id: UUID) {
        guard outcome != .running, activeID == id, let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[index].status = String(message.prefix(1000)); turns[index].outcome = outcome; activeID = nil
    }
    func clear() { guard !isRunning else { return }; turns.removeAll(); notice = nil }
}
