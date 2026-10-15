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
        XCTAssertTrue(reveal(checkButton, in: app, timeout: 10, toTap: true), "The check button should be present once the PDP is ready")
        XCTAssertTrue(checkButton.isEnabled, "The check button should be enabled once the PDP is ready")
        checkButton.tap()

        // The decisions render below the button once the engine answers, usually just past the fold.
        let readBadge = element(withIdentifier: "effect-read", in: app)
        XCTAssertTrue(reveal(readBadge, in: app, timeout: 30), "A decision for the read action should be shown after the check")

        for action in ["read", "create", "update", "delete", "publish"] {
            let badge = element(withIdentifier: "effect-\(action)", in: app)
            XCTAssertTrue(reveal(badge, in: app, timeout: 10), "A decision for the \(action) action should be shown")
            XCTAssertTrue(
                ["Allow", "Deny"].contains(badge.label),
                "The \(action) action should resolve to Allow or Deny, got “\(badge.label)”")
        }

        let duration = app.staticTexts["checkDuration"]
        XCTAssertTrue(reveal(duration, in: app, timeout: 10), "The evaluation time should be shown with the decisions")
        XCTAssertTrue(duration.label.hasPrefix("Evaluated locally in"), "Unexpected duration text: \(duration.label)")
        XCTAssertFalse(element(withIdentifier: "checkError", in: app).exists, "The check should not report an error")

        // A second check with a different principal goes through the same engine without an error.
        let adminRole = app.buttons["ADMIN"]
        XCTAssertTrue(reveal(adminRole, in: app, timeout: 10, toTap: true), "The role picker should offer ADMIN")
        adminRole.tap()
        XCTAssertTrue(reveal(checkButton, in: app, timeout: 10, toTap: true), "The check button should still be reachable")
        checkButton.tap()
        let enabledAgain = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: checkButton)
        wait(for: [enabledAgain], timeout: 30)
        XCTAssertFalse(element(withIdentifier: "checkError", in: app).exists, "The second check should not report an error")
        XCTAssertTrue(reveal(readBadge, in: app, timeout: 10), "Decisions should still be shown after the second check")
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

    /// Matches an element by identifier regardless of its accessibility type, which differs between
    /// SwiftUI containers and OS versions.
    @MainActor
    private func element(withIdentifier identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Scrolls the form until the element exists (and, with `toTap`, can be hit), or the timeout passes.
    ///
    /// Rows in a `Form` only exist while on screen. This polls `exists` rather than `waitForExistence`:
    /// a failed wait captures failure diagnostics, which can take over ten seconds on a CI simulator
    /// and would exhaust the timeout before the list is scrolled. Short, slow swipes keep each step
    /// within a screen so adjacent rows are not skipped; after a few upward swipes the search turns
    /// back towards the top in case the element was above the starting position. Hittability is only
    /// required for controls: SwiftUI reports decorative elements such as badges as not hittable even
    /// when they are fully visible, because hit-testing resolves to their row.
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval, toTap: Bool = false) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var step = 0
        while Date() < deadline {
            if element.exists, !toTap || element.isHittable {
                return true
            }
            if step % 8 < 4 {
                app.swipeUp(velocity: .slow)
            } else {
                app.swipeDown(velocity: .slow)
            }
            step += 1
        }
        return element.exists && (!toTap || element.isHittable)
    }
}
