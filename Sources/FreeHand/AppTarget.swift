import AppKit
import ApplicationServices

struct AppTarget {
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
    let application: NSRunningApplication
    let appElement: AXUIElement
    let windowElement: AXUIElement?
    let windowFrame: NSRect?
    let icon: NSImage?

    static func captureCurrentApp() -> AppTarget? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            Log.info("captureCurrentApp: no frontmost app")
            return nil
        }
        return capture(application: frontApp)
    }

    static func isAllowed(_ application: NSRunningApplication) -> Bool {
        let ignoredBundles: Set<String> = [
            Bundle.main.bundleIdentifier ?? "",
            "com.feibai.freehand",
            "com.apple.SecurityAgent",
            "com.apple.loginwindow",
            "com.apple.UserNotificationCenter",
        ]
        guard !application.isTerminated, application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundleId = application.bundleIdentifier, !ignoredBundles.contains(bundleId) else { return false }
        return true
    }

    static func capture(application frontApp: NSRunningApplication) -> AppTarget? {
        guard isAllowed(frontApp), let bundleId = frontApp.bundleIdentifier else {
            Log.info("Target rejected: own app or protected system process")
            return nil
        }
        let pid = frontApp.processIdentifier
        Log.info("Captured target pid=\(pid)")
        let appElement = AXUIElementCreateApplication(pid)
        let windowElement = focusedWindow(of: appElement)
        let frame = windowElement.flatMap { windowFrame(of: $0) }

        return AppTarget(
            pid: pid,
            name: frontApp.localizedName ?? "Unknown",
            bundleIdentifier: bundleId,
            application: frontApp,
            appElement: appElement,
            windowElement: windowElement,
            windowFrame: frame,
            icon: frontApp.icon
        )
    }

    private static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func windowFrame(of window: AXUIElement) -> NSRect? {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }

        guard let posValue, let sizeValue, CFGetTypeID(posValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

        guard let primaryScreen = NSScreen.screens.first else { return nil }
        let screenHeight = primaryScreen.frame.height
        let appKitY = screenHeight - position.y - size.height

        return NSRect(x: position.x, y: appKitY, width: size.width, height: size.height)
    }
}
