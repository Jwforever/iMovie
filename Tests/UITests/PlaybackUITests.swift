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
        app.tabBars.buttons["首页"].tap()
        app.buttons["home-source-picker"].tap()
        let source = app.buttons["source-fixture"]
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
        app.staticTexts["播放验证样片 · 第 1 集"].firstMatch.tap()
        assertPlaying()
        app.buttons["完成"].tap()
        app.segmentedControls.buttons["播放记录"].tap()
        XCTAssertTrue(app.staticTexts["播放验证样片 · 第 1 集"].firstMatch.exists)
        app.tabBars.buttons["首页"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["最近播放"].waitForExistence(timeout: 5))
        capture("12-home-with-recent")
    }

    func testWebPageFindsMediaAndOpensSystemPlayer() throws {
        app.buttons["home-open-link"].tap()
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

    func testUserConfigAndDM84WebMedia() throws {
        app.terminate()
        app.launchEnvironment["IMOVIE_CONFIG_URL"] = "http://www.饭太硬.cc/tv"
        app.launch()
        app.tabBars.buttons["设置"].tap()
        app.buttons["config-import"].tap()
        XCTAssertTrue(app.staticTexts["兼容情况"].waitForExistence(timeout: 35))
        capture("07-user-config-imported")
        app.tabBars.buttons["首页"].tap()
        app.buttons["home-source-picker"].tap()
        let source = app.buttons["source-Dm84"]
        for _ in 0..<5 {
            if source.exists && source.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(source.exists)
        source.tap()
        let query = app.textFields["site-search-query"]
        XCTAssertTrue(query.waitForExistence(timeout: 10))
        query.tap()
        query.typeText("神厨狂后\n")
        let video = app.staticTexts["神厨狂后"].firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 35))
        capture("08-dm84-search")
        video.tap()
        let episode = app.buttons["12"].firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 35))
        capture("09-dm84-episodes")
        episode.tap()
        XCTAssertTrue(app.buttons["系统播放"].waitForExistence(timeout: 45))
        capture("10-dm84-web-media-detected")
        app.buttons["系统播放"].tap()
        assertPlaying()
        capture("11-dm84-system-playing")
    }

    func testHomeSourceSelectionCategoryAndPersistence() throws {
        app.tabBars.buttons["设置"].tap()
        app.buttons["config-import"].tap()
        XCTAssertTrue(app.staticTexts["兼容情况"].waitForExistence(timeout: 15))
        app.tabBars.buttons["首页"].tap()
        XCTAssertTrue(app.staticTexts["热播推荐"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["category-1"].exists)
        capture("13-home-recommendations")
        app.buttons["category-1"].tap()
        XCTAssertTrue(app.staticTexts["测试分类"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["home-source-picker"].tap()
        app.buttons["source-fixture-two"].tap()
        XCTAssertTrue(app.staticTexts["第二来源样片"].waitForExistence(timeout: 10))
        capture("14-home-source-switched")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["第二来源样片"].waitForExistence(timeout: 10))
    }

    func testAueteBrowseEpisodesAndSearchVerification() throws {
        app.terminate()
        app.launchEnvironment["IMOVIE_CONFIG_URL"] = "http://www.饭太硬.cc/tv"
        app.launch()
        app.tabBars.buttons["设置"].tap()
        app.buttons["config-import"].tap()
        XCTAssertTrue(app.staticTexts["兼容情况"].waitForExistence(timeout: 35))
        app.tabBars.buttons["首页"].tap()
        app.buttons["home-source-picker"].tap()
        let source = app.buttons["source-奥特"]
        for _ in 0..<5 {
            if source.exists && source.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(source.exists)
        source.tap()
        let query = app.textFields["site-search-query"]
        XCTAssertTrue(query.waitForExistence(timeout: 10))
        let video = app.staticTexts["折月亮"].firstMatch
        for _ in 0..<4 {
            if video.exists && video.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(video.waitForExistence(timeout: 35))
        capture("15-auete-home")
        video.tap()
        XCTAssertTrue(app.buttons["第1集"].firstMatch.waitForExistence(timeout: 30))
        capture("16-auete-episodes")
        app.buttons["第1集"].firstMatch.tap()
        XCTAssertTrue(app.buttons["系统播放"].waitForExistence(timeout: 50))
        capture("17-auete-web-media")
        app.buttons["系统播放"].tap()
        assertPlaying()
        capture("18-auete-system-playing")
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
