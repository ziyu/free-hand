import Foundation

/// Deterministic interpretation of a small, explicit user-command grammar.
/// This runs BEFORE inference; it never overrides a model refusal after the fact.
/// Unknown or ambiguous commands remain model-driven and subject to review.
enum LiteralCommand: Equatable {
    case click(String)
    case type(String)
    case search(String)
    case key(String)
    case scroll(up: Bool)

    static func parse(_ goal: String) -> LiteralCommand? {
        let text = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let keys = ["press return": "return", "press enter": "return", "按回车": "return", "回车": "return",
                    "press tab": "tab", "按tab": "tab", "press escape": "escape", "按esc": "escape"]
        if let key = keys[lower] { return .key(key) }
        if ["scroll up", "向上滚动"].contains(lower) { return .scroll(up: true) }
        if ["scroll down", "向下滚动"].contains(lower) { return .scroll(up: false) }
        if ["search for ", "搜索", "请搜索", "查找", "请查找"].contains(where: lower.hasPrefix),
           let value = TextExtractor.extract(from: text), !value.isEmpty { return .search(value) }
        if ["type ", "enter ", "输入", "请输入", "键入", "请键入", "填写", "请填写"].contains(where: lower.hasPrefix),
           let value = TextExtractor.extract(from: text), !value.isEmpty { return .type(value) }
        if let prefix = ["click ", "点击", "请点击"].first(where: lower.hasPrefix) {
            var label = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            for (opening, closing) in [("\"", "\""), ("“", "”"), ("「", "」"), ("'", "'")] {
                if label.hasPrefix(opening), label.hasSuffix(closing), label.count >= 2 {
                    label = String(label.dropFirst().dropLast()); break
                }
            }
            if !label.isEmpty { return .click(label) }
        }
        return nil
    }

    var isSingleAction: Bool {
        if case .search = self { return false }
        return true
    }

    private func editable(_ elements: [AccessibilityElement]) -> [AccessibilityElement] {
        elements.filter { $0.source != "ocr" && $0.enabled && !SafetyPolicy.isSecure($0)
            && ["AXTextField", "AXTextArea", "AXComboBox"].contains($0.role) }
    }

    private func textField(_ elements: [AccessibilityElement]) -> AccessibilityElement? {
        let fields = editable(elements)
        let focused = fields.filter(\.focused)
        if focused.count == 1 { return focused[0] }
        return fields.count == 1 ? fields[0] : nil
    }

    func exactValueSatisfied(_ elements: [AccessibilityElement]) -> Bool {
        guard case .type(let text) = self, let field = textField(elements) else { return false }
        return field.value == text
    }

    func action(elements: [AccessibilityElement], history: [ActionHistory]) -> AgentDecision? {
        switch self {
        case .click(let label):
            let matches = DecisionClient.targets(elements)["CLICK", default: [:]].values.filter {
                $0.source != "ocr" && $0.displayLabel.compare(label, options: [.caseInsensitive]) == .orderedSame
            }
            guard matches.count == 1, let target = matches.first else { return nil }
            return AgentDecision(operation: "CLICK", targetIndex: String(target.id))
        case .type(let text):
            guard let field = textField(elements) else { return nil }
            if field.value == text { return AgentDecision(operation: "DONE", reason: "Exact requested field value is already present.") }
            return AgentDecision(operation: "TYPE_TEXT", targetIndex: String(field.id), textValue: text)
        case .search(let query):
            let fields = editable(elements).filter {
                let label = $0.displayLabel.lowercased()
                return label.contains("search") || label.contains("搜索") || label.contains("查找")
            }
            guard fields.count == 1, let field = fields.first, let value = field.value else { return nil }
            // Once submitted, only completion may be checked; never submit or type twice.
            if history.contains(where: { $0.action.hasPrefix("KEY_PRESS") && $0.action.contains("key=return") }) {
                return AgentDecision(operation: "DONE", reason: "Search submitted once; a fresh completion check is required.")
            }
            if value != query { return AgentDecision(operation: "TYPE_TEXT", targetIndex: String(field.id), textValue: query) }
            if !field.focused { return AgentDecision(operation: "CLICK", targetIndex: String(field.id)) }
            return AgentDecision(operation: "KEY_PRESS", key: "return")
        case .key(let key): return AgentDecision(operation: "KEY_PRESS", key: key)
        case .scroll(let up): return AgentDecision(operation: up ? "SCROLL_UP" : "SCROLL_DOWN")
        }
    }
}
