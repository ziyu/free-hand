import SwiftUI

@main
struct FreeHandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Free Hand", systemImage: "hand.raised") {
            FreeHandMenu(delegate: appDelegate, hotkey: appDelegate.hotkey)
        }
    }
}

private struct FreeHandMenu: View {
    @ObservedObject var delegate: AppDelegate
    @ObservedObject var hotkey: HotkeyManager
    var body: some View {
        Button(delegate.activeTask ? "停止任务并打开对话…" : "开始对话…") { delegate.showConversation() }
        Button("设置与权限…") { delegate.showSetup() }
        Divider()
        Button("停止当前任务") { delegate.stopTask() }.disabled(!delegate.activeTask)
        Text(hotkey.choice == .disabled ? "快捷键已关闭" : "快捷键：\(hotkey.choice.title)")
        if hotkey.state.needsAttention { Text("快捷键不可用，请在设置中更换") }
        Divider()
        Button("退出 Free Hand") { NSApp.terminate(nil) }
    }
}
