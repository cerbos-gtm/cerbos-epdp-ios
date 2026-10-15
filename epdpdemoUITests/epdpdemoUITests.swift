import XCTest

/// Drives the demo through its real UI: the PDP starts from Cerbos Hub, then a check is run from the
/// form and its decisions are shown. Needs network access to Cerbos Hub.
final class epdpdemoUITests: XCTestCase {

    /// The app's startTimeout is 120 s; allow for that plus a slow, shared CI simulator.
    private static let readyTimeout: TimeInterval = 180

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEngineBecomesReady() throws {
        _ = try launchAndWaitUntilReady()
    }

    @MainActor
    func testCheckShowsADecisionForEveryAction() throws {
        let app = try launchAndWaitUntilReady()

        let checkButton = app.buttons["checkButton"]
        XCTAssertTrue(checkButton.waitForExistence(timeout: 10), "The check button should be present once the PDP is ready")
        scrollIntoView(checkButton, in: app)
        XCTAssertTrue(checkButton.isEnabled, "The check button should be enabled once the PDP is ready")
        checkButton.tap()

        // The first badge appears once the decision is back from the engine; the rest render in the same update.
        let readBadge = element(withIdentifier: "effect-read", in: app)
        XCTAssertTrue(waitScrolling(for: readBadge, in: app, timeout: 30), "A decision for the read action should be shown after the check")

        for action in ["read", "create", "update", "delete", "publish"] {
            let badge = element(withIdentifier: "effect-\(action)", in: app)
            XCTAssertTrue(waitScrolling(for: badge, in: app, timeout: 5), "A decision for the \(action) action should be shown")
            XCTAssertTrue(
                ["Allow", "Deny"].contains(badge.label),
                "The \(action) action should resolve to Allow or Deny, got “\(badge.label)”")
        }

        let duration = app.staticTexts["checkDuration"]
        XCTAssertTrue(waitScrolling(for: duration, in: app, timeout: 5), "The evaluation time should be shown with the decisions")
        XCTAssertTrue(duration.label.hasPrefix("Evaluated locally in"), "Unexpected duration text: \(duration.label)")
        XCTAssertFalse(element(withIdentifier: "checkError", in: app).exists, "The check should not report an error")

        // A second check with a different principal goes through the same engine without an error.
        let adminRole = app.buttons["ADMIN"]
        XCTAssertTrue(waitScrolling(for: adminRole, in: app, timeout: 5, direction: .down), "The role picker should offer ADMIN")
        adminRole.tap()
        scrollIntoView(checkButton, in: app)
        checkButton.tap()
        let enabledAgain = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: checkButton)
        wait(for: [enabledAgain], timeout: 30)
        XCTAssertFalse(element(withIdentifier: "checkError", in: app).exists, "The second check should not report an error")
        XCTAssertTrue(waitScrolling(for: readBadge, in: app, timeout: 5), "Decisions should still be shown after the second check")
        XCTAssertTrue(["Allow", "Deny"].contains(readBadge.label), "Unexpected decision after the second check: \(readBadge.label)")
    }

    // MARK: - Helpers

    /// Launches the app and waits for the status banner to read `Ready`.
    @MainActor
    private func launchAndWaitUntilReady() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.buttons["hubSettingsButton"].waitForExistence(timeout: 10),
            "The Cerbos Hub settings toolbar button should be present after launch")

        let statusTitle = app.staticTexts["statusTitle"]
        XCTAssertTrue(statusTitle.waitForExistence(timeout: 10), "The status banner should be present after launch")

        let ready = expectation(for: NSPredicate(format: "label == %@", "Ready"), evaluatedWith: statusTitle)
        wait(for: [ready], timeout: Self.readyTimeout)
        return app
    }

    private enum ScrollDirection {
        case up, down
    }

    /// Matches an element by identifier regardless of its accessibility type, which differs between
    /// SwiftUI containers and OS versions.
    @MainActor
    private func element(withIdentifier identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Rows in a `Form` only exist while on screen, so waiting for one may need the list scrolled.
    @MainActor
    @discardableResult
    private func waitScrolling(
        for element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval, direction: ScrollDirection = .up
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var swipes = 0
        while true {
            if element.waitForExistence(timeout: min(2, max(0.5, deadline.timeIntervalSinceNow))) {
                return true
            }
            guard Date() < deadline, swipes < 6 else { return false }
            swipes += 1
            switch direction {
            case .up: app.swipeUp()
            case .down: app.swipeDown()
            }
        }
    }

    /// Scrolls until the element can be tapped.
    @MainActor
    private func scrollIntoView(_ element: XCUIElement, in app: XCUIApplication) {
        var swipes = 0
        while !element.isHittable, swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        if !element.isHittable {
            swipes = 0
            while !element.isHittable, swipes < 6 {
                app.swipeDown()
                swipes += 1
            }
        }
    }
}
