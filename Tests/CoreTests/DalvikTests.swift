import Foundation
import XCTest
@testable import iMovieCore

/// 解释器与规则分工的自测。
///
/// 这些用例在 CI 的 `swift test` 里必跑：DEX 能解析、采集器方法在位、
/// 线路/线路名/选集三段角色没有串位。任何一项挂了都说明"插件解析"这条路断了。
final class DalvikTests: XCTestCase {
    private func innerDex() throws -> Data {
        guard let url = Bundle.module.url(forResource: "Fixtures/spider", withExtension: "jar") else {
            throw XCTSkip("缺少测试夹具 spider.jar")
        }
        return try GuardContainer.innerDex(from: Data(contentsOf: url))
    }

    func testImageReadsCollectorClasses() throws {
        let image = try DalvikImage(data: try innerDex())
        XCTAssertGreaterThan(image.classes.count, 800, "DEX 里的类没有解析出来")

        let auete = "Lcom/github/catvod/spider/Auete;"
        guard let info = image.classes[auete] else {
            return XCTFail("没有找到 Auete 采集器")
        }
        XCTAssertEqual(info.superName, "Lcom/github/catvod/crawler/Spider;")
        XCTAssertNotNil(info.methods["homeContent"], "homeContent 没解析出来")
        XCTAssertEqual(info.methods["homeContent"]?.first?.params, ["Z"])
        XCTAssertEqual(info.methods["detailContent"]?.first?.params, ["Ljava/util/List;"])
        XCTAssertNotNil(info.methods["playerContent"])
    }

    func testCollectorMethodHasExecutableCode() throws {
        let image = try DalvikImage(data: try innerDex())
        let method = try XCTUnwrap(image.classes["Lcom/github/catvod/spider/Auete;"]?
            .methods["homeContent"]?.first)
        XCTAssertGreaterThan(method.codeOffset, 0, "homeContent 没有代码偏移")
        let code = try XCTUnwrap(image.code(method.codeOffset))
        XCTAssertGreaterThan(code.registers, 0)
        XCTAssertGreaterThan(code.size, 10, "homeContent 的指令太少，多半解析错了")
    }

    func testGuardRuleSplitsLineNameFromEpisodeContainer() {
        // 这几条字符串就是插件里 Auete 详情页的实际常量。
        let profile = GuardSiteProfile(
            className: "Auete",
            strings: [],
            methods: [
                "homeContent": ["https://www.example.com/", "ul.threadlist", "h2 a", "a.pic img", "span.hdtag"],
                "detailContent": [
                    "h1.detail-title", "div.detail-poster img", "div.message p.detail-des",
                    "div.play-card#player_list", "div.card-header span b", "ul.episode-list li > a"
                ]
            ],
            hosts: ["https://www.example.com"]
        )
        let rule = GuardRuleBuilder.rule(for: profile)
        XCTAssertEqual(rule?.baseURL, "https://www.example.com")
        XCTAssertEqual(rule?.lineSelector, "div.play-card#player_list")
        XCTAssertEqual(rule?.lineNameSelector, "div.card-header span b")
        XCTAssertEqual(rule?.episodeSelector, "ul.episode-list li > a")
    }

    func testRuleNeverUsesLineTitleAsEpisodeContainer() {
        let profile = GuardSiteProfile(
            className: "Sample",
            strings: [],
            methods: [
                "homeContent": ["https://fixture-media.test/"],
                "detailContent": ["div.card-header span b", "ul.episode-list li > a", "h1.detail-title"]
            ],
            hosts: ["https://fixture-media.test"]
        )
        guard let rule = GuardRuleBuilder.rule(for: profile) else {
            return XCTFail("应该能生成规则")
        }
        XCTAssertNotEqual(rule.lineSelector, "div.card-header span b",
                          "线路标题不能当成选集容器")
    }
}
