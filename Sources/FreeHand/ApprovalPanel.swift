import AppKit
import SwiftUI

/// A nonactivating panel preserves the target application's keyboard focus.
@MainActor
final class ApprovalPanel: NSPanel {
    init(target: AppTarget, decision: AgentDecision, label: String, completion: @escaping (Bool) -> Void) {
        let size = NSSize(width: 380, height: 220)
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        super.init(contentRect: CGRect(x: screen.maxX - size.width - 20, y: screen.maxY - size.height - 20,
                                      width: size.width, height: size.height),
                   styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Free Hand · Review action"
        level = .floating
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView: ApprovalView(app: target.name, operation: decision.operation,
            label: label, text: decision.textValue, key: decision.key, completion: completion))
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct ApprovalView: View {
    let app: String
    let operation: String
    let label: String
    let text: String?
    let key: String?
    let completion: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("One action in \(app)", systemImage: "hand.raised.fill").font(.headline)
            Text("\(operation.replacingOccurrences(of: "_", with: " ")) · \(key ?? label)")
                .font(.subheadline).lineLimit(2)
            if let text {
                Text(String(text.prefix(140))).font(.system(.body, design: .monospaced)).lineLimit(3)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            } else { Text("The target will be checked again before input is sent.").font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            HStack {
                Button("Stop task") { completion(false) }
                Spacer()
                Button("Allow once") { completion(true) }.buttonStyle(.borderedProminent)
            }
        }.padding(18).frame(width: 380, height: 220)
    }
}
