// Adapted from Third Hand's observed-target selection (see ThirdParty/third-hand.LICENSE).
import Foundation

struct DecisionResult {
    let decision: AgentDecision
    let done: Double
    let absent: Double
    let pickedNone: Bool
    let latencyMs: Int
    var origin: String = "laya"
}

struct EngineError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

@MainActor
protocol DecisionTransport: AnyObject {
    func predict(state: [String: Any], questions: [String: Any]) async throws -> [String: Any]
}

@MainActor
final class DecisionClient {
    private let transport: any DecisionTransport
    nonisolated static let maxChoices = 5
    nonisolated static let doneThreshold = 0.85
    nonisolated static let noneKey = "__none__"

    init(transport: any DecisionTransport) { self.transport = transport }

    nonisolated static func targets(_ elements: [AccessibilityElement]) -> [String: [String: AccessibilityElement]] {
        var result: [String: [String: AccessibilityElement]] = [:]
        let clickRoles: Set<String> = ["AXButton", "AXMenuItem", "AXMenuBarItem", "AXLink", "AXTab",
            "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXRow", "AXCell", "AXDisclosureTriangle", "AXSwitch"]
        for element in elements where element.enabled && !SafetyPolicy.isSecure(element) {
            let id = String(element.id)
            if element.source == "ocr" {
                if element.frame != nil { result["CLICK_TEXT", default: [:]][id] = element }
            } else if ["AXTextField", "AXTextArea", "AXComboBox"].contains(element.role) {
                result["TYPE_TEXT", default: [:]][id] = element
                result["CLICK", default: [:]][id] = element
            } else if clickRoles.contains(element.role) || element.actions.contains(where: {
                ["AXPress", "AXOpen", "AXConfirm", "AXPick"].contains($0)
            }) { result["CLICK", default: [:]][id] = element }
        }
        return result
    }

    nonisolated static func ranked(_ elements: [AccessibilityElement], goal: String) -> [AccessibilityElement] {
        let words = Set(goal.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        func relevance(_ element: AccessibilityElement) -> Int {
            let label = element.displayLabel.lowercased()
            let matches = words.filter { $0.count > 1 && label.contains($0) }.count
            let exact = label.count > 1 && goal.lowercased().contains(label) ? 100 : 0
            return matches * 20 + exact + (element.focused ? 50 : 0) + (element.isOutcomeEvidence ? 45 : 0)
                + (["AXTextField", "AXTextArea", "AXComboBox"].contains(element.role) ? 5 : 0)
        }
        return elements.filter { !SafetyPolicy.isSecure($0) }.sorted {
            let a = relevance($0), b = relevance($1)
            return a == b ? $0.id < $1.id : a > b
        }
    }

    nonisolated static func offeredTargets(_ elements: [AccessibilityElement], goal: String) -> [String: [String: AccessibilityElement]] {
        targets(elements).mapValues { candidates in
            Dictionary(uniqueKeysWithValues: ranked(Array(candidates.values), goal: goal)
                .prefix(maxChoices - 1).map { (String($0.id), $0) })
        }
    }

    nonisolated static func operationChoices(goal: String, elements: [AccessibilityElement]) -> [String: String] {
        var choices = ["WAIT": "wait for loading", "DONE": "task visibly complete", "BLOCKED": "cannot proceed"]
        for operation in targets(elements).keys {
            choices[operation] = ["CLICK": "click or focus a control", "TYPE_TEXT": "type text or a search query into an input field", "CLICK_TEXT": "click visible text"][operation]
        }
        let request = goal.lowercased()
        func mentions(_ words: [String]) -> Bool { words.contains { request.contains($0) } }
        let editable = elements.filter { ["AXTextField", "AXTextArea", "AXComboBox"].contains($0.role) && $0.enabled && !SafetyPolicy.isSecure($0) }
        if editable.contains(where: { $0.focused && !($0.value ?? "").isEmpty }) || mentions(["press return", "press enter", "回车"]) {
            choices["PRESS_RETURN"] = "submit focused field"
        }
        if mentions(["press tab", "next field", "下一个输入框", "制表键"]) { choices["PRESS_TAB"] = "focus next control" }
        if mentions(["escape", "dismiss", "close popup", "关闭弹窗", "退出弹窗"]) { choices["PRESS_ESCAPE"] = "dismiss popup" }
        let scrollable = elements.contains { ["AXScrollArea", "AXList", "AXTable", "AXOutline"].contains($0.role) }
        if scrollable || elements.count >= 16 || mentions(["scroll", "滚动", "向上翻", "向下翻"]) {
            choices["SCROLL_UP"] = "scroll up"
            choices["SCROLL_DOWN"] = "scroll down"
        }
        return choices
    }

    nonisolated static func operationInstruction(goal: String) -> String {
        "For the user task \"\(goal)\", which immediate desktop action should be taken next? Do not repeat completed steps."
    }

    /// Normalize a literal search into its observable next step. A small classifier
    /// should not have to invent the text-entry/submission workflow. The original
    /// user goal remains intact in state, and every step still goes through Laya,
    /// target validation, review, and post-action verification.
    nonisolated static func actionObjective(goal: String, elements: [AccessibilityElement], history: [ActionHistory]) -> String {
        let request = goal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["search for ", "搜索", "请搜索", "查找", "请查找"].contains(where: { request.hasPrefix($0) }),
              let query = TextExtractor.extract(from: goal) else { return goal }
        let fields = elements.filter {
            let label = $0.displayLabel.lowercased()
            return ["AXTextField", "AXTextArea", "AXComboBox"].contains($0.role) && $0.enabled && !SafetyPolicy.isSecure($0)
                && (label.contains("search") || label.contains("搜索") || label.contains("查找"))
        }
        guard fields.count == 1, let field = fields.first, let current = field.value else { return goal }
        if current != query { return "Type \"\(query)\" into the \"\(String(field.displayLabel.prefix(60)))\" search field." }
        let alreadySubmitted = history.contains { $0.action.hasPrefix("KEY_PRESS") && $0.action.contains("key=return") }
        guard !alreadySubmitted else { return goal }
        if !field.focused { return "Click the \"\(String(field.displayLabel.prefix(60)))\" search field to focus it." }
        return "Press Return to submit the search query that is already in the focused search field."
    }

    nonisolated static func state(goal: String, elements: [AccessibilityElement], appName: String,
                                 history: [ActionHistory]) throws -> [String: Any] {
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, goal.utf8.count <= 4000 else {
            throw ControllerError.invalid("Use a nonempty request shorter than 4,000 UTF-8 bytes.")
        }
        return ["task": goal, "app": String(appName.prefix(80)),
            "action_attempts": history.suffix(3).map { "\(String($0.action.prefix(100))): \(String($0.result.prefix(100)))" },
            "elements": ranked(elements, goal: goal).prefix(16).map { element -> [String: Any] in
                var row: [String: Any] = ["id": String(element.id), "role": element.displayRole,
                    "label": String(element.displayLabel.prefix(60)), "enabled": element.enabled]
                if element.focused { row["focused"] = true }
                // Empty is an observed value, not missing data. Search decisions depend on this distinction.
                if let value = element.value { row["value"] = String(value.prefix(80)) }
                if element.source == "ocr" { row["source"] = "ocr-text-not-proven-control" }
                return row
            }]
    }

    private func choose(_ name: String, instruction: String, criteria: [String: String], state: [String: Any]) async throws -> String {
        guard instruction.utf8.count <= 600 else {
            throw ControllerError.invalid("The task is too long for a local control-selection question. Use a shorter request; it was not truncated.")
        }
        let order = criteria.keys.sorted { left, right in
            if left == right { return false }
            if left == Self.noneKey { return true }
            if right == Self.noneKey { return false }
            return left < right
        }
        let result = try await transport.predict(state: state, questions: [name: [
            "type": "choice", "instructions": instruction, "criteria": criteria, "option_order": order]])
        guard let answers = result["answers"] as? [String: [String: Any]], let answer = answers[name],
              let choice = answer["choice"] as? String, criteria[choice] != nil,
              let probabilities = answer["probabilities"] as? [String: Double],
              Set(probabilities.keys) == Set(criteria.keys),
              probabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              abs(probabilities.values.reduce(0, +) - 1) < 0.01 else {
            throw ControllerError.invalid("Invalid local decision; no input was sent.")
        }
        // This is an abstention threshold, not a claim of calibrated accuracy.
        guard probabilities[choice, default: 0] >= 0.35 else {
            throw ControllerError.invalid("The local model is uncertain. Try a narrower, single-step request.")
        }
        return choice
    }

    func decide(goal: String, elements: [AccessibilityElement], appName: String, history: [ActionHistory],
                allowLiteralCommands: Bool = true) async throws -> DecisionResult {
        let start = Date()
        var state = try Self.state(goal: goal, elements: elements, appName: appName, history: history)
        if allowLiteralCommands, let command = LiteralCommand.parse(goal),
           let action = command.action(elements: elements, history: history) {
            return DecisionResult(decision: action, done: 0, absent: 0, pickedNone: false, latencyMs: 0, origin: "literal")
        }
        let offered = Self.offeredTargets(elements, goal: goal)
        let operations = Self.operationChoices(goal: goal, elements: elements)
        let objective = Self.actionObjective(goal: goal, elements: elements, history: history)
        if objective != goal { state["selectedIntent"] = objective }
        let operation = try await choose("operation", instruction: Self.operationInstruction(goal: objective), criteria: operations, state: state)
        try Task.checkCancellation()
        var answers: [String: Any] = ["operation": ["choice": operation]]
        if let candidates = offered[operation] {
            var criteria = candidates.mapValues { "\(String($0.displayLabel.prefix(32))) [\($0.displayRole)]" }
            criteria[Self.noneKey] = "none of these controls"
            state["selectedIntent"] = operation
            let target = try await choose("target", instruction: Self.targetInstruction(goal: goal, operation: operation), criteria: criteria, state: state)
            answers[operation.lowercased() + "_target"] = ["choice": target]
        }
        let data = try JSONSerialization.data(withJSONObject: ["answers": answers])
        return try Self.decode(data, elements: elements, latencyMs: Int(Date().timeIntervalSince(start) * 1000), offered: offered)
    }

    nonisolated static func targetInstruction(goal: String, operation: String) -> String {
        "For the task \"\(goal)\", which UI control should \(operation) target? Prefer search fields for search tasks."
    }

    func selectText(goal: String, field: AccessibilityElement, appName: String, terminal: Bool) async throws -> TextEntryPlan {
        // Explicit user text is authoritative. It is never composed from screen content.
        if let exact = TextExtractor.extract(from: goal) {
            return try TextEntryPlan.build(kind: "literal", content: exact, terminal: terminal)
        }
        let quoted = TextEntryPlan.candidates(goal).filter { candidate in
            ["\"\(candidate)\"", "“\(candidate)”", "'\(candidate)'", "「\(candidate)」"].contains { goal.contains($0) }
        }
        guard !quoted.isEmpty, quoted.count <= 4 else {
            throw ControllerError.invalid("Put the exact text or search terms in quotes, for example: 输入“你好” or Search for \"Adele\". Free Hand does not generate writing or commands.")
        }
        if quoted.count == 1 { return try TextEntryPlan.build(kind: "literal", content: quoted[0], terminal: terminal) }
        var state = try Self.state(goal: goal, elements: [], appName: appName, history: [])
        state["field"] = String(field.displayLabel.prefix(60))
        var criteria = Dictionary(uniqueKeysWithValues: quoted.enumerated().map { (String($0.offset), $0.element) })
        criteria[Self.noneKey] = "no suitable user text"
        let choice = try await choose("content", instruction: "Which user-supplied text belongs in this field?", criteria: criteria, state: state)
        guard let index = Int(choice), quoted.indices.contains(index) else {
            throw ControllerError.invalid("No unambiguous text was selected. Use a single quoted phrase.")
        }
        return try TextEntryPlan.build(kind: "literal", content: quoted[index], terminal: terminal)
    }

    func confirmCompletion(goal: String, elements: [AccessibilityElement], appName: String, history: [ActionHistory]) async throws -> Bool {
        let context = try Self.state(goal: goal, elements: elements, appName: appName, history: history)
        let result = try await transport.predict(state: context, questions: ["done": ["type": "noul",
            "instructions": "The entire user task is already completed, with visible evidence. A planned or failed action is not completion."]])
        guard let answers = result["answers"] as? [String: [String: Any]], let done = answers["done"]?["noul"] as? Double,
              done.isFinite, (0...1).contains(done) else {
            throw ControllerError.invalid("Invalid completion check. Stopped without sending more input.")
        }
        return done >= Self.doneThreshold
    }

    nonisolated static func decode(_ data: Data, elements: [AccessibilityElement], latencyMs: Int = 0,
                                   offered: [String: [String: AccessibilityElement]]? = nil) throws -> DecisionResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = json["answers"] as? [String: [String: Any]], let op = answers["operation"]?["choice"] as? String else {
            throw ControllerError.invalid("Missing operation in local decision.")
        }
        let candidates = offered ?? targets(elements)
        guard Set(candidates.keys).union(["SCROLL_UP", "SCROLL_DOWN", "PRESS_RETURN", "PRESS_TAB", "PRESS_ESCAPE", "WAIT", "DONE", "BLOCKED"]).contains(op) else {
            throw ControllerError.invalid("Unsupported local operation.")
        }
        var decision = AgentDecision(operation: op)
        var none = false
        if let targets = candidates[op] {
            guard let target = answers[op.lowercased() + "_target"]?["choice"] as? String else {
                throw ControllerError.invalid("Missing action target.")
            }
            if target == noneKey { none = true; decision = AgentDecision(operation: "BLOCKED", reason: "Target not visible in the local shortlist.") }
            else {
                guard targets[target] != nil else { throw ControllerError.invalid("Unoffered action target.") }
                decision.targetIndex = target
            }
        }
        if let key = ["PRESS_RETURN": "return", "PRESS_TAB": "tab", "PRESS_ESCAPE": "escape"][op] {
            decision = AgentDecision(operation: "KEY_PRESS", key: key)
        }
        return DecisionResult(decision: decision, done: 0, absent: 0, pickedNone: none, latencyMs: latencyMs)
    }
}
