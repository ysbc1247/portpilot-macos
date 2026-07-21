import XCTest

final class DevBerthUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testOnboardingExplainsSafetyWithoutAccount() {
        let app = launchApp(onboardingCompleted: false)

        XCTAssertTrue(app.staticTexts["Make local development legible"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["No account required"].exists)
        XCTAssertTrue(app.staticTexts["Observed is not managed"].exists)
        XCTAssertTrue(app.buttons["Review Runtime"].isEnabled)

        app.buttons["Review Runtime"].click()
        XCTAssertTrue(app.staticTexts["Runtime"].waitForExistence(timeout: 5))
    }

    func testPrimaryNavigationAndKeyboardCommandPalette() {
        let app = launchApp(onboardingCompleted: true)

        XCTAssertTrue(app.staticTexts["Runtime"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Projects"].exists)
        XCTAssertTrue(app.staticTexts["Sessions"].exists)
        XCTAssertTrue(app.staticTexts["Managed Services"].exists)

        app.typeKey("k", modifierFlags: .command)
        let search = app.textFields["Open, search, or run a safe action"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.typeText("Open Settings")
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5))
    }

    func testRuntimeEvidenceFilteringAndEmptyState() {
        let app = launchApp(onboardingCompleted: true)

        XCTAssertTrue(app.staticTexts["devberth-ui-fixture"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Observed host process"].exists)
        XCTAssertTrue(app.staticTexts["Inferred restart candidate"].exists)

        let search = app.searchFields["Ports, processes, projects"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.click()
        search.typeText("no-such-runtime")
        XCTAssertTrue(app.staticTexts["No matching runtime"].waitForExistence(timeout: 3))

        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["devberth-ui-fixture"].waitForExistence(timeout: 3))
    }

    func testRuntimeGracefulStopConfirmationCancelsWithEscape() {
        let app = launchApp(onboardingCompleted: true)
        let fixture = app.staticTexts["devberth-ui-fixture"]
        XCTAssertTrue(fixture.waitForExistence(timeout: 8))

        let stop = app.buttons["Stop"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 3))
        XCTAssertTrue(stop.isHittable)
        stop.click()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        assertDisappears(cancel)
        XCTAssertTrue(fixture.waitForExistence(timeout: 3))
    }

    func testPrimaryDestinationEmptyStatesExposeNamedActions() {
        let app = launchApp(onboardingCompleted: true)

        XCTAssertTrue(app.staticTexts["Runtime"].waitForExistence(timeout: 8))
        app.staticTexts["Projects"].firstMatch.click()
        XCTAssertTrue(app.buttons["New Project"].waitForExistence(timeout: 3))

        app.staticTexts["Sessions"].firstMatch.click()
        XCTAssertTrue(app.buttons["Capture Session"].waitForExistence(timeout: 3))

        app.staticTexts["Managed Services"].firstMatch.click()
        XCTAssertTrue(app.buttons["New Managed Service"].waitForExistence(timeout: 3))
    }

    func testSettingsExposePermissionAndMCPRepairActions() {
        let app = launchApp(onboardingCompleted: true)
        XCTAssertTrue(app.staticTexts["Runtime"].waitForExistence(timeout: 8))

        app.staticTexts["Settings"].firstMatch.click()

        XCTAssertTrue(app.buttons["Open Full Disk Access Settings"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Set Up / Repair Codex MCP"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Global Codex configuration"].exists)
    }

    func testEscapeDismissesCommandPaletteAndCustomSheets() {
        let app = launchApp(onboardingCompleted: true)
        XCTAssertTrue(app.staticTexts["Runtime"].waitForExistence(timeout: 8))

        app.typeKey("k", modifierFlags: .command)
        let commandSearch = app.textFields["Open, search, or run a safe action"]
        XCTAssertTrue(commandSearch.waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        assertDisappears(commandSearch)

        app.staticTexts["Projects"].firstMatch.click()
        let newProject = app.buttons["New Project"].firstMatch
        XCTAssertTrue(newProject.waitForExistence(timeout: 3))
        newProject.click()
        let createProject = app.buttons["Create"].firstMatch
        XCTAssertTrue(createProject.waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        assertDisappears(createProject)

        app.staticTexts["Sessions"].firstMatch.click()
        let captureSession = app.buttons["Capture Session"].firstMatch
        XCTAssertTrue(captureSession.waitForExistence(timeout: 3))
        captureSession.click()
        let capture = app.buttons["Capture"].firstMatch
        XCTAssertTrue(capture.waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        assertDisappears(capture)

        app.staticTexts["Managed Services"].firstMatch.click()
        let newService = app.buttons["New Managed Service"].firstMatch
        XCTAssertTrue(newService.waitForExistence(timeout: 3))
        newService.click()
        let saveDraft = app.buttons["Save Draft"].firstMatch
        XCTAssertTrue(saveDraft.waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        assertDisappears(saveDraft)
    }

    private func launchApp(onboardingCompleted: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DEVBERTH_UI_TESTING"] = "1"
        app.launchArguments += [
            "-devberth.onboarding.completed", onboardingCompleted ? "YES" : "NO",
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launch()
        return app
    }

    private func assertDisappears(
        _ element: XCUIElement,
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: timeout),
            .completed,
            file: file,
            line: line
        )
    }
}
