import XCTest

/// Launches the demo and waits for the PDP to reach `Ready`. Needs network access to Cerbos Hub.
final class epdpdemoUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEngineBecomesReady() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.buttons["hubSettingsButton"].waitForExistence(timeout: 10),
            "The Cerbos Hub settings toolbar button should be present after launch")

        let statusTitle = app.staticTexts["statusTitle"]
        XCTAssertTrue(statusTitle.waitForExistence(timeout: 10), "The status banner should be present after launch")

        let ready = expectation(for: NSPredicate(format: "label == %@", "Ready"), evaluatedWith: statusTitle)
        // The app's startTimeout is 120 s; allow for that plus a slow, shared CI simulator.
        wait(for: [ready], timeout: 180)
    }
}
