import XCTest
@testable import FreeHand

@MainActor
final class TextEntryPlanTests: XCTestCase {
    func testSearchCandidatesNeverIncludeOldScreenContent() {
        let candidates = TextEntryPlan.candidates("search for Ninajirachi")
        XCTAssertEqual(candidates.first, "Ninajirachi")
        XCTAssertFalse(candidates.contains { $0.localizedCaseInsensitiveContains("skyfall") || $0.localizedCaseInsensitiveContains("adele") })
    }

    func testLiteralCommandIsPreservedWithoutAddedCommands() throws {
        let command = "cd '/tmp/My Project'"
        let plan = try TextEntryPlan.build(kind: "literal", content: command, terminal: true)
        XCTAssertEqual(plan.text, command)
        XCTAssertThrowsError(try TextEntryPlan.build(kind: "change_directory", content: "/tmp", terminal: true))
        XCTAssertThrowsError(try TextEntryPlan.build(kind: "unsupported", content: "go into my project", terminal: true))
    }

    func testExplicitTextDoesNotNeedASecondModelOrOldScreenContent() async throws {
        let transport = FixtureTransport()
        let client = DecisionClient(transport: transport)
        let field = AccessibilityElement(id: 1, role: "AXTextField", label: "Search", value: "Skyfall Adele", enabled: true, actions: [], axElement: nil)
        let plan = try await client.selectText(goal: "search for Ninajirachi", field: field, appName: "Spotify", terminal: false)
        XCTAssertEqual(plan.kind, "literal")
        XCTAssertEqual(plan.text, "Ninajirachi")
        XCTAssertTrue(transport.calls.isEmpty)
    }

    func testChineseAndUnicodeRemainExactUserText() async throws {
        let client = DecisionClient(transport: FixtureTransport())
        let field = testElement(1, role: "AXTextField")
        for goal in ["输入“你好🌏”", "请输入「你好🌏」。", "在搜索框输入“你好🌏”"] {
            let plan = try await client.selectText(goal: goal, field: field, appName: "Test", terminal: false)
            XCTAssertEqual(plan.text, "你好🌏")
        }
    }

    func testGeneratedWritingIsRejected() async {
        let client = DecisionClient(transport: FixtureTransport())
        do {
            _ = try await client.selectText(goal: "Write a new essay about cats", field: testElement(1, role: "AXTextField"), appName: "Test", terminal: false)
            XCTFail("Writing must not be generated")
        } catch { XCTAssertTrue(error.localizedDescription.contains("quotes")) }
    }

    func testMultilineAndNullCannotBecomeTerminalInput() {
        for text in ["one\ntwo", "one\rtwo", "one\0two"] {
            XCTAssertThrowsError(try TextEntryPlan.build(kind: "literal", content: text, terminal: true))
        }
    }
}
