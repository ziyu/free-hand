import SwiftUI

/// Used in both settings and the conversation so remediation never disagrees
/// with the submission gate. No checkbox here can manufacture an authorization.
struct AccessibilityStatusView: View {
    @ObservedObject var delegate: AppDelegate
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(delegate.accessibility.message, systemImage: delegate.accessibilityReady ? "checkmark.shield" : "exclamationmark.shield")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("permissions.status")
            if !delegate.accessibilityReady {
                Text("已经开启开关？先重新检测。仍未生效时连接当前版本，并核对系统条目与下方应用路径；草稿会保留，不会自动发送。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("重新检测") { delegate.refreshPermissions() }
                    .accessibilityIdentifier("permissions.refresh")
                if !delegate.accessibilityReady {
                    Button("连接当前版本") { delegate.enableAccessibility() }
                        .accessibilityIdentifier("permissions.connect")
                } else {
                    Button("系统设置") { delegate.openPrivacy("Privacy_Accessibility") }
                }
                Button(showDetails ? "收起诊断" : "诊断详情") { showDetails.toggle() }
                Spacer(minLength: 0)
            }.controlSize(.small).disabled(delegate.activeTask)
            if showDetails || !delegate.accessibilityReady {
                Text(delegate.accessibility.diagnostics).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("permissions.evidence")
                if showDetails {
                    Text(delegate.appIdentity.signingExplanation).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(delegate.appIdentity.bundlePath).font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text("版本 \(delegate.appIdentity.version) · 进程 \(delegate.appIdentity.processID) · 签名 \(delegate.appIdentity.codeHash.map { String($0.prefix(12)) } ?? "未知")")
                        .font(.caption2).foregroundStyle(.secondary)
                    Button("定位当前应用") { delegate.revealCurrentApplication() }.controlSize(.small)
                    Text("系统已经勾选但始终拒绝时：移除旧 Free Hand 条目，再用 + 添加上面这份应用并开启。仅由你在系统设置中授权；程序不会修改权限数据库。")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
