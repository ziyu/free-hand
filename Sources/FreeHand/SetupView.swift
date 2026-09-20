import AppKit
import SwiftUI

struct SetupView: View {
    @ObservedObject var delegate: AppDelegate
    @ObservedObject var engine: LocalEngine
    @ObservedObject var installer: EngineInstaller
    @ObservedObject var hotkey: HotkeyManager
    private let accent = Color(red: 0.15, green: 0.48, blue: 0.38)
    var body: some View {
        VStack(spacing: 0) {
            // The primary entry stays visible even if settings require scrolling.
            HStack(spacing: 16) {
                Image(systemName: "hand.raised.fill").font(.system(size: 32)).foregroundStyle(.white)
                    .frame(width: 60, height: 60).background(accent.gradient, in: RoundedRectangle(cornerRadius: 17))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Free Hand").font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("本地助手 · 点击按钮即可开始").foregroundStyle(.secondary)
                }
                Spacer()
                ConversationLaunchButton(title: delegate.activeTask ? "停止并打开对话" : "开始对话") { delegate.showConversation() }
                    .frame(width: 190, height: 42)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("先打开对话，再选应用。不需要先把快捷键配置好。")
                        .font(.headline)
                    Text("可以先输入指令，开启辅助功能并加载引擎后再执行。Free Hand 操作当前桌面，不是独立后台桌面。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        metric("ENGINE", engine.phase == .ready ? "Ready" : engine.phase.rawValue.capitalized)
                        metric("LAST INFERENCE", engine.decisions == 0 ? "—" : String(format: "%.0f ms", engine.latencyMs))
                        metric("MODEL CALLS", String(engine.decisions))
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Label("快捷键（可选）", systemImage: "keyboard").font(.headline)
                        HStack {
                            Picker("打开对话 / 停止任务", selection: Binding(get: { hotkey.choice }, set: { hotkey.select($0) })) {
                                ForEach(ShortcutChoice.allCases) { Text($0.title).tag($0) }
                            }.accessibilityIdentifier("settings.shortcut")
                            Button("重新检测") { hotkey.retry() }.disabled(delegate.activeTask)
                        }.disabled(delegate.activeTask)
                        Label(hotkey.message, systemImage: hotkey.state.needsAttention ? "exclamationmark.triangle" : "keyboard")
                            .font(.caption).foregroundStyle(hotkey.state.needsAttention ? Color.orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("settings.shortcutStatus")
                        if let date = hotkey.lastTriggeredAt {
                            Text("最近收到快捷键：\(date.formatted(date: .omitted, time: .standard))")
                                .font(.caption).foregroundStyle(accent)
                        }
                        Text("快捷键打开对话无需辅助功能权限。若其他软件仍拦截按键，可换组合或关闭快捷键，直接使用按钮。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 14) {
                        Label("执行前准备", systemImage: "slider.horizontal.3").font(.headline)
                        Text("辅助功能 · Accessibility").font(.subheadline.bold())
                        AccessibilityStatusView(delegate: delegate)
                        Divider()
                        row("2", "本地决策引擎", installer.running ? installer.message : engine.detail, ready: engine.phase == .ready) {
                            if installer.running || engine.phase == .loading { ProgressView().controlSize(.small) }
                            else if engine.phase == .ready { Button("卸载内存") { delegate.unloadEngine() }.disabled(delegate.activeTask) }
                            else {
                                HStack {
                                    if EnginePaths.installed { Button("加载") { delegate.loadEngine() } }
                                    Button(EnginePaths.installed ? "修复" : "安装") { delegate.installEngine() }
                                }.disabled(delegate.activeTask)
                            }
                        }
                        Text("首次安装下载 Python 依赖和约 650 MB 模型，需要联网及 uv；之后推理在本机运行，无需 API Key。")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        row("3", "屏幕文字识别（可选）", delegate.screenReady ? "本地 OCR 可用" : "仅在应用辅助功能信息不足时使用。", ready: delegate.screenReady) {
                            Button(delegate.screenReady ? "设置" : "开启") { delegate.enableScreen() }
                        }
                    }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 14))
                    Toggle("每一步操作都由我确认", isOn: $delegate.reviewEveryAction).font(.headline).disabled(delegate.activeTask)
                    Text(delegate.reviewEveryAction ? "推荐：确认每一次点击、输入和按键。确认后仍会重新校验目标。" : "导航自动模式：部分点击与滚动无需确认。风险识别是启发式判断，不是安全隔离。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = delegate.lastError {
                        Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(alignment: .top) {
                        Text("支持明确的点击、输入和搜索指令。\n复杂自然语言规划仍是实验功能。")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("在 Finder 中显示应用") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }.font(.caption)
                    }
                }.padding(24)
            }
        }.frame(width: 780, height: 800).background(Color(nsColor: .windowBackgroundColor)).tint(accent)
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
    private func row<Content: View>(_ number: String, _ title: String, _ subtitle: String, ready: Bool,
                                    @ViewBuilder action: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(ready ? "✓" : number).font(.subheadline.bold()).foregroundStyle(ready ? accent : .secondary)
                .frame(width: 28, height: 28).background(accent.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.bold())
                Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            action()
        }
    }
}
