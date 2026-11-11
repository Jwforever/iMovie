import Foundation
import XCTest
@testable import iMovieCore

/// 用真实插件包验证「jar → guard → 内层 DEX → 明文站点规则」这条链。
/// 夹具是饭太硬配置当前指向的 spider 包（md5 9d5f341aa5f3353b50cc3bc16b4f3e8a）。
final class GuardPluginTests: XCTestCase {
    private func fixture() throws -> Data {
        guard let url = Bundle.module.url(forResource: "Fixtures/spider", withExtension: "jar") else {
            throw XCTSkip("缺少测试夹具 spider.jar")
        }
        return try Data(contentsOf: url)
    }

    private func index() throws -> GuardIndex {
        let dex = try GuardContainer.innerDex(from: try fixture())
        let file = try DexFile(data: dex)
        return GuardRuleCatalog.decode(file: file, source: "fixture")
    }

    func testContainerUnpacksInnerDex() throws {
        let dex = try GuardContainer.innerDex(from: try fixture())
        XCTAssertEqual(dex.count, 2_728_036)
        XCTAssertTrue(GuardContainer.isDex([UInt8](dex.prefix(4))))
    }

    func testDecoderCollectsTablesAndGetters() throws {
        let dex = try GuardContainer.innerDex(from: try fixture())
        let file = try DexFile(data: dex)
        let decoder = GuardStringDecoder(dex: file)
        decoder.collectTables()
        decoder.collectGetters()
        decoder.buildMethodIndex()
        XCTAssertGreaterThan(decoder.tables.count, 100)
        XCTAssertGreaterThan(decoder.getters.count, 10)
        XCTAssertGreaterThan(decoder.methodIndex.count, 1_000)
    }

    func testPluginYieldsSiteRuleWithoutAnyHardcodedDomain() throws {
        let guardIndex = try index()
        XCTAssertGreaterThan(guardIndex.profiles.count, 30)
        guard let profile = guardIndex.profiles["Auete"] else {
            return XCTFail("插件里没有 Auete 采集器")
        }
        XCTAssertTrue(profile.hosts.contains("www.au1080.top"), "应解出插件里的当前主域：\(profile.hosts)")
        let rule = GuardRuleBuilder.rule(for: profile)
        XCTAssertEqual(rule?.baseURL, "https://www.au1080.top")
        XCTAssertNotNil(rule?.listSelector)
        XCTAssertNotNil(rule?.searchURL)
        XCTAssertNotNil(rule?.episodeSelector)
    }

    func testSitesWithoutDomainAreReportedNotInvented() throws {
        let guardIndex = try index()
        guard let sixV = guardIndex.profiles["SixV"] else { return XCTFail("缺少 SixV") }
        XCTAssertTrue(sixV.hosts.isEmpty, "SixV 的域名不在插件字符串里，不应被猜出来")
        XCTAssertNil(GuardRuleBuilder.rule(for: sixV))
    }

    func testClassNameMapping() {
        XCTAssertEqual(GuardRuleCatalog.className(fromAPI: "csp_AueteGuard"), "Auete")
        XCTAssertEqual(GuardRuleCatalog.className(fromAPI: "csp_SixV"), "SixV")
        XCTAssertNil(GuardRuleCatalog.className(fromAPI: "https://example.test/api"))
    }

    func testSelectorHeuristicsRejectUrlsAndRegexes() {
        XCTAssertTrue(GuardRuleBuilder.isSelector("ul.stui-vodlist > li"))
        XCTAssertTrue(GuardRuleBuilder.isSelector("div.item"))
        XCTAssertFalse(GuardRuleBuilder.isSelector("https://example.test/a"))
        XCTAssertFalse(GuardRuleBuilder.isSelector(#"<a href="(.+?)">"#))
        XCTAssertNil(GuardRuleBuilder.pickHost(["not a url", "/relative/path"]))
        XCTAssertEqual(GuardRuleBuilder.pickHost(["https://example.test/"]), "https://example.test")
    }
}
