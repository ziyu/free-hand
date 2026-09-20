import AppKit
import Security

/// The running executable's identity, for diagnosing stale grants after a build.
/// Reading code-signing metadata never changes certificates, TCC, or permissions.
struct RunningAppIdentity: Codable, Equatable {
    let bundleIdentifier: String
    let bundlePath: String
    let version: String
    let processID: Int32
    let codeHash: String?
    let designatedRequirement: String?
    let signatureValid: Bool
    let adHoc: Bool

    static func current() -> RunningAppIdentity {
        var dynamic: SecCode?
        var code: SecStaticCode?
        var information: CFDictionary?
        var requirement: SecRequirement?
        var description: CFString?
        var valid = false
        if SecCodeCopySelf([], &dynamic) == errSecSuccess, let dynamic {
            valid = SecCodeCheckValidity(dynamic, [], nil) == errSecSuccess
            if SecCodeCopyStaticCode(dynamic, [], &code) == errSecSuccess, let code {
                _ = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                if SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement {
                    _ = SecRequirementCopyString(requirement, [], &description)
                }
            }
        }
        let info = information as? [String: Any] ?? [:]
        let hash = (info[kSecCodeInfoUnique as String] as? Data)?.map { String(format: "%02x", $0) }.joined()
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return RunningAppIdentity(bundleIdentifier: Bundle.main.bundleIdentifier ?? "unbundled",
            bundlePath: Bundle.main.bundleURL.resolvingSymlinksInPath().path,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
            processID: ProcessInfo.processInfo.processIdentifier, codeHash: hash,
            designatedRequirement: description as String?, signatureValid: valid,
            adHoc: SecCodeSignatureFlags(rawValue: flags).contains(.adhoc))
    }

    var signingExplanation: String {
        if !signatureValid { return "当前签名无法验证。请退出后重新打开这份应用，避免运行旧进程。" }
        if adHoc { return "当前是开发签名；代码更新会改变签名哈希。系统里旧版本的开关可能仍开启，但不对应此版本。" }
        return "当前为证书签名。请确认系统设置中授权的是下面这份应用。"
    }
}

struct PermissionDiagnosticReport: Encodable {
    let scope = "same running app; public permission APIs and window references only; no desktop input"
    let identity: RunningAppIdentity
    let evidence: AccessibilityAccessSnapshot
    var accessState: String { evidence.state.rawValue }
    enum CodingKeys: String, CodingKey { case scope, identity, evidence, accessState }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(scope, forKey: .scope)
        try values.encode(identity, forKey: .identity)
        try values.encode(evidence, forKey: .evidence)
        try values.encode(accessState, forKey: .accessState)
    }
}
