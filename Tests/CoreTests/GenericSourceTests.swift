import Foundation
import XCTest
@testable import iMovieCore

final class GenericSourceTests: XCTestCase {
    func testAllUnknownAndroidSourcesRemainOpenAndSeparateInSearch() throws {
        let config = try ConfigDecoder.decode(Data(#"{"sites":[{"key":"new-a","type":3,"api":"csp_NewUnknownGuard"},{"key":"new-b","type":3,"api":"csp_NewUnknownGuard"}]}"#.utf8), sourceURL: URL(string: "https://example.test/config")!)
        XCTAssertEqual(config.nativeSites.count, 2)
        XCTAssertTrue(config.sites.allSatisfy(\.usesGenericAdapter))
        XCTAssertEqual(config.searchTargets.count, 2)
        XCTAssertEqual(config.sites[0].runtime.title, "通用试配")
    }

    func testFutureSourceRuleDecodesWithoutNewNativeAdapter() throws {
        let config = try ConfigDecoder.decode(Data(#"{"sites":[{"key":"future","type":3,"api":"csp_FutureGuard","ios":{"baseURL":"https://example.test/","searchURL":"/find?q={query}","listSelector":".custom"}}]}"#.utf8), sourceURL: URL(string: "https://config.test/tv")!)
        XCTAssertEqual(config.sites[0].genericRule?.listSelector, ".custom")
        XCTAssertEqual(config.sites[0].genericRule?.searchURL, "/find?q={query}")
        let url = try GenericSourceAdapter.expand("/find?q={query}&page={page}", base: URL(string: "https://example.test")!, query: "A & B", page: 2)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "A & B")
    }

    func testGenericAueteAndMacCMSCardsDetailAndEpisodeParsing() throws {
        let base = URL(string: "https://example.test")!, rule = GenericSourceRule(baseURL: "https://example.test")
        let html = #"<nav><a href='/Movie/index.html'>电影</a></nav><li data-href='/Movie/test/a/'><a href='/Movie/test/a/'><img src='/cover.jpg'></a><h2><a href='/Movie/test/a/'>样片</a></h2><span class='hdtag'>HD</span></li><ul class='stui-vodlist'><li><a href='/detail/2.html' title='第二部'><img data-original='/two.jpg'></a></li></ul>"#
        let page = try GenericSourceAdapter.decodePage(Data(html.utf8), baseURL: base, rule: rule, page: 1)
        XCTAssertEqual(page.videos.map(\.title), ["样片", "第二部"])
        XCTAssertEqual(page.videos.first?.poster, "https://example.test/cover.jpg")
        XCTAssertEqual(page.categories.first?.name, "电影")
        let detail = #"<h1 class='detail-title'>样片</h1><ul class='episode-list'><li><a href='/play/1.html'>第一集</a></li><li><a href='https://ads.test/play/ad.html'>广告</a></li></ul>"#
        let video = try GenericSourceAdapter.decodeDetail(Data(detail.utf8), baseURL: base, rule: rule, id: "1")
        XCTAssertEqual(video.lines[0].episodes.count, 1)
        XCTAssertEqual(video.lines[0].episodes[0].value, "https://example.test/play/1.html")
    }

    func testMissingDomainReportsSpecificErrorWhileStillOpen() async throws {
        let site = SourceSite(key: "x", name: "未知", type: 3, api: "csp_EncryptedGuard", searchable: true, extensionValue: "deadbeef")
        XCTAssertTrue(site.isNative)
        do {
            _ = try await GenericSourceAdapter(site: site).rule()
            XCTFail("Class identifiers cannot invent domains")
        } catch { XCTAssertTrue(error.localizedDescription.contains("没有提供")) }
    }
}
