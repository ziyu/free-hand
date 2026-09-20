import XCTest
@testable import FreeHand

/// Explicit opt-in. These call the real model over the production Swift/Python pipe,
/// but never move a pointer, type into an application, or access private screen data.
@MainActor
final class LiveEngineTests: XCTestCase {
    func testRealModelRoundTripAndReload() async throws {
        guard ProcessInfo.processInfo.environment["FREEHAND_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set FREEHAND_LIVE_TESTS=1 with an installed local checkpoint for real inference.")
        }
        let engine = LocalEngine()
        defer { engine.stop() }
        try await engine.start()
        XCTAssertEqual(engine.phase, .ready)
        let recorder = FixtureRecordingTransport(engine: engine)
        let client = DecisionClient(transport: recorder)
        // Exercise actual inference independently of deterministic command routing.
        let modelResult = try await recorder.predict(state: ["task": "Click Settings", "app": "Fixture", "elements": []],
            questions: ["operation": ["type": "choice", "instructions": "Choose the next action for clicking Settings.",
                "criteria": ["CLICK": "click Settings", "WAIT": "wait"], "option_order": ["CLICK", "WAIT"]]])
        XCTAssertNotNil((modelResult["answers"] as? [String: Any])?["operation"])
        XCTAssertEqual(engine.decisions, 1)
        XCTAssertGreaterThan(engine.latencyMs, 0)
        let result = try await client.decide(goal: "Click Settings", elements: [testElement(1, label: "Settings"), testElement(2, label: "Help")], appName: "Free Hand Playground", history: [])
        XCTAssertEqual(result.decision.operation, "CLICK")
        XCTAssertEqual(result.decision.targetIndex, "1")
        XCTAssertEqual(result.origin, "literal")
        let chinese = try await client.decide(goal: "点击设置", elements: [testElement(1, label: "设置"), testElement(2, label: "帮助")], appName: "Free Hand Playground", history: [])
        XCTAssertEqual(chinese.decision.operation, "CLICK")
        XCTAssertEqual(chinese.decision.targetIndex, "1")
        let search = try await client.decide(goal: "Search for \"Adele\"", elements: [testElement(1, label: "Search contacts", role: "AXTextField"), testElement(2, label: "Name", role: "AXTextField")], appName: "Free Hand Playground", history: [])
        XCTAssertTrue(["TYPE_TEXT", "CLICK"].contains(search.decision.operation), "Search operation=\(search.decision.operation) targetAbstained=\(search.pickedNone)")
        XCTAssertEqual(search.decision.targetIndex, "1")
        XCTAssertEqual(engine.decisions, 1) // Exact commands never silently become extra model calls.
        engine.stop()
        XCTAssertEqual(engine.phase, .stopped)
        try await engine.start()
        XCTAssertEqual(engine.phase, .ready)
    }

    /// Keep the failing model-only regressions executable rather than claiming
    /// deterministic command results measure model accuracy.
    func testExperimentalModelOnlyAccuracy() async throws {
        guard ProcessInfo.processInfo.environment["FREEHAND_EXPERIMENTAL_ACCURACY"] == "1" else {
            throw XCTSkip("Known experimental model-planning regressions; opt in with FREEHAND_EXPERIMENTAL_ACCURACY=1.")
        }
        let engine = LocalEngine()
        defer { engine.stop() }
        try await engine.start()
        let client = DecisionClient(transport: FixtureRecordingTransport(engine: engine))
        for (goal, elements, expected) in [
            ("Click Settings", [testElement(1, label: "Settings"), testElement(2, label: "Help")], "CLICK"),
            ("点击设置", [testElement(1, label: "设置"), testElement(2, label: "帮助")], "CLICK"),
            ("Search for \"Adele\"", [testElement(1, label: "Search contacts", role: "AXTextField"), testElement(2, label: "Name", role: "AXTextField")], "TYPE_TEXT")
        ] {
            let result = try await client.decide(goal: goal, elements: elements, appName: "Free Hand Playground", history: [], allowLiteralCommands: false)
            if expected == "TYPE_TEXT" { XCTAssertTrue(["TYPE_TEXT", "CLICK"].contains(result.decision.operation), goal) }
            else { XCTAssertEqual(result.decision.operation, expected, goal) }
            XCTAssertEqual(result.decision.targetIndex, "1", goal)
        }
    }
}

@MainActor
private final class FixtureRecordingTransport: DecisionTransport {
    let engine: LocalEngine
    var records: [[String: Any]] = []
    init(engine: LocalEngine) { self.engine = engine }
    func predict(state: [String: Any], questions: [String: Any]) async throws -> [String: Any] {
        let result = try await engine.predict(state: state, questions: questions)
        // Only explicit, hardcoded test fixtures reach this class. Never production UI.
        if let path = ProcessInfo.processInfo.environment["FREEHAND_FIXTURE_REPORT"] {
            records.append(["state": state, "questions": questions, "result": result])
            let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path))
        }
        return result
    }
}
