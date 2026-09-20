import AppKit
import Carbon

enum ShortcutChoice: String, CaseIterable, Identifiable {
    case controlShiftSpace, commandShiftSpace, controlOptionSpace, controlOptionShiftH, disabled
    var id: String { rawValue }
    var title: String {
        switch self {
        case .controlShiftSpace: return "⌃ ⇧ Space"
        case .commandShiftSpace: return "⌘ ⇧ Space"
        case .controlOptionSpace: return "⌃ ⌥ Space（旧快捷键）"
        case .controlOptionShiftH: return "⌃ ⌥ ⇧ H"
        case .disabled: return "关闭快捷键 · 仅使用按钮"
        }
    }
    var keyCode: UInt32 { self == .controlOptionShiftH ? UInt32(kVK_ANSI_H) : UInt32(kVK_Space) }
    var modifiers: UInt32 {
        switch self {
        case .controlShiftSpace: return UInt32(controlKey | shiftKey)
        case .commandShiftSpace: return UInt32(cmdKey | shiftKey)
        case .controlOptionSpace: return UInt32(controlKey | optionKey)
        case .controlOptionShiftH: return UInt32(controlKey | optionKey | shiftKey)
        case .disabled: return 0
        }
    }
    static func saved(in defaults: UserDefaults) -> Self {
        // The old event tap had no saved binding. New installs and that version
        // move to Ctrl-Shift-Space; an explicitly saved choice is never replaced.
        defaults.string(forKey: "conversationShortcut").flatMap(Self.init(rawValue:)) ?? .controlShiftSpace
    }
}

enum ShortcutState: Equatable {
    case stopped, disabled, registered, reservedBySystem, occupied, failed(Int32)
    var isRegistered: Bool { self == .registered }
    var needsAttention: Bool {
        switch self { case .reservedBySystem, .occupied, .failed: return true; default: return false }
    }
    func message(for choice: ShortcutChoice) -> String {
        switch self {
        case .stopped: return "快捷键尚未注册；可以直接点击“开始对话”。"
        case .disabled: return "快捷键已关闭；使用“开始对话”按钮或菜单栏入口。"
        case .registered: return "已注册 \(choice.title)。按一次打开对话；任务运行时按一次停止。"
        case .reservedBySystem: return "该组合已被 macOS 系统快捷键使用。请选择其他组合，或直接点击“开始对话”。"
        case .occupied: return "该组合已被其他热键注册占用。请选择其他组合，或直接点击“开始对话”。"
        case .failed(let code): return "快捷键注册失败（\(code)）。可重新检测、换键，或直接点击“开始对话”。"
        }
    }
}

@MainActor
protocol HotkeyRegistering: AnyObject {
    var onEvent: ((UInt32, Bool) -> Void)? { get set }
    func isSystemReserved(_ choice: ShortcutChoice) -> Bool
    func register(_ choice: ShortcutChoice, id: UInt32) -> OSStatus
    func unregister()
}

/// Opens Free Hand, not another app: registration does NOT depend on AX/TCC.
/// No global event tap, keyboard logging, or permission-polling registration loop.
@MainActor
final class HotkeyManager: ObservableObject {
    @Published private(set) var choice: ShortcutChoice
    @Published private(set) var state: ShortcutState = .stopped
    @Published private(set) var lastTriggeredAt: Date?
    private let registrar: any HotkeyRegistering
    private let defaults: UserDefaults
    private let onTrigger: () -> Void
    private var registrationID: UInt32 = 0
    private var held = false

    init(defaults: UserDefaults = .standard, registrar: (any HotkeyRegistering)? = nil,
         onTrigger: @escaping () -> Void) {
        self.defaults = defaults
        self.choice = ShortcutChoice.saved(in: defaults)
        self.registrar = registrar ?? CarbonHotkeyRegistrar()
        self.onTrigger = onTrigger
        self.registrar.onEvent = { [weak self] id, pressed in self?.handle(id: id, pressed: pressed) }
    }
    var isRunning: Bool { state.isRegistered }
    var message: String { state.message(for: choice) }

    func start() { registerChoice() }
    func select(_ choice: ShortcutChoice) {
        self.choice = choice
        defaults.set(choice.rawValue, forKey: "conversationShortcut")
        registerChoice()
    }
    func retry() { registerChoice() }
    func stop() {
        registrationID &+= 1
        held = false
        registrar.unregister()
        state = .stopped
    }
    private func registerChoice() {
        stop()
        lastTriggeredAt = nil
        guard choice != .disabled else { state = .disabled; return }
        guard !registrar.isSystemReserved(choice) else { state = .reservedBySystem; return }
        let status = registrar.register(choice, id: registrationID)
        switch status {
        case noErr: state = .registered
        case OSStatus(eventHotKeyExistsErr): state = .occupied
        default: state = .failed(status)
        }
        if state != .registered { registrar.unregister() }
    }
    private func handle(id: UInt32, pressed: Bool) {
        guard state == .registered, id == registrationID else { return }
        if !pressed { held = false; return }
        guard !held else { return } // A held shortcut must not open then immediately cancel.
        held = true
        lastTriggeredAt = Date()
        onTrigger()
    }
}

/// Public Carbon hotkey API; exclusive registration reports a real conflict.
/// CopySymbolicHotKeys detects enabled system bindings. Third-party event taps
/// may still intercept keys; the UI therefore offers alternate bindings/buttons.
@MainActor
final class CarbonHotkeyRegistrar: HotkeyRegistering {
    nonisolated static let signature: OSType = 0x46484B59 // FHKY
    var onEvent: ((UInt32, Bool) -> Void)?
    private var handler: EventHandlerRef?
    private var hotkey: EventHotKeyRef?
    fileprivate var registeredID: UInt32?

    func isSystemReserved(_ choice: ShortcutChoice) -> Bool {
        var items: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&items) == noErr,
              let items = items?.takeRetainedValue() as? [[String: Any]] else { return false }
        return Self.matchesSystemShortcut(choice, entries: items)
    }
    nonisolated static func matchesSystemShortcut(_ choice: ShortcutChoice, entries: [[String: Any]]) -> Bool {
        guard choice != .disabled else { return false }
        return entries.contains { row in
            (row[kHISymbolicHotKeyEnabled as String] as? Bool) == true
                && (row[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value == choice.keyCode
                && (row[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value == choice.modifiers
        }
    }
    func register(_ choice: ShortcutChoice, id: UInt32) -> OSStatus {
        unregister()
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let result = InstallEventHandler(GetApplicationEventTarget(), freeHandHotkeyCallback,
            numericCast(types.count), &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { return result }
        let status = RegisterEventHotKey(choice.keyCode, choice.modifiers,
            EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &hotkey)
        if status == noErr { registeredID = id } else { unregister() }
        return status
    }
    func unregister() {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
        hotkey = nil; handler = nil; registeredID = nil
    }
    deinit {
        // AppDelegate owns this on the main thread and explicitly stops on exit.
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

private func freeHandHotkeyCallback(_ next: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let data else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, numericCast(MemoryLayout<EventHotKeyID>.size), nil, &id) == noErr,
          id.signature == CarbonHotkeyRegistrar.signature else { return OSStatus(eventNotHandledErr) }
    let registrar = Unmanaged<CarbonHotkeyRegistrar>.fromOpaque(data).takeUnretainedValue()
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    let registrationID = id.id
    // Application event handlers run on the main event loop. An unrelated
    // registration must be passed on, not swallowed by our handler.
    return MainActor.assumeIsolated {
        guard registrar.registeredID == registrationID else { return OSStatus(eventNotHandledErr) }
        Task { @MainActor [weak registrar] in
            guard registrar?.registeredID == registrationID else { return }
            registrar?.onEvent?(registrationID, pressed)
        }
        return noErr
    }
}
