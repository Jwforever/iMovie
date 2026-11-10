import Foundation
import XCTest
@testable import iMovieCore

final class SourceAdapterTests: XCTestCase {
    func testGuardEntriesSelectLocalImplementations() throws {
        let data = Data(#"{"sites":[{"key":"dm","name":"动漫","api":"csp_Dm84Guard","type":3},{"key":"bili","api":"csp_BiliGuard","type":3},{"key":"unknown","api":"csp_UnknownGuard","type":3}]}"#.utf8)
        let config = try ConfigDecoder.decode(data, sourceURL: URL(string: "https://example.test/tv")!)
        XCTAssertEqual(config.nativeSites.count, 2)
        XCTAssertEqual(config.sites[0].nativeAdapter, .dm84)
        XCTAssertEqual(config.sites[1].nativeAdapter, .bilibili)
        XCTAssertEqual(config.sites[2].runtime, .android)
    }

    func testDM84HTMLListPreservesCategoryAndDeduplicatesItems() throws {
        let html = #"""
        <ul class="nav_row"><li><a href="/list-1.html">国漫</a></li><li><a href="/list-4.html">电影</a></li></ul>
        <div class="item"><a class="cover" data-bg="/poster.jpg"></a><a class="title" href="/v/123.html">动漫 &amp; 电影</a><span class="desc">更新至 5 集</span></div>
        <div class="item"><a class="title" href="/v/123.html">重复</a></div>
        <a href="/show-1--time----2.html">下一页</a>
        """#
        let page = try HTMLSourceAdapter.decodePage(Data(html.utf8), adapter: .dm84, baseURL: URL(string: "https://dm84.tv/")!, page: 1)
        XCTAssertEqual(page.categories.map(\.name), ["国漫", "电影"])
        XCTAssertEqual(page.videos.count, 1)
        XCTAssertEqual(page.videos[0].title, "动漫 & 电影")
        XCTAssertEqual(page.videos[0].poster, "https://dm84.tv/poster.jpg")
        XCTAssertEqual(page.pageCount, 2)
    }

    func testDM84DetailKeepsLinesAndRejectsExternalEpisodeLinks() throws {
        let html = #"""
        <h1 class="v_title">样例</h1><meta property="og:description" content="简介">
        <ul class="tab_control"><li>线路一</li><li>线路二</li></ul>
        <ul class="play_list"><li><a href="/p/123-1-2.html">2</a></li><li><a href="/p/123-1-1.html">1</a></li><li><a href="https://ads.example.test/a">广告</a></li></ul>
        <ul class="play_list"><li><a href="/p/123-2-1.html">正片</a></li></ul>
        """#
        let video = try HTMLSourceAdapter.decodeDetail(Data(html.utf8), adapter: .dm84, baseURL: URL(string: "https://dm84.tv/v/123.html")!, id: "123.html")
        XCTAssertEqual(video.lines.count, 2)
        XCTAssertEqual(video.lines[0].episodes.count, 2)
        XCTAssertEqual(video.lines[1].episodes[0].value, "https://dm84.tv/p/123-2-1.html")
        XCTAssertEqual(video.summary, "简介")
    }

    func testBilibiliSearchMarkupAndProtocolRelativePictures() throws {
        let row: [String: Any] = ["bvid": "BV1vmWJ6LEmW", "title": "测试<em class='keyword'>搜索</em>", "pic": "//i.example.test/a.jpg", "author": "作者"]
        let video = BilibiliAdapter.video(row)
        XCTAssertEqual(video?.title, "测试 搜索")
        XCTAssertEqual(video?.poster, "https://i.example.test/a.jpg")
        XCTAssertNil(BilibiliAdapter.video(["bvid": "../../bad"]))
        XCTAssertThrowsError(try BilibiliAdapter.decode(Data(#"{"code":-412,"message":"请求被拦截"}"#.utf8)))
    }

    func testPlaybackKindRemainsCompatibleWithSavedRecords() throws {
        let old = Data(#"{"title":"旧记录","url":"https://example.test/a.mp4","headers":{},"group":"测试"}"#.utf8)
        let media = try JSONDecoder().decode(MediaLink.self, from: old)
        XCTAssertNil(media.kind)
        XCTAssertNil(media.reference)
        let web = MediaLink(title: "网页", url: "https://example.test/play", kind: .web)
        XCTAssertEqual(try JSONDecoder().decode(MediaLink.self, from: JSONEncoder().encode(web)).kind, .web)
    }

    func testSavedEpisodeKeepsSourceForRefreshingExpiringAddresses() throws {
        let config = try ConfigDecoder.decode(Data(#"{"sites":[{"key":"bili","name":"公开内容","type":3,"api":"csp_BiliGuard"}]}"#.utf8), sourceURL: URL(string: "https://example.test/tv")!)
        var media = MediaLink(title: "分集", url: "https://media.example.test/expired.mp4?expires=1")
        media.reference = PlaybackReference(site: config.sites[0], episode: Episode(title: "第一集", value: "bili:BV1vmWJ6LEmW:43436606874"), flag: "公开视频")
        let restored = try JSONDecoder().decode(MediaLink.self, from: JSONEncoder().encode(media))
        XCTAssertEqual(restored.reference?.site.nativeAdapter, .bilibili)
        XCTAssertEqual(restored.reference?.episode.value, "bili:BV1vmWJ6LEmW:43436606874")
        XCTAssertEqual(restored.reference?.flag, "公开视频")
        var refreshed = restored
        refreshed.url = "https://media.example.test/new.mp4?expires=2"
        XCTAssertEqual(refreshed.id, restored.id)
    }
}
