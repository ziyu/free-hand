import AppKit
import SwiftUI
import XCTest
@testable import FreeHand

@MainActor
final class ConversationTests: XCTestCase {
    private let first = ConversationApplication(pid: 100, bundleIdentifier: "test.editor", name: "Editor", launched: Date(timeIntervalSince1970: 10))
    private let other = ConversationApplication(pid: 200, bundleIdentifier: "test.browser", name: "Browser", launched: Date(timeIntervalSince1970: 11))
    private func model() -> ConversationModel {
        let model = ConversationModel(); model.refresh([first, other], preferred: first.id); return model
    }
    func testOpeningDoesNotNeedEnginePermissionsOrASelectedApplication() async throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        defer { delegate.conversationWindow?.orderOut(nil); delegate.setupWindow?.orderOut(nil); delegate.hotkey.stop() }
        XCTAssertEqual(delegate.engine.phase, .stopped)
        delegate.showSetup()
        let view = try XCTUnwrap(delegate.setupWindow?.contentView)
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        let button = try XCTUnwrap(AppDelegate.launchButton(in: view))
        XCTAssertTrue(button.isEnabled)
        button.performClick(nil)
        XCTAssertTrue(delegate.conversationWindow?.isVisible == true)
        XCTAssertFalse(delegate.activeTask)
        XCTAssertEqual(delegate.engine.phase, .stopped)
        XCTAssertFalse(delegate.canSubmitConversation)
        XCTAssertFalse(delegate.conversation.applications.contains { $0.bundleIdentifier == "com.feibai.freehand" })
        let window = delegate.conversationWindow
        delegate.conversation.draft = "输入“你好”"
        window?.performClose(nil)
        button.performClick(nil)
        XCTAssertTrue(window === delegate.conversationWindow)
        XCTAssertEqual(delegate.conversation.draft, "输入“你好”")
        // No permissions/inference/UI writes are authorized by merely clicking Open.
        XCTAssertTrue(delegate.conversation.turns.isEmpty)
        XCTAssertEqual(delegate.engine.decisions, 0)
    }
    func testHotkeyEntryAlsoOpensWithoutEngineAndPreservesDraft() {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        defer { delegate.conversationWindow?.orderOut(nil); delegate.hotkey.stop() }
        delegate.handleHotkey()
        XCTAssertTrue(delegate.conversationWindow?.isVisible == true)
        delegate.conversation.draft = "draft"
        let window = delegate.conversationWindow
        delegate.handleHotkey()
        XCTAssertTrue(window === delegate.conversationWindow)
        XCTAssertEqual(delegate.conversation.draft, "draft")
        XCTAssertFalse(delegate.activeTask)
    }
    func testMissingPrerequisiteDoesNotEraseOrQueueDraft() {
        let delegate = AppDelegate()
        delegate.conversation.draft = "输入“你好”"
        delegate.sendConversation()
        XCTAssertEqual(delegate.conversation.draft, "输入“你好”")
        XCTAssertTrue(delegate.conversation.turns.isEmpty)
        XCTAssertNotNil(delegate.conversation.notice)
        XCTAssertFalse(delegate.activeTask)
    }
    func testRefreshingDoesNotSilentlyRetargetToAnotherApp() {
        let model = model(); model.draft = "keep me"
        model.refresh([other])
        XCTAssertNil(model.selected)
        XCTAssertEqual(model.selectedID, first.id)
        XCTAssertEqual(model.draft, "keep me")
        XCTAssertThrowsError(try model.begin(goal: "Click", application: first))
    }
    func testPIDReuseChangesIdentity() {
        let relaunched = ConversationApplication(pid: first.pid, bundleIdentifier: first.bundleIdentifier,
            name: first.name, launched: Date(timeIntervalSince1970: 20))
        XCTAssertNotEqual(first.id, relaunched.id)
        let model = model(); model.refresh([relaunched])
        XCTAssertNil(model.selected)
    }
    func testOnlySuccessfulBeginClearsDraftAndDoubleSubmitFails() throws {
        let model = model(); model.draft = "Click Settings"
        XCTAssertThrowsError(try model.begin(goal: "  ", application: first))
        XCTAssertEqual(model.draft, "Click Settings")
        let id = try model.begin(goal: model.draft, application: first)
        XCTAssertEqual(model.draft, "")
        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(model.turns.last?.application, first.name)
        XCTAssertThrowsError(try model.begin(goal: "second", application: first))
        model.refresh([first, other], preferred: other.id)
        XCTAssertEqual(model.selectedID, first.id)
        model.finish(.cancelled, message: "Stopped", id: id)
        XCTAssertFalse(model.isRunning)
    }
    func testLateCallbacksCannotRewriteACompletedOrNewTurn() throws {
        let model = model()
        let old = try model.begin(goal: "First", application: first)
        model.finish(.cancelled, message: "Cancelled", id: old)
        let new = try model.begin(goal: "Second", application: first)
        model.update("late success", id: old)
        model.finish(.completed, message: "late done", id: old)
        XCTAssertEqual(model.activeID, new)
        XCTAssertEqual(model.turns.first?.outcome, .cancelled)
        XCTAssertEqual(model.turns.last?.status, "准备执行…")
        model.update("Waiting approval", id: new)
        model.finish(.stopped, message: "Not completed", id: new)
        XCTAssertEqual(model.turns.last?.outcome, .stopped)
        XCTAssertFalse(model.isRunning)
    }
    func testConversationAndErrorSizeAreBoundedAndClearDoesNotEraseAnActiveTurn() throws {
        let model = model()
        for index in 0..<45 {
            let id = try model.begin(goal: "Task \(index)", application: first)
            model.finish(.completed, message: "Done", id: id)
        }
        XCTAssertEqual(model.turns.count, 40)
        let id = try model.begin(goal: "Keep", application: first)
        model.update(String(repeating: "x", count: 5000), id: id)
        XCTAssertEqual(model.turns.last?.status.count, 1000)
        model.clear()
        XCTAssertEqual(model.turns.count, 40)
        model.finish(.cancelled, message: "Stopped", id: id)
        model.clear()
        XCTAssertTrue(model.turns.isEmpty)
    }
    func testOversizedGoalIsRejectedBeforeCreatingHistory() {
        let model = model()
        XCTAssertThrowsError(try model.begin(goal: String(repeating: "你", count: 1400), application: first))
        XCTAssertTrue(model.turns.isEmpty)
        XCTAssertFalse(model.isRunning)
    }
    func testOwnApplicationIsAlwaysExcluded() {
        XCTAssertFalse(AppTarget.isAllowed(NSRunningApplication.current))
        XCTAssertNil(ConversationApplication(NSRunningApplication.current))
        XCTAssertNil(AppTarget.capture(application: NSRunningApplication.current))
    }
}
