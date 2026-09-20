import AppKit
import SwiftUI

/// A real native button, shared by the setup UI and the in-app entry smoke test.
struct ConversationLaunchButton: NSViewRepresentable {
    var title = "开始对话"
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.open))
        button.identifier = NSUserInterfaceItemIdentifier("conversation.open")
        button.setAccessibilityIdentifier("conversation.open")
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 16, weight: .semibold)
        button.bezelColor = NSColor(calibratedRed: 0.15, green: 0.48, blue: 0.38, alpha: 1)
        button.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) { button.title = title; context.coordinator.action = action }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func open() { action() }
    }
}

struct ConversationView: View {
    @ObservedObject var delegate: AppDelegate
    @ObservedObject var model: ConversationModel
    @ObservedObject var engine: LocalEngine
    @ObservedObject var installer: EngineInstaller
    @FocusState private var inputFocused: Bool
    private let accent = Color(red: 0.15, green: 0.48, blue: 0.38)
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("对话", systemImage: "bubble.left.and.bubble.right.fill").font(.title2.bold())
                    Spacer()
                    Label(engine.phase == .ready ? "本地引擎就绪" : "引擎未就绪", systemImage: engine.phase == .ready ? "checkmark.shield" : "circle.dotted")
                        .font(.caption).foregroundStyle(engine.phase == .ready ? accent : .secondary)
                    Button("设置") { delegate.showSetup() }.accessibilityIdentifier("conversation.settings")
                }
                HStack(spacing: 10) {
                    Text("操作应用").font(.subheadline.bold())
                    Picker("操作应用", selection: $model.selectedID) {
                        Text(model.selectedID.isEmpty ? "选择一个应用…" : "目标已退出，请重新选择…").tag("")
                        if !model.selectedID.isEmpty && model.selected == nil {
                            Text("目标已退出，请重新选择…").tag(model.selectedID)
                        }
                        ForEach(model.applications) { application in
                            Text("\(application.name) · \(application.pid)").tag(application.id)
                        }
                    }.labelsHidden().accessibilityIdentifier("conversation.target").disabled(model.isRunning)
                    Button { delegate.refreshApplications() } label: { Image(systemName: "arrow.clockwise") }
                        .help("刷新正在运行的应用").accessibilityLabel("刷新应用")
                }
                Text("每条消息是一条独立操作指令。发送后会切换到所选应用；默认每一步都需要你确认。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(20)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if model.turns.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("告诉 Free Hand 要做什么").font(.title3.bold())
                                Text("不必使用快捷键。先选择应用，再输入简短指令；暂未授权也可以先写好草稿。")
                                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                HStack {
                                    suggestion("输入“你好”")
                                    suggestion("Click Settings")
                                    suggestion("Search for \"Adele\"")
                                }
                                Text("这是任务对话，不是通用聊天模型。复杂自然语言规划仍是实验功能。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                                .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                        }
                        ForEach(model.turns) { turn in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack { Text("你 → \(turn.application)").font(.caption.bold()); Spacer() }
                                Text(turn.goal).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12).background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                                HStack(alignment: .top, spacing: 8) {
                                    if turn.outcome == .running { ProgressView().controlSize(.small) }
                                    else { Image(systemName: turn.outcome == .completed ? "checkmark.circle" : "stop.circle") }
                                    Text(turn.status).textSelection(.enabled).font(.callout)
                                }.foregroundStyle(turn.outcome == .stopped ? Color.orange : .secondary)
                            }.id(turn.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(20)
                }
                .onChange(of: model.turns) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if !delegate.accessibilityReady {
                    AccessibilityStatusView(delegate: delegate)
                }
                if engine.phase != .ready {
                    HStack {
                        Text(installer.running ? installer.message : engine.detail).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if installer.running || engine.phase == .loading { ProgressView().controlSize(.small) }
                        else {
                            Button(EnginePaths.installed ? "加载引擎" : "安装引擎") {
                                if EnginePaths.installed { delegate.loadEngine() } else { delegate.installEngine() }
                            }.disabled(delegate.activeTask)
                        }
                    }
                }
                if let notice = model.notice {
                    Text(notice).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("conversation.notice")
                }
                TextField("输入指令，例如：输入“你好”", text: $model.draft, axis: .vertical)
                    .lineLimit(2...5).textFieldStyle(.plain).font(.body)
                    .padding(12).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
                    .focused($inputFocused).accessibilityIdentifier("conversation.input")
                HStack {
                    Button("清空记录") { model.clear() }.disabled(model.isRunning || model.turns.isEmpty)
                    Spacer()
                    if delegate.activeTask {
                        Button("停止任务", role: .destructive) { delegate.stopTask() }.accessibilityIdentifier("conversation.stop")
                    }
                    Button("发送指令") { delegate.sendConversation() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                        .disabled(!delegate.canSubmitConversation).accessibilityIdentifier("conversation.send")
                }
                Text(delegate.submissionBlocker ?? "⌘ Return 发送 · 记录仅保存在本次会话内，不写入磁盘。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(16)
        }
        .frame(minWidth: 560, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor)).tint(accent)
        .onAppear { inputFocused = true }
        .onChange(of: model.selectedID) { delegate.refreshPermissions() }
    }
    private func suggestion(_ text: String) -> some View {
        Button(text) { model.draft = text; inputFocused = true }.font(.caption)
            .disabled(model.isRunning)
    }
}
