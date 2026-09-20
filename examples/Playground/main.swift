import AppKit

/// Benign, disposable native UI for testing. No network, files, or user accounts.
final class Playground: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let field = NSTextField(string: "")
    let status = NSTextField(labelWithString: "Ready. Search for a name.")
    let toggle = NSButton(checkboxWithTitle: "Dark mode", target: nil, action: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Free Hand Playground"
        window.isReleasedWhenClosed = false
        let heading = NSTextField(labelWithString: "A safe place to lend a hand")
        heading.font = .systemFont(ofSize: 23, weight: .bold)
        field.placeholderString = "Search contacts"
        field.setAccessibilityLabel("Search contacts")
        field.target = self; field.action = #selector(search)
        let button = NSButton(title: "Search", target: self, action: #selector(search))
        button.bezelStyle = .rounded
        toggle.target = self; toggle.action = #selector(toggleMode)
        status.setAccessibilityLabel("Search result")
        let help = NSTextField(wrappingLabelWithString: "Try: Search for \"Adele\" · 输入“你好” · Click Dark mode\nOnly this disposable window is changed. No personal data is used.")
        help.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [heading, field, button, toggle, status, help])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func search() { status.stringValue = "Showing results for: \(field.stringValue)" }
    @objc func toggleMode() {
        window.appearance = NSAppearance(named: toggle.state == .on ? .darkAqua : .aqua)
        status.stringValue = "Dark mode \(toggle.state == .on ? "enabled" : "disabled")"
    }
}

let app = NSApplication.shared
let delegate = Playground()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
