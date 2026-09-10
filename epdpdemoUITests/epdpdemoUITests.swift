import XCTest

/// Launches the demo and waits for the embedded PDP to reach `Ready`, which exercises the web view
/// host, the WASM engine and a real policy bundle download from Cerbos Hub on the simulator.
///
/// Requires network access to `api.cerbos.cloud`.
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
        wait(for: [ready], timeout: 120)
    }
}
