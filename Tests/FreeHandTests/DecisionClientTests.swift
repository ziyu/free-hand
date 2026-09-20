import XCTest
@testable import FreeHand

func testElement(_ id: Int, label: String = "Settings", role: String = "AXButton", enabled: Bool = true) -> AccessibilityElement {
    AccessibilityElement(id: id, role: role, label: label,
        value: ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) ? "" : nil,
        enabled: enabled, actions: [], axElement: nil)
}

@MainActor
final class FixtureTransport: DecisionTransport {
    var calls: [([String: Any], [String: Any])] = []
    var replies: [[String: Any]] = []
    func predict(state: [String: Any], questions: [String: Any]) async throws -> [String: Any] {
        calls.append((state, questions))
        guard !replies.isEmpty else { throw ControllerError.invalid("Unexpected fixture call") }
        return replies.removeFirst()
    }
}

@MainActor
final class DecisionClientTests: XCTestCase {
    func testOnlyEnabledCompatibleNonsecureTargetsAreOffered() {
        let targets = DecisionClient.targets([testElement(1), testElement(2, role: "AXTextField"),
            testElement(3, enabled: false), testElement(4, role: "AXStaticText"),
            testElement(5, label: "Password", role: "AXTextField")])
        XCTAssertEqual(Set(targets["CLICK"]!.keys), ["1", "2"])
        XCTAssertEqual(Set(targets["TYPE_TEXT"]!.keys), ["2"])
    }

    func testLateRelevantTargetSurvivesSmallLocalShortlist() {
        var elements = (1...500).map { testElement($0, label: "Unrelated \($0)") }
        elements.append(testElement(501, label: "Export"))
        let offered = DecisionClient.offeredTargets(elements, goal: "Click Export")
        XCTAssertEqual(offered["CLICK"]?.count, 4)
        XCTAssertNotNil(offered["CLICK"]?["501"])
        XCTAssertNil(offered["CLICK"]?["500"])
        let response = Data(#"{"answers":{"operation":{"choice":"CLICK"},"click_target":{"choice":"500"}}}"#.utf8)
        XCTAssertThrowsError(try DecisionClient.decode(response, elements: elements, offered: offered))
    }

    func testNoneAbstainsAndWrongOperationDoesNotBecomeInput() throws {
        let data = Data(#"{"answers":{"operation":{"choice":"CLICK"},"click_target":{"choice":"__none__"}}}"#.utf8)
        let result = try DecisionClient.decode(data, elements: [testElement(1)])
        XCTAssertEqual(result.decision.operation, "BLOCKED")
        XCTAssertTrue(result.pickedNone)
        for operation in ["SHELL", "OPEN_URL", "TYPE_TEXT"] {
            let data = try JSONSerialization.data(withJSONObject: ["answers": ["operation": ["choice": operation]]])
            XCTAssertThrowsError(try DecisionClient.decode(data, elements: [testElement(1)]))
        }
    }

    func testGoalNeverSilentlyTruncatedAndSecureDataExcluded() throws {
        XCTAssertThrowsError(try DecisionClient.state(goal: String(repeating: "a", count: 4001), elements: [], appName: "T", history: []))
        XCTAssertThrowsError(try DecisionClient.state(goal: " ", elements: [], appName: "T", history: []))
        let state = try DecisionClient.state(goal: "Click settings", elements: [testElement(1), testElement(2, label: "Password", role: "AXTextField")], appName: "Test", history: [])
        XCTAssertEqual((state["elements"] as? [[String: Any]])?.count, 1)
        XCTAssertNil(state["screenshots"])
        XCTAssertNil(state["messages"])
    }

    func testCompletionAsksOnlyCompletionAndDoesNotAcceptNegativeCheck() async throws {
        let transport = FixtureTransport()
        transport.replies = [["answers": ["done": ["noul": 0.1]]], ["answers": ["done": ["noul": 0.95]]]]
        let client = DecisionClient(transport: transport)
        let first = try await client.confirmCompletion(goal: "Search", elements: [], appName: "Test", history: [])
        let second = try await client.confirmCompletion(goal: "Search", elements: [], appName: "Test", history: [])
        XCTAssertFalse(first)
        XCTAssertTrue(second)
        XCTAssertTrue(transport.calls.allSatisfy { Set($0.1.keys) == ["done"] })
    }

    func testDefaultReviewCoversEveryMutationAndAutoStillGatesText() {
        let elements = [testElement(1), testElement(2, label: "Delete account"), testElement(3, label: "删除")]
        for decision in [AgentDecision(operation: "CLICK", targetIndex: "1"), AgentDecision(operation: "SCROLL_DOWN"),
                         AgentDecision(operation: "KEY_PRESS", key: "tab")] {
            XCTAssertTrue(SafetyPolicy.requiresApproval(decision, elements: elements, bundle: nil, reviewEveryAction: true))
        }
        for decision in [AgentDecision(operation: "TYPE_TEXT"), AgentDecision(operation: "KEY_PRESS", key: "return"),
                         AgentDecision(operation: "CLICK_TEXT"), AgentDecision(operation: "CLICK", targetIndex: "2"),
                         AgentDecision(operation: "CLICK", targetIndex: "3")] {
            XCTAssertTrue(SafetyPolicy.requiresApproval(decision, elements: elements, bundle: nil, reviewEveryAction: false))
        }
        XCTAssertTrue(SafetyPolicy.requiresApproval(AgentDecision(operation: "KEY_PRESS", key: "tab"), elements: [], bundle: "com.apple.Terminal", reviewEveryAction: false))
        XCTAssertFalse(SafetyPolicy.requiresApproval(AgentDecision(operation: "WAIT"), elements: [], bundle: nil, reviewEveryAction: true))
    }

    func testSecureTargetRejectedEvenWithCraftedDecision() {
        XCTAssertThrowsError(try AgentDecision(operation: "TYPE_TEXT", targetIndex: "1", textValue: "secret")
            .validate(elements: [testElement(1, label: "密码", role: "AXTextField")], hasScreenshot: false))
    }

    func testActionsAreGroundedBeforeAskingTheModel() {
        let choices = DecisionClient.operationChoices(goal: "Click Settings", elements: [testElement(1)])
        XCTAssertEqual(Set(choices.keys), ["CLICK", "DONE", "WAIT", "BLOCKED"])
        let emptyField = testElement(1, label: "Search", role: "AXTextField")
        XCTAssertNil(DecisionClient.operationChoices(goal: "Search for cats", elements: [emptyField])["PRESS_RETURN"])
        let fullField = AccessibilityElement(id: 1, role: "AXTextField", label: "Search", value: "cats", enabled: true,
            actions: [], axElement: nil, focused: true)
        XCTAssertNotNil(DecisionClient.operationChoices(goal: "Search for cats", elements: [fullField])["PRESS_RETURN"])
        XCTAssertNotNil(DecisionClient.operationChoices(goal: "向下滚动", elements: [testElement(1)])["SCROLL_DOWN"])
        XCTAssertNotNil(DecisionClient.operationChoices(goal: "Press Tab", elements: [emptyField])["PRESS_TAB"])
        XCTAssertNotNil(DecisionClient.operationChoices(goal: "Press Escape", elements: [testElement(1)])["PRESS_ESCAPE"])
    }

    func testKnownEmptyFieldsAreNotSerializedAsUnknown() throws {
        let state = try DecisionClient.state(goal: "Search for cats", elements: [testElement(1, label: "Search", role: "AXTextField")], appName: "Fixture", history: [])
        let elements = try XCTUnwrap(state["elements"] as? [[String: Any]])
        XCTAssertEqual(elements[0]["value"] as? String, "")
    }

    func testLiteralSearchPreparationIsGroundedAndCannotResubmitForever() {
        let goal = "Search for \"Adele\""
        let empty = testElement(1, label: "Search contacts", role: "AXTextField")
        XCTAssertEqual(DecisionClient.actionObjective(goal: goal, elements: [empty], history: []), "Type \"Adele\" into the \"Search contacts\" search field.")
        let full = AccessibilityElement(id: 1, role: "AXTextField", label: "Search contacts", value: "Adele", enabled: true, actions: [], axElement: nil, focused: true)
        XCTAssertTrue(DecisionClient.actionObjective(goal: goal, elements: [full], history: []).hasPrefix("Press Return"))
        XCTAssertEqual(DecisionClient.actionObjective(goal: goal, elements: [full], history: [ActionHistory(action: "KEY_PRESS target=none text= key=return", result: "changed")]), goal)
        XCTAssertEqual(DecisionClient.actionObjective(goal: goal, elements: [empty, testElement(2, label: "Search pages", role: "AXTextField")], history: []), goal)
        XCTAssertEqual(DecisionClient.actionObjective(goal: "Write an essay", elements: [empty], history: []), "Write an essay")
    }
}
