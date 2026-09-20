import XCTest
@testable import FreeHand

@MainActor
final class LiteralCommandTests: XCTestCase {
    func testExactEnglishAndChineseControlsDoNotNeedModelReinterpretation() async throws {
        let transport = FixtureTransport()
        let client = DecisionClient(transport: transport)
        for (goal, label) in [("Click Settings", "Settings"), ("点击设置", "设置")] {
            let result = try await client.decide(goal: goal, elements: [testElement(1, label: label), testElement(2, label: "Help")], appName: "Fixture", history: [])
            XCTAssertEqual(result.origin, "literal")
            XCTAssertEqual(result.decision.operation, "CLICK")
            XCTAssertEqual(result.decision.targetIndex, "1")
        }
        XCTAssertTrue(transport.calls.isEmpty)
    }

    func testAmbiguousDisabledAndSecureControlsDoNotGetABypass() {
        let command = LiteralCommand.click("Settings")
        XCTAssertNil(command.action(elements: [testElement(1), testElement(2)], history: []))
        XCTAssertNil(command.action(elements: [testElement(1, enabled: false)], history: []))
        XCTAssertNil(LiteralCommand.click("Password").action(elements: [testElement(1, label: "Password", role: "AXTextField")], history: []))
        XCTAssertNil(command.action(elements: [testElement(1, label: "Unrelated")], history: []))
    }

    func testExactTypingNeedsUniqueOrFocusedFieldAndPreservesUnicode() {
        let command = LiteralCommand.parse("输入“你好🌏”")!
        let fields = [testElement(1, role: "AXTextField"), testElement(2, role: "AXTextField")]
        XCTAssertNil(command.action(elements: fields, history: []))
        let decision = command.action(elements: [fields[0]], history: [])
        XCTAssertEqual(decision?.operation, "TYPE_TEXT")
        XCTAssertEqual(decision?.textValue, "你好🌏")
        XCTAssertTrue(SafetyPolicy.requiresApproval(decision!, elements: fields, bundle: nil, reviewEveryAction: true))
        let full = AccessibilityElement(id: 1, role: "AXTextField", label: "Message", value: "你好🌏", enabled: true, actions: [], axElement: nil)
        XCTAssertTrue(command.exactValueSatisfied([full]))
        XCTAssertEqual(command.action(elements: [full], history: [])?.operation, "DONE")
    }

    func testSearchIsGroundedAndNeverResubmits() {
        let command = LiteralCommand.search("Adele")
        let empty = testElement(1, label: "Search contacts", role: "AXTextField")
        let unrelated = testElement(2, label: "Name", role: "AXTextField")
        let first = command.action(elements: [empty, unrelated], history: [])
        XCTAssertEqual(first?.operation, "TYPE_TEXT")
        XCTAssertEqual(first?.targetIndex, "1")
        XCTAssertEqual(first?.textValue, "Adele")
        let full = AccessibilityElement(id: 1, role: "AXTextField", label: "Search contacts", value: "Adele", enabled: true, actions: [], axElement: nil, focused: true)
        XCTAssertEqual(command.action(elements: [full], history: [])?.key, "return")
        let attempted = [ActionHistory(action: "KEY_PRESS target=none text= key=return", result: "Execution failed")]
        XCTAssertEqual(command.action(elements: [full], history: attempted)?.operation, "DONE")
        XCTAssertFalse(command.exactValueSatisfied([full])) // Search is not completed merely by filling a field.
        XCTAssertFalse(command.isSingleAction)
        XCTAssertNil(command.action(elements: [empty, testElement(3, label: "Search pages", role: "AXTextField")], history: []))
    }

    func testUnsupportedWritingAndCompoundTasksAreNotInvented() {
        XCTAssertNil(LiteralCommand.parse("Write a beautiful essay"))
        XCTAssertNil(LiteralCommand.parse("search for whales then open the first result"))
        XCTAssertNil(LiteralCommand.parse("press return then delete everything"))
        XCTAssertNil(LiteralCommand.parse("输入"))
        XCTAssertEqual(LiteralCommand.parse("Scroll down"), .scroll(up: false))
        XCTAssertEqual(LiteralCommand.parse("按回车"), .key("return"))
    }

    func testLiteralPathCannotBypassTextSafetyValidation() throws {
        let field = testElement(1, role: "AXTextField")
        for text in ["one\ntwo", "one\rtwo", "one\0two"] {
            let decision = try XCTUnwrap(LiteralCommand.type(text).action(elements: [field], history: []))
            XCTAssertThrowsError(try decision.validate(elements: [field], hasScreenshot: false))
        }
    }
}
