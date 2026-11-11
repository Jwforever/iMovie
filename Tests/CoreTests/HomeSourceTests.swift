import Foundation
import XCTest
@testable import iMovieCore

final class HomeSourceTests: XCTestCase {
    func testSearchGroupsBiliAliasesAndRespectsDisabledAndUnsupportedSources() throws {
        let text = #"""
        {"sites":[
          {"key":"bili-doc","type":3,"api":"csp_BiliGuard","ext":{"json":"https://example.test/docs.json"}},
          {"key":"bili-music","type":3,"api":"csp_BiliGuard","ext":{"json":"https://example.test/music.json"}},
          {"key":"auete","type":3,"api":"csp_AueteGuard"},
          {"key":"dm84","type":3,"api":"csp_Dm84Guard"},
          {"key":"off","type":1,"api":"https://example.test/api","searchable":0},
          {"key":"unknown","type":3,"api":"csp_UnknownGuard"}
        ]}
        """#
        let config = try ConfigDecoder.decode(Data(text.utf8), sourceURL: URL(string: "https://example.test/tv")!)
        XCTAssertEqual(config.searchTargets.map(\.site.key), ["bili-doc", "auete", "dm84", "unknown"])
        XCTAssertEqual(config.searchTargets[0].aliases.map(\.key), ["bili-music"])
        XCTAssertEqual(config.searchTargets[1].site.nativeAdapter, .auete)
    }

    func testAueteNewSiteListKeepsRelativePathsImagesAndPagination() throws {
        let html = #"""
        <li data-href="/Movie/jqp/sample/"><a class="pic"><img src="/poster.webp"></a>
        <h2><a href="/Movie/jqp/sample/">电影 &amp; 剧集</a></h2><span class="hdtag">HD</span></li>
        <li data-href="/Movie/jqp/sample/"><h2><a href="/Movie/jqp/sample/">重复</a></h2></li>
        <li data-href="https://ads.example.test/Movie/jqp/ad/"><h2><a href="https://ads.example.test/Movie/jqp/ad/">广告</a></h2></li>
        <ul class="pagination"><li><a href="/Movie/index2.html">下一页</a></li></ul>
        """#
        let page = try AueteAdapter.decodePage(Data(html.utf8), baseURL: URL(string: "https://www.aeete.com/Movie/index.html")!, page: 1)
        XCTAssertEqual(page.videos.count, 1)
        let first = try XCTUnwrap(page.videos.first)
        XCTAssertEqual(first.id, "/Movie/jqp/sample/")
        XCTAssertEqual(first.title, "电影 & 剧集")
        XCTAssertEqual(first.poster, "https://www.aeete.com/poster.webp")
        XCTAssertEqual(page.pageCount, 2)
        XCTAssertTrue(page.categories.contains { $0.name == "电视剧" })
        let url = try AueteAdapter.pageURL(category: "Movie", search: nil, page: 2)
        XCTAssertEqual(url.path, "/Movie/index2.html")
        let search = try AueteAdapter.pageURL(category: nil, search: "唐朝 & 故事", page: 1)
        XCTAssertEqual(search.path, "/auete4so.php")
        XCTAssertEqual(URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "唐朝 & 故事")
        XCTAssertThrowsError(try AueteAdapter.pageURL(category: "../bad", search: nil, page: 1))
    }

    func testAueteDetailPreservesEpisodeLinesAndRejectsExternalEpisodes() throws {
        let html = #"""
        <h1 class="detail-title">《样片》</h1><div class="detail-poster"><img src="/cover.jpg"></div>
        <div class="detail-info-body">简介</div>
        <ul class="episode-list"><li><a href="/Tv/neidi/sample/play-0-0.html">第1集</a></li>
        <li><a href="https://ads.example.test/Tv/neidi/sample/play-0-0.html">广告</a></li></ul>
        <ul class="episode-list"><li><a href="/Tv/neidi/sample/play-1-0.html">正片</a></li></ul>
        """#
        let detail = try AueteAdapter.decodeDetail(Data(html.utf8), baseURL: URL(string: "https://www.aeete.com/Tv/neidi/sample/")!, id: "/Tv/neidi/sample/")
        XCTAssertEqual(detail.title, "样片")
        XCTAssertEqual(detail.lines.count, 2)
        XCTAssertEqual(detail.lines[0].episodes.count, 1)
        XCTAssertEqual(detail.lines[1].episodes[0].value, "https://www.aeete.com/Tv/neidi/sample/play-1-0.html")
    }

    func testAuetePlayerOnlyAcceptsPublicHTTPMediaFromNowVariable() throws {
        let url = "https://media.example.test/play/index.m3u8?token=a&b=c"
        let encoded = Data(url.utf8).base64EncodedString()
        let html = "<script>var next=base64decode('aW52YWxpZA==');var now=base64decode(\"\(encoded)\");</script>"
        XCTAssertEqual(AueteAdapter.decodePlayer(Data(html.utf8))?.absoluteString, url)
        let unsafe = Data("file:///private/test.mp4".utf8).base64EncodedString()
        XCTAssertNil(AueteAdapter.decodePlayer(Data("var now=base64decode('\(unsafe)')".utf8)))
        XCTAssertNil(AueteAdapter.decodePlayer(Data("<html>验证</html>".utf8)))
    }
}
