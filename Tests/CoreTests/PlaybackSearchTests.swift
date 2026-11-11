import Foundation
import XCTest
@testable import iMovieCore

final class PlaybackSearchTests: XCTestCase {
    func testFuzzySearchExpandsPartialWordsWithoutDroppingOriginal() {
        XCTAssertEqual(SearchRanking.queries("神厨狂后"), ["神厨狂后", "神厨狂", "厨狂后"])
        XCTAssertEqual(SearchRanking.queries("样片"), ["样片"])
        XCTAssertEqual(SearchRanking.queries("星际 穿越"), ["星际 穿越", "星际", "穿越"])
    }
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

    func testDoubanProductionPosterFieldsAndFallbacks() throws {
        let data = Data(#"{"subject_collection_items":[{"id":"1","title":"封面字段","cover_url":"https://img.example.test/one.jpg","rating":{"value":9.5,"count":1000}},{"id":"2","title":"图片字段","pic":{"large":"https://img.example.test/two.jpg","normal":"https://img.example.test/two-small.jpg"},"rating":{"value":9.4,"count":1000}},{"id":"3","title":"旧版字段","cover":{"url":"https://img.example.test/three.jpg"},"rating":{"value":9.3,"count":1000}}]}"#.utf8)
        XCTAssertEqual(try DoubanRecommendations.decode(data).map(\.poster), ["https://img.example.test/one.jpg", "https://img.example.test/two.jpg", "https://img.example.test/three.jpg"])
    }

    func testCatalogCachePersistsAndClearingForcesReload() async throws {
        actor Counter {
            var count = 0
            func load() -> (Data, URL) {
                count += 1
                return (Data("catalog".utf8), URL(string: "https://example.test/catalog")!)
            }
        }
        let counter = Counter(), key = UUID().uuidString
        let cache = CatalogCache()
        _ = try await cache.data(key: key, lifetime: 60) { await counter.load() }
        _ = try await cache.data(key: key, lifetime: 60) { await counter.load() }
        let restarted = CatalogCache()
        _ = try await restarted.data(key: key, lifetime: 60) { await counter.load() }
        let first = await counter.count
        XCTAssertEqual(first, 1)
        await restarted.clear()
        _ = try await restarted.data(key: key, lifetime: 60) { await counter.load() }
        let second = await counter.count
        XCTAssertEqual(second, 2)
        await restarted.clear()
    }
}
