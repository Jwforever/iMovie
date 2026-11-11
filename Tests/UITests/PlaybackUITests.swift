import XCTest

final class PlaybackUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["IMOVIE_DEFAULTS_SUITE"] = "local.imovie.tests.\(UUID().uuidString)"
        app.launchEnvironment["IMOVIE_CONFIG_URL"] = "http://127.0.0.1:8765/tv"
        app.launchEnvironment["IMOVIE_DOUBAN_URL"] = "http://127.0.0.1:8765/douban"
        app.launch()
    }

    override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait }

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
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "native-player").firstMatch.exists)
        capture("02-episodes")
        app.buttons["第 1 集"].tap()
        assertPlaying()
        capture("03-native-playing")
        app.buttons["收藏"].tap()
        app.buttons["detail-back"].tap()
        app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(app.staticTexts["播放验证样片 · 第 1 集"].firstMatch.waitForExistence(timeout: 5))
        capture("04-bookmark")
        app.staticTexts["播放验证样片 · 第 1 集"].firstMatch.tap()
        assertPlaying()
        app.buttons["完成"].tap()
        app.segmentedControls.buttons["播放记录"].tap()
        XCTAssertTrue(app.staticTexts["播放验证样片 · 第 1 集"].firstMatch.exists)
        app.tabBars.buttons["首页"].tap()
        XCTAssertTrue(app.staticTexts["最近播放"].waitForExistence(timeout: 5))
        capture("12-home-with-recent")
    }

    func testHTTPExtractionAutomaticallyPlaysWithoutWebPage() throws {
        app.buttons["home-open-link"].tap()
        let webMode = app.switches["library-web-mode"]
        webMode.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(webMode.value as? String, "1")
        let address = app.textFields["library-direct-url"]
        address.tap()
        address.typeText("http://127.0.0.1:8765/web\n")
        assertPlaying()
        XCTAssertEqual(app.webViews.count, 0)
        XCTAssertFalse(app.buttons["系统播放"].exists)
        capture("06-http-to-native-playing")
    }

    func testUserConfigAndDM84WebMedia() throws {
        app.terminate()
        app.launchEnvironment["IMOVIE_CONFIG_URL"] = "http://www.饭太硬.cc/tv"
        app.launchEnvironment.removeValue(forKey: "IMOVIE_DOUBAN_URL")
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
        if !video.waitForExistence(timeout: 65) {
            // Public-site network availability is separate from deterministic app regressions.
            let networkError = app.staticTexts.matching(NSPredicate(format:
                "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
                "无法连接服务器", "找不到服务器", "请求超时")).firstMatch
            if networkError.exists {
                capture("21-dm84-source-network-error")
                throw XCTSkip("DM84 live site could not be reached from this runner; playback was verified in earlier runs. See screenshot 21 and validation.md.")
            }
            XCTFail("动漫巴士搜索未返回结果，且不是可识别的外部网络故障")
            return
        }
        capture("08-dm84-search")
        video.tap()
        let episode = app.buttons["12"].firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 35))
        capture("09-dm84-episodes")
        episode.tap()
        assertPlaying()
        XCTAssertEqual(app.webViews.count, 0)
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
        app.tabBars.buttons["搜索"].tap()
        let query = app.textFields["global-search-query"]
        query.tap()
        query.typeText("样片\n")
        let summary = app.staticTexts["search-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        let completed = NSPredicate(format: "label CONTAINS %@", "2 个有结果")
        expectation(for: completed, evaluatedWith: summary)
        waitForExpectations(timeout: 10)
        capture("20-global-search-results")
        let hits = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-hit-"))
        XCTAssertEqual(hits.element(boundBy: 0).identifier, "search-hit-fixture-two|exact")
        app.buttons["search-filter-fixture"].tap()
        XCTAssertTrue(app.buttons["search-hit-fixture|exact"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["search-hit-fixture-two|exact"].exists)
        capture("22-global-search-filtered")
        app.buttons["search-filter-all"].tap()
        XCTAssertTrue(app.buttons["search-hit-fixture-two|exact"].waitForExistence(timeout: 5))
        app.tabBars.buttons["首页"].tap()
        app.tabBars.buttons["搜索"].tap()
        XCTAssertFalse(app.buttons["search-hit-fixture-two|exact"].exists)
        XCTAssertEqual(app.textFields["global-search-query"].value as? String, "搜索影片、剧集或视频")
    }

    func testAueteBrowseEpisodesAndSearchVerification() throws {
        app.terminate()
        app.launchEnvironment["IMOVIE_CONFIG_URL"] = "http://www.饭太硬.cc/tv"
        app.launchEnvironment.removeValue(forKey: "IMOVIE_DOUBAN_URL")
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
        let video = app.buttons["video-card-/Tv/neidi/zheyueliang/"]
        XCTAssertTrue(video.waitForExistence(timeout: 30))
        capture("31-live-douban-home")
        // Short drags keep the poster below the pinned header. Full-screen swipes
        // can oscillate past it when the live carousel changes the page height.
        for _ in 0..<10 {
            if video.exists && video.isHittable && video.frame.minY > 220 && video.frame.maxY < app.frame.height - 100 { break }
            let midpoint = video.exists ? video.frame.midY : app.frame.height
            let distance = max(-220, min(220, app.frame.height * 0.52 - midpoint))
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55 + distance / app.frame.height))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(video.isHittable && video.frame.minY > 220 && video.frame.maxY < app.frame.height - 100)
        capture("15-auete-home")
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(app.buttons["第1集"].firstMatch.waitForExistence(timeout: 30))
        capture("16-auete-episodes")
        app.buttons["第1集"].firstMatch.tap()
        assertPlaying()
        XCTAssertEqual(app.webViews.count, 0)
        capture("18-auete-system-playing")
        app.buttons["detail-back"].tap()
        query.tap()
        query.typeText("折月亮\n")
        let status = app.staticTexts["折月亮"].firstMatch
        let verification = app.buttons["source-verify"]
        let ready = NSPredicate { _, _ in status.exists || verification.exists }
        expectation(for: ready, evaluatedWith: nil)
        waitForExpectations(timeout: 35)
        if verification.exists {
            verification.tap()
            XCTAssertTrue(app.buttons["验证完成，重试"].waitForExistence(timeout: 10))
            capture("19-auete-search-verification")
            app.buttons["source-verification-close"].tap()
        }
    }

    func testWholePosterTapTargetsAndLazyEmbeddedPlaybackSurviveRotation() throws {
        app.tabBars.buttons["设置"].tap()
        app.buttons["config-import"].tap()
        XCTAssertTrue(app.staticTexts["兼容情况"].waitForExistence(timeout: 15))
        app.tabBars.buttons["首页"].tap()
        let card = app.buttons["video-card-1"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        app.swipeUp()
        for point in [CGVector(dx: 0.12, dy: 0.12), CGVector(dx: 0.85, dy: 0.12), CGVector(dx: 0.5, dy: 0.4), CGVector(dx: 0.12, dy: 0.65)] {
            card.coordinate(withNormalizedOffset: point).tap()
            XCTAssertTrue(app.buttons["episode-第 1 集"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "native-player").firstMatch.exists)
            app.buttons["detail-back"].tap()
        }
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        app.buttons["episode-第 1 集"].tap()
        assertPlaying()
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "detail-introduction").firstMatch.exists)
        let session = app.descendants(matching: .any).matching(identifier: "playback-session").firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        let before = (session.value as? String ?? "").components(separatedBy: "|")
        XCTAssertEqual(before.count, 3)
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = orientation
            assertPlaying()
            let after = (session.value as? String ?? "").components(separatedBy: "|")
            XCTAssertEqual(after.first, before.first, "旋转不能更换播放会话")
            let advanced = NSPredicate { _, _ in
                let value = (session.value as? String ?? "").components(separatedBy: "|")
                return value.count == 3 && value[2] == "frame" && (Int(value[1]) ?? 0) > (Int(after[1]) ?? 0)
            }
            expectation(for: advanced, evaluatedWith: nil)
            waitForExpectations(timeout: 8)
            capture(orientation == .portrait ? "24-inline-portrait" : "23-inline-landscape")
        }
        XCTAssertFalse(app.buttons["1.25×"].exists)
        app.buttons["detail-back"].tap()
    }

    func testHomeContentAndAbout() throws {
        app.tabBars.buttons["设置"].tap()
        app.buttons["config-import"].tap()
        XCTAssertTrue(app.staticTexts["兼容情况"].waitForExistence(timeout: 15))
        app.tabBars.buttons["首页"].tap()
        XCTAssertTrue(app.staticTexts["热播推荐"].waitForExistence(timeout: 10))
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "video-card-")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        capture("25-home-content")
        first.tap()
        XCTAssertTrue(app.buttons["episode-第 1 集"].waitForExistence(timeout: 5))
        app.buttons["detail-back"].tap()
        app.tabBars.buttons["设置"].tap()
        for _ in 0..<4 {
            if app.buttons["settings-about"].exists && app.buttons["settings-about"].isHittable { break }
            app.swipeUp()
        }
        app.buttons["settings-about"].tap()
        XCTAssertTrue(app.staticTexts["by Chris Wei"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.links["about-github"].exists || app.buttons["about-github"].exists)
        capture("26-about-imovie")
    }

    func testPosterCacheSurvivesRelaunchAndClearDownloadsAgain() throws {
        let key = UUID().uuidString
        app.terminate()
        app.launchEnvironment["IMOVIE_CONFIG_URL"] = "http://127.0.0.1:8765/tv?image=" + key
        app.launch()
        app.tabBars.buttons["设置"].tap()
        app.buttons["config-import"].tap()
        XCTAssertTrue(app.staticTexts["兼容情况"].waitForExistence(timeout: 15))
        app.tabBars.buttons["首页"].tap()
        XCTAssertTrue(app.buttons["video-card-1"].waitForExistence(timeout: 10))
        app.swipeUp()
        app.buttons["video-card-1"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(app.buttons["episode-第 1 集"].waitForExistence(timeout: 5))
        XCTAssertEqual(try imageRequests(key), 1)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["video-card-1"].waitForExistence(timeout: 10))
        XCTAssertEqual(try imageRequests(key), 1, "应用重启后应从磁盘复用海报")
        app.tabBars.buttons["设置"].tap()
        for _ in 0..<4 {
            if app.buttons["clear-image-cache"].exists && app.buttons["clear-image-cache"].isHittable { break }
            app.swipeUp()
        }
        app.buttons["clear-image-cache"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["video-card-1"].waitForExistence(timeout: 10))
        app.swipeUp()
        app.buttons["video-card-1"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(app.buttons["episode-第 1 集"].waitForExistence(timeout: 5))
        XCTAssertEqual(try imageRequests(key), 2, "清理后才重新请求海报")
        capture("27-poster-cache")
    }

    func testUnknownAndroidSourceOpensGenericPipelineAndReportsMissingAddress() throws {
        app.terminate()
        app.launchEnvironment["IMOVIE_CONFIG_URL"] = "http://127.0.0.1:8765/tv?generic=1"
        app.launch()
        app.tabBars.buttons["设置"].tap()
        app.buttons["config-import"].tap()
        XCTAssertTrue(app.staticTexts["兼容情况"].waitForExistence(timeout: 15))
        app.tabBars.buttons["首页"].tap()
        XCTAssertTrue(app.staticTexts["通用规则样片"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "video-card-")).firstMatch.tap()
        XCTAssertTrue(app.buttons["episode-第1集"].waitForExistence(timeout: 5))
        app.buttons["episode-第1集"].tap()
        assertPlaying()
        XCTAssertEqual(app.webViews.count, 0)
        capture("28-generic-source-playing")
        app.buttons["detail-back"].tap()
        app.buttons["home-source-picker"].tap()
        app.buttons["source-missing"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "没有可用的插件地址")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["来源地址 / 规则"].exists)
        capture("29-generic-source-error")
        app.buttons["来源地址 / 规则"].tap()
        let address = app.textFields["source-rule-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        address.typeText("http://127.0.0.1:8765/generic/\n")
        for _ in 0..<4 {
            if app.buttons["source-rule-save"].exists && app.buttons["source-rule-save"].isHittable { break }
            app.swipeUp()
        }
        app.buttons["source-rule-save"].tap()
        // The editor pops back to the source and the saved override reloads it.
        XCTAssertTrue(app.staticTexts["通用规则样片"].waitForExistence(timeout: 10))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["通用规则样片"].waitForExistence(timeout: 10))
        capture("30-generic-rule-persisted")
    }

    private func imageRequests(_ key: String) throws -> Int {
        let ready = expectation(description: "Image request counter")
        var count = -1
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:8765/image-stats?key=" + key)!) { data, _, _ in
            if let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Int] { count = root["requests"] ?? -1 }
            ready.fulfill()
        }.resume()
        wait(for: [ready], timeout: 5)
        return count
    }

    private func assertPlaying() {
        let player = app.descendants(matching: .any).matching(identifier: "native-player").firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 10))
        let predicate = NSPredicate(format: "value == %@", "playing")
        expectation(for: predicate, evaluatedWith: player)
        waitForExpectations(timeout: 55)
        let session = app.descendants(matching: .any).matching(identifier: "playback-session").firstMatch
        let rendered = NSPredicate { _, _ in
            let fields = (session.value as? String ?? "").components(separatedBy: "|")
            return fields.count == 3 && fields[2] == "frame" && (Int(fields[1]) ?? 0) >= 3
        }
        expectation(for: rendered, evaluatedWith: nil)
        waitForExpectations(timeout: 20)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
