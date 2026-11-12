import XCTest

@MainActor
final class SwaplightUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testLiveMenuAndInspector() {
        let app = launch(fixture: false)
        openMenu(app)
        XCTAssertTrue(text(app, containing: "Memory pressure").exists)
        XCTAssertTrue(text(app, containing: "Compressed:").exists)
        app.buttons["All Processes"].click()
        let table = app.outlines["processes-table"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        XCTAssertTrue(app.windows.firstMatch.exists)
    }

    func testAppBreakdownProtectionAndQuit() {
        let app = launch()
        openMenu(app)
        app.buttons["All Apps"].click()
        let table = app.outlines["apps-table"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        let browser = row(table, containing: "Example Browser")
        XCTAssertTrue(browser.waitForExistence(timeout: 4), table.debugDescription)
        browser.click()
        let breakdown = app.buttons["View 2 Processes"]
        XCTAssertTrue(breakdown.waitForExistence(timeout: 4))
        let protection = app.switches["Keep Running"].firstMatch.exists
            ? app.switches["Keep Running"] : app.checkBoxes["Keep Running"]
        XCTAssertTrue(protection.exists)
        protection.click()
        XCTAssertTrue(text(app, containing: "Marked Keep Running.").exists)
        XCTAssertFalse(app.buttons["Quit App"].exists)
        protection.click()
        breakdown.click()
        XCTAssertTrue(app.buttons["Clear Scope"].exists)
        XCTAssertTrue(app.staticTexts["2 observed"].exists)
        app.buttons["Clear Scope"].click()
        XCTAssertTrue(app.staticTexts["7 observed"].exists)

        // Back to the same app, then verify the normal quit UI with the simulator.
        let sidebar = app.descendants(matching: .any).matching(identifier: "Sidebar").firstMatch
        row(sidebar, containing: "Apps").click()
        row(table, containing: "Example Browser").click()
        app.buttons["Quit App"].click()
        let alert = app.sheets.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["Quit App"].click()
        XCTAssertTrue(text(app, containing: "Exited.").waitForExistence(timeout: 5))
    }

    func testSearchCancelTimeoutAndSeparateForceConfirmation() {
        let app = launch()
        openMenu(app)
        app.buttons["All Processes"].click()
        let table = app.outlines["processes-table"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        search(app, "no-such-fixture")
        XCTAssertTrue(text(app, containing: "No matching processes").waitForExistence(timeout: 4))
        app.buttons["Clear Search"].click()
        search(app, "FixtureWorker")
        XCTAssertTrue(text(app, containing: "1 match").waitForExistence(timeout: 3))
        let worker = row(table, containing: "FixtureWorker")
        XCTAssertTrue(worker.exists, table.debugDescription)
        worker.click()

        let stop = app.buttons["Stop Process"]
        XCTAssertTrue(stop.waitForExistence(timeout: 4))
        stop.click()
        let alert = app.sheets.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertTrue(alert.buttons["Cancel"].exists)
        // Return should choose the non-destructive default.
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(text(app, containing: "Cancelled.").waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Review Force Stop…"].exists)

        stop.click()
        alert.buttons["Stop Process"].click()
        let force = app.buttons["Review Force Stop…"]
        XCTAssertTrue(force.waitForExistence(timeout: 8))
        force.click()
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertTrue(text(alert, containing: "Unsaved work").exists)
        alert.buttons["Cancel"].click()
        XCTAssertTrue(force.exists)
        force.click()
        alert.buttons["Force Stop"].click()
        XCTAssertTrue(text(app, containing: "Exited.").waitForExistence(timeout: 5))
    }

    private func launch(fixture: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        if fixture {
            app.launchArguments = ["--ui-fixture", "--ui-light"]
            if #available(macOS 15.0, *) { app.launchArguments += ["--ui-preview"] }
        }
        app.launch()
        return app
    }

    private func openMenu(_ app: XCUIApplication) {
        if app.windows["preview"].exists { return }
        let item = app.statusItems.firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Swaplight should expose a status item")
        item.click()
        XCTAssertTrue(app.buttons["All Apps"].waitForExistence(timeout: 4))
    }

    private func search(_ app: XCUIApplication, _ query: String) {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.click()
        field.typeText(query)
    }

    private func row(_ outline: XCUIElement, containing value: String) -> XCUIElement {
        let row = outline.descendants(matching: .outlineRow)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@ OR title CONTAINS %@", value, value, value)).firstMatch
        if row.exists { return row }
        return outline.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", value, value)).firstMatch
    }

    private func text(_ app: XCUIElement, containing value: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", value, value)).firstMatch
    }
}
