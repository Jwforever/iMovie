import Foundation
import SwiftSoup
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

    /// DOM 垫片是解释器跑通插件详情/播放的关键。这里用真实插件镜像验证混淆名与
    /// jsoup 语义一一对应；奥特等站点的播放地址就靠 lF(data) 从 script 里取。
    func testHTMLShimsMatchPluginDOMSemantics() throws {
        let image = try DalvikImage(data: try innerDex())
        let vm = DalvikVM(image: image)
        let hN = "Lcom/github/catvod/spider/merge/hN;"
        let mA = "Lcom/github/catvod/spider/merge/MA;"
        let kB = "Lcom/github/catvod/spider/merge/kB;"

        let html = "<div id=\"wrap\"><script>var now=\"https://cdn.example/x.m3u8\";</script>" +
            "<p class=\"t\">hello</p></div>"
        let root = try XCTUnwrap(try SwiftSoup.parse(html).select("div").first())

        func obj(_ element: Element) -> DalvikObject {
            let object = DalvikObject(className: hN)
            object.payload = element
            return object
        }
        func body(_ owner: String, _ name: String) throws ->
            (DalvikVM, DalvikObject?, [DalvikValue]) throws -> DalvikValue {
            try XCTUnwrap(vm.overrideBody(owner, name), "缺垫片 \(owner)->\(name)")
        }
        func text(_ value: DalvikValue?) -> String {
            DalvikNatives.text(value ?? .ref(nil))
        }

        // lF = data()：奥特 playerContent 靠它从 <script> 里拿播放地址。
        let script = try XCTUnwrap(try root.select("script").first())
        XCTAssertEqual(text(try body(hN, "lF")(vm, obj(script), [])), "var now=\"https://cdn.example/x.m3u8\";")

        // cS = select，返回 kB 列表。
        let selected = try body(hN, "cS")(vm, obj(root), [.ref(DalvikObject.string("p"))])
        XCTAssertEqual(selected.asObject?.items?.count, 1)

        // 结构导航：L=parent、J=children、C=siblingIndex、o/u7=前后兄弟。
        let parent = try body(hN, "L")(vm, obj(script), [])
        XCTAssertEqual(text(try body(mA, "N")(vm, parent.asObject, [.ref(DalvikObject.string("id"))])), "wrap")
        let children = try body(hN, "J")(vm, obj(root), [])
        XCTAssertEqual(children.asObject?.items?.count, 2)
        let paragraph = try XCTUnwrap(children.asObject?.items?.last?.asObject)
        XCTAssertEqual(try body(hN, "C")(vm, paragraph, []).intValue, 1)
        let next = try body(hN, "o")(vm, children.asObject?.items?.first?.asObject, [])
        XCTAssertEqual(text(try body(hN, "kR")(vm, next.asObject, [])), "hello")
        let previous = try body(hN, "u7")(vm, paragraph, [])
        XCTAssertEqual((previous.asObject?.payload as? Element)?.tagName(), "script")

        // 文本与属性修改：Qz=text(String)、V=attr(k,v)。
        try body(hN, "Qz")(vm, paragraph, [.ref(DalvikObject.string("替换后的文本"))])
        XCTAssertEqual(try XCTUnwrap(paragraph.payload as? Element).text(), "替换后的文本")
        try body(hN, "V")(vm, obj(script), [.ref(DalvikObject.string("src")), .ref(DalvikObject.string("a.js"))])
        XCTAssertEqual(try script.attr("src"), "a.js")

        // 列表：kB.tF 第一个、kB.N(i) 取第 i 个包成新列表、kB.t0 拼接文本。
        XCTAssertEqual(text(try body(kB, "t0")(vm, children.asObject, [])), "替换后的文本")
        let eqOne = try body(kB, "N")(vm, children.asObject, [.int(1)])
        XCTAssertEqual(eqOne.asObject?.items?.count, 1)
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
                "homeContent": ["https://fixture-media.test/", "ul.threadlist"],
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

    func testAuxiliaryHostsAreNotUsedAsWebsiteHome() {
        let profile = GuardSiteProfile(className: "API", strings: ["https://images.fixture.test/"],
            methods: ["detailContent": ["https://player.fixture.test/"]], hosts: ["images.fixture.test", "player.fixture.test"])
        XCTAssertNil(GuardRuleBuilder.rule(for: profile))
        let web = GuardSiteProfile(className: "HTML", strings: [],
            methods: ["<init>": ["https://old.fixture.test/"], "homeContent": ["div.module-item"]], hosts: [])
        XCTAssertEqual(GuardRuleBuilder.rule(for: web, ext: "{\"siteUrl\":\"https://current.fixture.test/\"}")?.baseURL, "https://current.fixture.test/")
    }
}
