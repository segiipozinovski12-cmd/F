import XCTest

final class CallControlsTests: XCTestCase {
    @MainActor func testMuteRouteCollapseExpandAndImmediateHangup() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--vo1d-call-controls-test"]
        app.launch()
        let mute = app.buttons["call.mute"]
        XCTAssertTrue(mute.waitForExistence(timeout: 15))
        mute.tap()
        XCTAssertEqual(mute.label, "Включить микрофон")
        mute.tap()
        XCTAssertEqual(mute.label, "Микрофон")
        app.buttons["call.route"].tap()
        let speaker = app.buttons["call.output.speaker"]
        if !speaker.isHittable { app.swipeUp() }
        XCTAssertTrue(speaker.waitForExistence(timeout: 3))
        speaker.tap()
        XCTAssertTrue(speaker.isSelected)
        app.buttons["call.output.receiver"].tap()
        XCTAssertTrue(app.buttons["call.output.receiver"].isSelected)
        app.swipeDown()
        let collapse = app.buttons["call.collapse"]
        if !collapse.isHittable { app.swipeDown() }
        collapse.tap()
        let expand = app.buttons["call.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 3))
        expand.tap()
        let end = app.buttons["call.end"]
        XCTAssertTrue(end.waitForExistence(timeout: 3))
        if !end.isHittable { app.swipeUp() }
        end.tap()
        XCTAssertFalse(end.waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["call.expand"].exists)
    }
}
