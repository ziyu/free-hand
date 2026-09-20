import Foundation

enum SafetyPolicy {
    static func isSecure(_ element: AccessibilityElement) -> Bool {
        let text = (element.role + " " + (element.label ?? "")).lowercased()
        return text.contains("securetextfield") || text.contains("password") || text.contains("密码")
    }

    static func requiresApproval(_ decision: AgentDecision, elements: [AccessibilityElement], bundle: String?, reviewEveryAction: Bool) -> Bool {
        guard !["WAIT", "DONE", "BLOCKED"].contains(decision.operation) else { return false }
        if reviewEveryAction || TextEntryPlan.isTerminal(bundle) { return true }
        // Auto mode is convenience, NOT a security sandbox. Text, submit and OCR always get review.
        if ["TYPE_TEXT", "CLICK_TEXT"].contains(decision.operation) || decision.key == "return" { return true }
        let label = elements.first { String($0.id) == decision.targetIndex }?.displayLabel.lowercased() ?? ""
        let risky = ["delete", "remove", "trash", "send", "publish", "purchase", "buy", "pay", "transfer",
                     "install", "allow", "approve", "grant", "authorize", "confirm", "submit", "sign in", "log in",
                     "删除", "移除", "清空", "发送", "发布", "购买", "付款", "转账", "安装", "允许", "授权", "确认", "提交", "登录"]
        return risky.contains { label.contains($0) }
    }
}
