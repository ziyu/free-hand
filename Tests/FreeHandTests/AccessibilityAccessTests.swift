import ApplicationServices
import XCTest
@testable import FreeHand

final class AccessibilityAccessTests: XCTestCase {
    private func evidence(trusted: Bool = false, posting: Bool = false, error: AXError? = nil,
                          readable: Bool = false, target: Int32? = 200) -> AccessibilityAccessSnapshot {
        AccessibilityAccessSnapshot(trusted: trusted, eventPosting: posting, processID: 100,
            probeProcessID: target, probeError: error?.rawValue, windowsReadable: readable)
    }

    func testUncheckedCannotAuthorizeInput() {
        XCTAssertEqual(AccessibilityAccessSnapshot.unchecked.state, .unchecked)
        XCTAssertFalse(AccessibilityAccessSnapshot.unchecked.canControl)
    }
    func testAuthoritativeTrustAndInputPreflightAreAccepted() {
        let value = evidence(trusted: true, posting: true, error: .success, readable: true)
        XCTAssertEqual(value.state, .authorized)
        XCTAssertTrue(value.canControl)
    }
    func testStaleFalseTrustRequiresBothExternalReadAndOSInputPermission() {
        let value = evidence(posting: true, error: .success, readable: true)
        XCTAssertEqual(value.state, .verifiedCapabilities)
        XCTAssertTrue(value.canControl)
        XCTAssertFalse(value.trusted) // Never rewrite the actual OS evidence to make it look consistent.
        XCTAssertTrue(value.message.contains("暂未同步"))
    }
    func testReadOnlyAccessCannotAuthorizeSynthesizingInput() {
        XCTAssertFalse(evidence(error: .success, readable: true).canControl)
        XCTAssertEqual(evidence(error: .success, readable: true).state, .inputUnavailable)
        XCTAssertFalse(evidence(trusted: true).canControl)
    }
    func testPostingAccessAloneCannotAuthorizeAXControl() {
        XCTAssertFalse(evidence(posting: true).canControl)
        XCTAssertFalse(evidence(posting: true, error: .success, readable: false).canControl)
    }
    func testExplicitAPIDenialOverridesAllPositiveAndStaleSignals() {
        for trusted in [false, true] {
            for posting in [false, true] {
                for readable in [false, true] {
                    let denied = evidence(trusted: trusted, posting: posting, error: .apiDisabled, readable: readable)
                    XCTAssertFalse(denied.canControl)
                    XCTAssertEqual(denied.state, .notEffective)
                }
            }
        }
    }
    func testSelfOrMissingTargetCannotServeAsExternalEvidence() {
        for target: Int32? in [nil, 0, -1, 100] {
            XCTAssertFalse(evidence(posting: true, error: .success, readable: true, target: target).canControl)
        }
    }
    func testUnresponsiveUnsupportedAndEmptyTargetsDoNotBecomeFalseDenials() {
        for error: AXError in [.cannotComplete, .noValue, .attributeUnsupported, .notImplemented] {
            let authorized = evidence(trusted: true, posting: true, error: error)
            XCTAssertTrue(authorized.canControl)
            XCTAssertTrue(authorized.probeDescription.contains("不是未授权结论"))
            XCTAssertFalse(evidence(posting: true, error: error).canControl)
        }
    }
    func testRefreshUsesNewEvidenceInsteadOfLatchingAGrant() {
        var current = evidence(trusted: true, posting: true, error: .success, readable: true)
        XCTAssertTrue(current.canControl)
        current = evidence(error: .apiDisabled)
        XCTAssertFalse(current.canControl)
        current = evidence(posting: true, error: .success, readable: true)
        XCTAssertTrue(current.canControl)
    }
    func testNotEffectiveDoesNotClaimTheUserHasNotEnabledSettings() {
        let value = evidence(error: .apiDisabled)
        XCTAssertTrue(value.message.contains("不代表你没有开启"))
        XCTAssertFalse(value.message.contains("尚未开启"))
        XCTAssertTrue(value.diagnostics.contains("AXError -25211"))
    }
    func testUnknownFailureNeverManufacturesReadAccess() {
        let unknown = AccessibilityAccessSnapshot(trusted: false, eventPosting: true, processID: 100,
            probeProcessID: 200, probeError: -99999, windowsReadable: true)
        XCTAssertFalse(unknown.canControl)
        XCTAssertEqual(unknown.probeDescription, "读取状态 -99999")
    }
    func testDiagnosticContainsIdentityAndEvidenceWithoutObservedContents() throws {
        let identity = RunningAppIdentity(bundleIdentifier: "test.app", bundlePath: "/test/Free Hand.app",
            version: "test", processID: 100, codeHash: "1234", designatedRequirement: "test", signatureValid: true, adHoc: true)
        let report = PermissionDiagnosticReport(identity: identity, evidence: evidence(error: .apiDisabled))
        let data = try JSONEncoder().encode(report)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["scope", "identity", "evidence", "accessState"])
        XCTAssertEqual(json["accessState"] as? String, "notEffective")
        XCTAssertTrue(identity.signingExplanation.contains("签名哈希"))
        let roundtrip = try JSONDecoder().decode(AccessibilityAccessSnapshot.self,
            from: JSONEncoder().encode(evidence(posting: true, error: .success, readable: true)))
        XCTAssertTrue(roundtrip.canControl)
    }

    @MainActor
    func testRefreshUpdatesUIAndSubmissionTogetherWithoutQueuingOrErasingDraft() {
        var current = evidence(error: .apiDisabled)
        let delegate = AppDelegate(permissionCheck: { _ in current })
        let target = ConversationApplication(pid: 12345, bundleIdentifier: "fixture", name: "Fixture", launched: nil)
        delegate.conversation.refresh([target], preferred: target.id)
        delegate.conversation.draft = "输入“你好”"
        delegate.refreshPermissions()
        XCTAssertFalse(delegate.accessibilityReady)
        XCTAssertEqual(delegate.submissionBlocker, current.message)
        delegate.conversation.notice = current.message
        current = evidence(posting: true, error: .success, readable: true)
        delegate.refreshPermissions()
        XCTAssertTrue(delegate.accessibilityReady)
        XCTAssertTrue(delegate.submissionBlocker?.contains("引擎") == true)
        XCTAssertNil(delegate.conversation.notice)
        XCTAssertEqual(delegate.conversation.draft, "输入“你好”")
        XCTAssertTrue(delegate.conversation.turns.isEmpty)
        XCTAssertFalse(delegate.activeTask)
        current = evidence(error: .apiDisabled)
        delegate.refreshPermissions()
        XCTAssertFalse(delegate.accessibilityReady)
        XCTAssertEqual(delegate.submissionBlocker, current.message)
    }

    @MainActor
    func testPermissionRefreshDoesNotClearOtherErrors() {
        let delegate = AppDelegate(permissionCheck: { _ in self.evidence(trusted: true, posting: true) })
        delegate.conversation.notice = "目标应用已退出。"
        delegate.refreshPermissions()
        XCTAssertEqual(delegate.conversation.notice, "目标应用已退出。")
    }
}
