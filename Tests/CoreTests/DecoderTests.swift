import Foundation
import XCTest
@testable import iMovieCore

final class DecoderTests: XCTestCase {
    private let sourceURL = URL(string: "http://example.test/config/tv")!

    func testImageWrappedJSONCDoesNotTreatAndroidIdentifierAsURL() throws {
        let text = #"""
        {
          // https:// inside strings must survive
          "spider": "https://example.test/spider.jar;md5;abc",
          "sites": [
            {"key":"android","name":"安卓源","type":3,"api":"csp_Guard","ext":{"secret":"leave untouched"}},
            {"key":"js","name":"脚本源","type":3,"api":"../rules/a.js",},
            {"key":"native","name":"JSON源","type":"4","api":"https://example.test/api?url=a//b","searchable":"1"},
          ],
          "lives": [{"name":"直播","url":"../live.m3u","ua":"test-agent"}],
        }
        """#
        var data = Data([0xFF, 0xD8, 0x00, 0xAA, 0xFF])
        data.append(Data(("abc**" + Data(text.utf8).base64EncodedString()).utf8))
        let result = try ConfigDecoder.decode(data, sourceURL: sourceURL)
        XCTAssertEqual(result.sites.count, 3)
        XCTAssertEqual(result.sites[0].api, "csp_Guard")
        XCTAssertEqual(result.sites[0].runtime, .android)
        XCTAssertEqual(result.sites[1].runtime, .javascript)
        XCTAssertEqual(result.sites[2].runtime, .jsonAPI)
        XCTAssertEqual(result.sites[2].api, "https://example.test/api?url=a//b")
        XCTAssertEqual(result.lives[0].url, "http://example.test/live.m3u")
        XCTAssertEqual(result.lives[0].headers["User-Agent"], "test-agent")
    }

    func testCommentMarkersInsideEscapedStringArePreserved() throws {
        let text = #"{"sites":[{"key":"a","type":1,"api":"https://example.test/a","name":"a \" // /* b"}]/*comment*/}"#
        let result = try ConfigDecoder.decode(Data(text.utf8), sourceURL: sourceURL)
        XCTAssertEqual(result.sites.first?.name, "a \" // /* b")
    }

    func testPlainBase64WithoutPadding() throws {
        let text = #"{"sites":[{"key":"a","type":1,"api":"https://example.test/api"}]}"#
        let base64 = Data(text.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let result = try ConfigDecoder.decode(Data(base64.utf8), sourceURL: sourceURL)
        XCTAssertEqual(result.nativeSites.count, 1)
    }

    func testInvalidAndEmptyConfigurationsFail() {
        for input in [Data(), Data("{}".utf8), Data("<html>error</html>".utf8), Data([0xFF, 0xD8])] {
            XCTAssertThrowsError(try ConfigDecoder.decode(input, sourceURL: sourceURL))
        }
    }

    func testM3UPreservesSignedURLAndPerChannelHeaders() throws {
        let text = """
        #EXTM3U
        #EXTINF:-1 group-title="News, World",Channel, HD
        #EXTVLCOPT:http-user-agent=Test/1
        #EXTVLCOPT:http-referrer=https://example.test/
        ../live/main.m3u8?token=a=b&x=1|Origin=https%3A%2F%2Fexample.test
        #EXTINF:-1,Second
        https://media.test/second.m3u8
        #EXTINF:-1,Unsupported
        udp://239.1.1.1:1234
        """
        let result = try PlaylistDecoder.decode(Data(text.utf8), baseURL: sourceURL)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].title, "Channel, HD")
        XCTAssertEqual(result[0].group, "News, World")
        XCTAssertEqual(result[0].url, "http://example.test/live/main.m3u8?token=a=b&x=1")
        XCTAssertEqual(result[0].headers["User-Agent"], "Test/1")
        XCTAssertEqual(result[0].headers["Referer"], "https://example.test/")
        XCTAssertEqual(result[0].headers["Origin"], "https://example.test")
        XCTAssertTrue(result[1].headers.isEmpty)
    }

    func testTXTGroupsAndHLSVariants() throws {
        let text = "地方台,#genre#\n电视一台,https://media.test/one.m3u8\n电视二台,https://media.test/two.m3u8\n"
        let result = try PlaylistDecoder.decode(Data(text.utf8), baseURL: sourceURL)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].group, "地方台")
        let manifest = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100000\n480p.m3u8\n"
        let hls = try PlaylistDecoder.decode(Data(manifest.utf8), baseURL: sourceURL)
        XCTAssertEqual(hls.count, 1)
        XCTAssertEqual(hls[0].url, sourceURL.absoluteString)
    }

    func testHTMLResponseIsNotMisreadAsRelativeChannels() {
        let html = "<html>\n<body>Service unavailable, try later</body>\n</html>"
        XCTAssertThrowsError(try PlaylistDecoder.decode(Data(html.utf8), baseURL: sourceURL))
    }

    func testEpisodeParsingKeepsEmbeddedDollarAndQuery() {
        let root: [String: Any] = ["list": [["vod_id": 3, "vod_name": "A &amp; B", "vod_play_from": "main$$$other", "vod_play_url": "第一集$https://media.test/a.m3u8?x=$abc#第二集$https://media.test/b.mp4$$$正片$abc"]]]
        let result = TVAPIClient.decodePage(root, baseURL: sourceURL)
        XCTAssertEqual(result.videos[0].id, "3")
        XCTAssertEqual(result.videos[0].title, "A & B")
        XCTAssertEqual(result.videos[0].lines.count, 2)
        XCTAssertEqual(result.videos[0].lines[0].episodes[0].value, "https://media.test/a.m3u8?x=$abc")
        XCTAssertEqual(result.videos[0].lines[1].name, "other")
    }

    func testOnlyHTTPAddressesAreAccepted() {
        for value in ["", "file:///etc/passwd", "javascript:alert(1)", "ftp://example.test/a", "https://user:pass@example.test/a"] {
            XCTAssertNil(HTTPAddress.optional(value))
        }
        XCTAssertNotNil(HTTPAddress.optional("http://www.饭太硬.cc/tv"))
        XCTAssertTrue(HTTPAddress.isMedia("https://example.test/video.m3u8?token=abc"))
        XCTAssertFalse(HTTPAddress.isMedia("https://example.test/player?url=movie.mp4"))
    }
}
