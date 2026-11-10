import XCTest

final class PlaybackUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["IMOVIE_DEFAULTS_SUITE"] = "local.imovie.tests.\(UUID().uuidString)"
        app.launchEnvironment["IMOVIE_CONFIG_URL"] = "http://127.0.0.1:8765/tv"
        app.launch()
    }

    func testImportBrowsePlayAndBookmark() throws {
        app.tabBars.buttons["设置"].tap()
        app.buttons["config-import"].tap()
        XCTAssertTrue(app.staticTexts["兼容情况"].waitForExistence(timeout: 15))
        app.tabBars.buttons["片库"].tap()
        let source = app.buttons["source-fixture"]
        app.swipeUp()
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        capture("01-library-configured")
        source.tap()
        XCTAssertTrue(app.staticTexts["播放验证样片"].waitForExistence(timeout: 10))
        app.staticTexts["播放验证样片"].firstMatch.tap()
        XCTAssertTrue(app.buttons["第 1 集"].waitForExistence(timeout: 10))
        capture("02-episodes")
        app.buttons["第 1 集"].tap()
        assertPlaying()
        capture("03-native-playing")
        app.buttons["收藏"].tap()
        app.buttons["完成"].tap()
        app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(app.staticTexts["播放验证样片 · 第 1 集"].firstMatch.waitForExistence(timeout: 5))
        capture("04-bookmark")
        app.segmentedControls.buttons["播放记录"].tap()
        XCTAssertTrue(app.staticTexts["播放验证样片 · 第 1 集"].firstMatch.exists)
    }

    func testWebPageFindsMediaAndOpensSystemPlayer() throws {
        app.switches["library-web-mode"].tap()
        let address = app.textFields["library-direct-url"]
        address.tap()
        address.typeText("http://127.0.0.1:8765/web\n")
        XCTAssertTrue(app.buttons["系统播放"].waitForExistence(timeout: 15))
        capture("05-web-media-detected")
        app.buttons["系统播放"].tap()
        assertPlaying()
        capture("06-web-to-native-playing")
    }

    private func assertPlaying() {
        let player = app.descendants(matching: .any).matching(identifier: "native-player").firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 10))
        let predicate = NSPredicate(format: "value == %@", "playing")
        expectation(for: predicate, evaluatedWith: player)
        waitForExpectations(timeout: 20)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
