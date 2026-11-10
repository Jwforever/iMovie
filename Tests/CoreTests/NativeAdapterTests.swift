import Foundation
import XCTest
@testable import iMovieCore

final class NativeAdapterTests: XCTestCase {
    func testOnlyKnownRuleAddressesSelectExperimentalNativeAdapter() throws {
        let config = #"""
        {"sites":[
          {"key":"native","type":3,"api":"https://example.test/drpy2.min.js","ext":"https://ghproxy.net/https://raw.githubusercontent.com/fantaiying7/EXT/refs/heads/main/%E5%85%94%E5%B0%8F%E8%B4%9D.js"},
          {"key":"spoof","type":3,"api":"https://example.test/drpy2.min.js","ext":"https://example.test/兔小贝.js"},
          {"key":"android","type":3,"api":"csp_TestGuard","ext":"rfOIzPkSUkANv6AT/=="}
        ]}
        """#
        let result = try ConfigDecoder.decode(Data(config.utf8), sourceURL: URL(string: "https://example.test/tv")!)
        XCTAssertEqual(result.sites[0].runtime, .nativePort)
        XCTAssertEqual(result.sites[0].nativeAdapter, .tuxiaobei)
        XCTAssertEqual(result.sites[1].runtime, .javascript)
        XCTAssertEqual(result.sites[2].runtime, .android)
        XCTAssertEqual(result.sites[2].extensionValue, "rfOIzPkSUkANv6AT/==")
        XCTAssertEqual(result.nativeSites.count, 1)
    }

    func testJSONPCategoryWithUnrelatedSiteFieldsAndEmptyPages() throws {
        let payload = #"({"status":0,"data":{"items":[{"video_id":3840,"name":"小闹钟","image":"https://example.test/a.jpg","duration_string":"02:38","unused":null},{"video_id":3840,"name":"duplicate"}]}});"#
        let result = try TuxiaobeiAdapter.decodeCategory(Data(payload.utf8), page: 2)
        XCTAssertEqual(result.videos.count, 1)
        XCTAssertEqual(result.videos[0].id, "3840")
        XCTAssertEqual(result.videos[0].title, "小闹钟")
        XCTAssertEqual(result.pageCount, 2)
        XCTAssertEqual(result.categories.count, 4)
        let empty = try TuxiaobeiAdapter.decodeCategory(Data(#"{"status":0,"data":{"items":[]}}"#.utf8), page: 3)
        XCTAssertTrue(empty.videos.isEmpty)
        XCTAssertEqual(empty.pageCount, 3)
    }

    func testSearchExtractsSiteResultsWithoutDuplicatePictureLinks() throws {
        let html = #"""
        <div class="search-result">2 results</div><div class="list-con">
        <div class="items"><a href="/play/1311"><mip-img src="https://example.test/a.jpg"></mip-img></a>
        <div class="text"><a href="/play/1311"><p class="title">小星星 &amp; 新版</p></a><span class="time">01:39</span></div></div>
        <!--items end-->
        <div class="items"><a href="/play/2384"><p class="title">小星星(新)</p></a></div>
        <!--items end--></div>
        """#
        let result = try TuxiaobeiAdapter.decodeSearch(Data(html.utf8))
        XCTAssertEqual(result.videos.count, 2)
        XCTAssertEqual(result.videos[0].title, "小星星 & 新版")
        XCTAssertEqual(result.videos[0].note, "01:39")
        XCTAssertEqual(result.videos[1].id, "2384")
    }

    func testDetailHandlesAttributeOrderAndEscapedMediaQuery() throws {
        let html = #"""
        <mip-search-video autoplay="true" poster="https://example.test/poster.jpg" id="videoWrap"
        video-src="https://example.test/video.mp4?token=a&amp;quality=high"></mip-search-video>
        <div class="info"><div class="title">小闹钟</div></div>
        """#
        let result = try TuxiaobeiAdapter.decodeDetail(Data(html.utf8), id: "3840")
        XCTAssertEqual(result.title, "小闹钟")
        XCTAssertEqual(result.lines.first?.episodes.first?.value, "https://example.test/video.mp4?token=a&quality=high")
    }

    func testChangedOrUnexpectedResponsesFailInsteadOfPretendingToWork() {
        for text in ["<html>error</html>", "evil({\"status\":0,\"data\":{\"items\":[]}}); alert(1);", #"{"status":403}"#] {
            XCTAssertThrowsError(try TuxiaobeiAdapter.decodeCategory(Data(text.utf8), page: 1))
        }
        XCTAssertThrowsError(try TuxiaobeiAdapter.decodeDetail(Data("<html>no public media</html>".utf8), id: "1"))
    }
}
