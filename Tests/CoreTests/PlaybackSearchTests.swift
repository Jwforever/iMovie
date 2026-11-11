import Foundation
import XCTest
@testable import iMovieCore

final class PlaybackSearchTests: XCTestCase {
    func testSearchRanksFullTitleBeforePrefixContainsAndUnrelated() {
        let titles = ["无关花絮", "新神厨狂后", "神厨狂后 第二季", "神厨狂后", "神话狂想"]
        let sorted = titles.sorted { SearchRanking.score(title: $0, query: "神厨狂后") > SearchRanking.score(title: $1, query: "神厨狂后") }
        XCTAssertEqual(Array(sorted.prefix(3)), ["神厨狂后", "神厨狂后 第二季", "新神厨狂后"])
        XCTAssertEqual(sorted.last, "无关花絮")
        XCTAssertEqual(SearchRanking.score(title: "ＡＢＣ：１２３", query: "abc123"), 100_000)
        XCTAssertEqual(SearchRanking.score(title: "", query: "片名"), 0)
    }

    func testPublicMediaParsesNamedPlayerEncodingAndRejectsAdLinks() throws {
        let base = URL(string: "https://example.test/player")!
        let value = "https://video.example.test/index.m3u8?token=a&v=b"
        let encoded = Data(value.utf8).base64EncodedString()
        let html = "<a href='https://ad.example.test/ad.mp4'>ad</a><script>var player_aaaa={\"encrypt\":2,\"url\":\"\(encoded)\"}</script>"
        XCTAssertEqual(MediaResolver.publicMedia(in: Data(html.utf8), baseURL: base).map(\.absoluteString), [value])
        let dom = "<video src='/main.mp4'></video><source src='file:///private/test.mp4'><script>var config={\"url\":\"https://example.test/blob\"};</script>"
        XCTAssertEqual(MediaResolver.publicMedia(in: Data(dom.utf8), baseURL: base).map(\.absoluteString), ["https://example.test/main.mp4"])
    }

    func testPlayerObjectKeepsBracesInsideStringsAndDoesNotReadWrongVariable() {
        let html = #"window.__HHJX_BOOTSTRAP__={"url":"https://example.test/a?text={x}","t":123,"key":"sample"};window.other={"url":"bad"}"#
        let object = MediaResolver.object(named: "__HHJX_BOOTSTRAP__", in: Data(html.utf8))
        XCTAssertEqual(object?["t"] as? Int, 123)
        XCTAssertEqual(object?["key"] as? String, "sample")
        XCTAssertNil(MediaResolver.object(named: "missing", in: Data(html.utf8)))
    }

    func testDoubanRecommendationsRequireRealRatingAndVoteCount() throws {
        let data = Data(#"{"subject_collection_items":[{"id":"1","title":"低分","rating":{"value":5.5,"count":1000}},{"id":"2","title":"暂无评分","rating":null},{"id":"3","title":"高分","rating":{"value":9.4,"count":1000}},{"id":"4","title":"票数不足","rating":{"value":10,"count":1}},{"id":"5","title":"次高分","rating":{"value":8.5,"count":10000}}]}"#.utf8)
        let items = try DoubanRecommendations.decode(data)
        XCTAssertEqual(items.map(\.title), ["高分", "次高分"])
        XCTAssertEqual(items.first?.rating, 9.4)
        XCTAssertEqual(items.first?.subjectURL.absoluteString, "https://movie.douban.com/subject/3/")
    }

    func testRecommendationLookupRequiresFullTitleRatherThanRemakesAndSeasons() {
        let video = Video(id: "1", title: "星际穿越2", poster: "", note: "", summary: "", playFrom: "", playURL: "")
        XCTAssertFalse(DoubanRecommendations.matches("星际穿越", video: video))
    }

    func testFirstAidCatalogSearchAndPublicEpisode() throws {
        let html = #"<div class="jj-title-li"><div class="list-br3"><a href="/jijiu/article/sample.html">人工呼吸</a><a href="https://ad.example.test/jijiu/article/sample.html">广告</a></div></div>"#
        let page = try FirstAidAdapter.decodePage(Data(html.utf8), category: "0", search: "呼吸")
        XCTAssertEqual(page.videos.map(\.title), ["人工呼吸"])
        let detail = try FirstAidAdapter.decodeDetail(Data(#"<h1 class="video-title h1-title">人工呼吸法</h1><div class="img-text-con">教学</div><video id="video"><source src="https://vod.youlai.cn/sample.mp4"></video>"#.utf8), id: "/jijiu/article/sample.html")
        XCTAssertEqual(detail.lines.first?.episodes.first?.value, "https://vod.youlai.cn/sample.mp4")
        XCTAssertEqual(SourceSite(key: "Aid", name: "急救", type: 3, api: "csp_FirstAidGuard", searchable: true).nativeAdapter, .firstAid)
    }
}
