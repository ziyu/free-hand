import AppKit
import ApplicationServices

/// Evidence collected by the controlling application itself, never a terminal,
/// helper's authorization, a preference, or the name of a System Settings row.
struct AccessibilityAccessSnapshot: Equatable, Codable {
    enum State: String, Codable {
        case unchecked, authorized, verifiedCapabilities, notEffective, inputUnavailable
    }
    let trusted: Bool
    let eventPosting: Bool
    let processID: Int32
    let probeProcessID: Int32?
    let probeError: Int32?
    let windowsReadable: Bool

    static let unchecked = AccessibilityAccessSnapshot(trusted: false, eventPosting: false,
        processID: 0, probeProcessID: nil, probeError: nil, windowsReadable: false)

    var verifiedExternalRead: Bool {
        guard let pid = probeProcessID, pid > 0, pid != processID else { return false }
        return probeError == AXError.success.rawValue && windowsReadable
    }
    var state: State {
        if processID == 0 { return .unchecked }
        // An explicit OS denial overrides cached positive trust/preflight results.
        if probeError == AXError.apiDisabled.rawValue { return .notEffective }
        if !eventPosting { return trusted || verifiedExternalRead ? .inputUnavailable : .notEffective }
        if trusted { return .authorized }
        // A stale trust query is not allowed to block independently verified AX
        // access AND an affirmative OS event-posting preflight. Read access alone
        // can never authorize keyboard/mouse synthesis.
        return verifiedExternalRead ? .verifiedCapabilities : .notEffective
    }
    var canControl: Bool { state == .authorized || state == .verifiedCapabilities }
    var message: String {
        switch state {
        case .unchecked: return "正在检查当前应用的辅助功能连接…"
        case .authorized: return "辅助功能已授权，输入权限可用。"
        case .verifiedCapabilities: return "实际辅助功能读取和输入权限已验证；系统信任状态暂未同步。"
        case .notEffective: return "当前运行版本的授权尚未生效；这不代表你没有开启系统开关。"
        case .inputUnavailable: return "辅助功能可以访问，但当前进程的键鼠输入权限尚未生效。"
        }
    }
    var probeDescription: String {
        guard let probeError else { return "尚无可检测的外部应用" }
        switch AXError(rawValue: probeError) {
        case .success: return verifiedExternalRead ? "外部窗口读取成功" : "未得到有效的外部窗口列表"
        case .apiDisabled: return "系统拒绝当前进程（AXError \(probeError)）"
        case .cannotComplete: return "目标暂未响应（不是未授权结论）"
        case .noValue, .attributeUnsupported, .notImplemented: return "目标未提供窗口列表（不是未授权结论）"
        default: return "读取状态 \(probeError)"
        }
    }
    var diagnostics: String {
        "信任接口：\(trusted ? "是" : "否") · 输入预检：\(eventPosting ? "是" : "否") · \(probeDescription)"
    }
}

@MainActor
enum AccessibilityAccess {
    /// Read only the selected application's window references. No window titles,
    /// field values, screen pixels, or input are read/logged by this permission probe.
    static func check(targetPID: pid_t? = nil) -> AccessibilityAccessSnapshot {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        let posting = CGPreflightPostEventAccess()
        let application: NSRunningApplication?
        if let targetPID {
            application = NSRunningApplication(processIdentifier: targetPID)
        } else {
            application = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
                .first { !$0.isTerminated }
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let application, !application.isTerminated, application.processIdentifier > 0,
              application.processIdentifier != ownPID, AppTarget.isAllowed(application) else {
            return AccessibilityAccessSnapshot(trusted: trusted, eventPosting: posting, processID: ownPID,
                probeProcessID: nil, probeError: nil, windowsReadable: false)
        }
        let target = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(target, 0.12)
        var windows: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(target, kAXWindowsAttribute as CFString, &windows)
        let readable = result == .success && windows.map { CFGetTypeID($0) == CFArrayGetTypeID() } == true
        return AccessibilityAccessSnapshot(trusted: trusted, eventPosting: posting, processID: ownPID,
            probeProcessID: application.processIdentifier, probeError: result.rawValue, windowsReadable: readable)
    }

    static func require(targetPID: pid_t) throws {
        let snapshot = check(targetPID: targetPID)
        guard snapshot.canControl else {
            throw ControllerError.invalid(snapshot.message + " 请返回 Free Hand 重新检测或连接当前版本。")
        }
    }

    static func requireEventPosting() throws {
        guard CGPreflightPostEventAccess() else {
            throw ControllerError.invalid("当前进程的键鼠输入权限不可用，已停止发送输入。请在 Free Hand 中重新检测授权。")
        }
    }
}
