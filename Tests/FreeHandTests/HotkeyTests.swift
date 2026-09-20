import AppKit
import Carbon
import XCTest
@testable import FreeHand

@MainActor
private final class FakeHotkeyRegistrar: HotkeyRegistering {
    var onEvent: ((UInt32, Bool) -> Void)?
    var reserved = false
    var status: OSStatus = noErr
    var ids: [UInt32] = []
    var released = 0
    func isSystemReserved(_ choice: ShortcutChoice) -> Bool { reserved }
    func register(_ choice: ShortcutChoice, id: UInt32) -> OSStatus { ids.append(id); return status }
    func unregister() { released += 1 }
}

@MainActor
final class HotkeyTests: XCTestCase {
    private func withSettings(_ run: (UserDefaults) throws -> Void) rethrows {
        let suite = "FreeHandHotkeyTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try run(defaults)
    }
    func testNewDefaultDoesNotReuseOldChordAndSavedDisabledIsPreserved() {
        withSettings { defaults in
            XCTAssertEqual(ShortcutChoice.saved(in: defaults), .controlShiftSpace)
            defaults.set(ShortcutChoice.disabled.rawValue, forKey: "conversationShortcut")
            XCTAssertEqual(ShortcutChoice.saved(in: defaults), .disabled)
            defaults.set("unknown", forKey: "conversationShortcut")
            XCTAssertEqual(ShortcutChoice.saved(in: defaults), .controlShiftSpace)
        }
    }
    func testRegistrationAndOpenHaveNoAccessibilityGate() {
        withSettings { defaults in
            let registrar = FakeHotkeyRegistrar()
            var invoked = 0
            let manager = HotkeyManager(defaults: defaults, registrar: registrar) { invoked += 1 }
            manager.start()
            XCTAssertEqual(manager.state, .registered)
            registrar.onEvent?(registrar.ids.last!, true)
            XCTAssertEqual(invoked, 1)
            XCTAssertNotNil(manager.lastTriggeredAt)
            manager.stop()
        }
    }
    func testHeldKeyDoesNotOpenThenCancelAndReleaseRearmsIt() {
        withSettings { defaults in
            let registrar = FakeHotkeyRegistrar()
            var invoked = 0
            let manager = HotkeyManager(defaults: defaults, registrar: registrar) { invoked += 1 }
            manager.start()
            let id = registrar.ids.last!
            for _ in 0..<10 { registrar.onEvent?(id, true) }
            XCTAssertEqual(invoked, 1)
            registrar.onEvent?(id, false); registrar.onEvent?(id, true)
            XCTAssertEqual(invoked, 2)
            manager.stop()
        }
    }
    func testSystemConflictDoesNotAttemptRegistration() {
        withSettings { defaults in
            let registrar = FakeHotkeyRegistrar(); registrar.reserved = true
            let manager = HotkeyManager(defaults: defaults, registrar: registrar) { XCTFail("Must not trigger") }
            manager.start()
            XCTAssertEqual(manager.state, .reservedBySystem)
            XCTAssertTrue(registrar.ids.isEmpty)
            XCTAssertTrue(manager.message.contains("开始对话"))
        }
    }
    func testOccupiedChordCanBeChangedAndFailureCannotDispatchAnEvent() {
        withSettings { defaults in
            let registrar = FakeHotkeyRegistrar(); registrar.status = OSStatus(eventHotKeyExistsErr)
            var invoked = 0
            let manager = HotkeyManager(defaults: defaults, registrar: registrar) { invoked += 1 }
            manager.start()
            let staleID = registrar.ids.last!
            XCTAssertEqual(manager.state, .occupied)
            registrar.onEvent?(staleID, true)
            XCTAssertEqual(invoked, 0)
            registrar.status = noErr
            manager.select(.controlOptionShiftH)
            XCTAssertEqual(manager.state, .registered)
            XCTAssertEqual(ShortcutChoice.saved(in: defaults), .controlOptionShiftH)
            registrar.onEvent?(staleID, true)
            XCTAssertEqual(invoked, 0)
            registrar.onEvent?(registrar.ids.last!, true)
            XCTAssertEqual(invoked, 1)
            manager.stop()
        }
    }
    func testDisableUnregistersAndIgnoresQueuedInput() {
        withSettings { defaults in
            let registrar = FakeHotkeyRegistrar()
            let manager = HotkeyManager(defaults: defaults, registrar: registrar) { XCTFail("Disabled hotkey fired") }
            manager.start(); let id = registrar.ids.last!
            manager.select(.disabled)
            XCTAssertEqual(manager.state, .disabled)
            XCTAssertGreaterThanOrEqual(registrar.released, 2)
            XCTAssertEqual(registrar.ids.count, 1)
            registrar.onEvent?(id, true)
        }
    }
    func testUnknownRegistrationErrorIsVisibleAndRetryWorks() {
        withSettings { defaults in
            let registrar = FakeHotkeyRegistrar(); registrar.status = -50
            let manager = HotkeyManager(defaults: defaults, registrar: registrar) {}
            manager.start()
            XCTAssertEqual(manager.state, .failed(-50))
            XCTAssertTrue(manager.message.contains("-50"))
            registrar.status = noErr; manager.retry()
            XCTAssertEqual(manager.state, .registered)
            manager.stop()
        }
    }
    func testDisabledSystemBindingsDoNotProduceFalseConflicts() {
        let shortcut = ShortcutChoice.controlShiftSpace
        let row: [String: Any] = [kHISymbolicHotKeyEnabled as String: true,
            kHISymbolicHotKeyCode as String: shortcut.keyCode,
            kHISymbolicHotKeyModifiers as String: shortcut.modifiers]
        XCTAssertTrue(CarbonHotkeyRegistrar.matchesSystemShortcut(shortcut, entries: [row]))
        var disabled = row; disabled[kHISymbolicHotKeyEnabled as String] = false
        XCTAssertFalse(CarbonHotkeyRegistrar.matchesSystemShortcut(shortcut, entries: [disabled]))
        XCTAssertFalse(CarbonHotkeyRegistrar.matchesSystemShortcut(.commandShiftSpace, entries: [row]))
        XCTAssertFalse(CarbonHotkeyRegistrar.matchesSystemShortcut(.disabled, entries: [row]))
    }

    /// Calls the actual Carbon registrar and its native event handler. Events are
    /// sent to THIS test application's event target, never to the user's desktop.
    func testRealExclusiveRegistrationConflictReleaseAndEventDelivery() async throws {
        _ = NSApplication.shared
        let first = CarbonHotkeyRegistrar(), second = CarbonHotkeyRegistrar()
        defer { first.unregister(); second.unregister() }
        let status = first.register(.controlOptionShiftH, id: 101)
        guard status == noErr else { throw XCTSkip("Test chord is already occupied (\(status)); no other app was modified.") }
        XCTAssertEqual(second.register(.controlOptionShiftH, id: 202), OSStatus(eventHotKeyExistsErr))
        var edges: [Bool] = []
        first.onEvent = { id, down in XCTAssertEqual(id, 101); edges.append(down) }
        for kind in [kEventHotKeyPressed, kEventHotKeyReleased] {
            var event: EventRef?
            XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kind), 0, 0, &event), noErr)
            let actual = try XCTUnwrap(event)
            defer { ReleaseEvent(actual) }
            var id = EventHotKeyID(signature: CarbonHotkeyRegistrar.signature, id: 101)
            XCTAssertEqual(SetEventParameter(actual, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                numericCast(MemoryLayout<EventHotKeyID>.size), &id), noErr)
            XCTAssertEqual(SendEventToEventTarget(actual, GetApplicationEventTarget()), noErr)
            // Delivery to Swift is intentionally queued, just as in the production app.
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(edges, [true, false])
        first.unregister()
        XCTAssertEqual(second.register(.controlOptionShiftH, id: 202), noErr)
    }
}
