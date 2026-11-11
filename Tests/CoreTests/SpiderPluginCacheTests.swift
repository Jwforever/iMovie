import Foundation
import CryptoKit
import XCTest
@testable import iMovieCore

final class SpiderPluginCacheTests: XCTestCase {
    private actor Loader {
        var bytes: Data
        var requests = 0
        init(_ bytes: Data) { self.bytes = bytes }
        func get(_ url: URL) async throws -> Data {
            requests += 1
            try await Task.sleep(nanoseconds: 5_000_000)
            return bytes
        }
        func replace(_ bytes: Data) { self.bytes = bytes }
    }

    private func dex(_ marker: UInt8 = 0) -> Data {
        var bytes = Data("dex\n035\0".utf8)
        bytes.append(Data(repeating: marker, count: 120))
        return bytes
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("imovie-plugin-tests-" + UUID().uuidString, isDirectory: true)
    }

    private func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func testSameFilenameOnDifferentHostsAndPathsDoesNotCollide() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let loader = Loader(dex())
        let cache = SpiderPluginCache(folder: folder, load: { try await loader.get($0) })
        for address in ["https://a.test/spider.jar", "https://b.test/spider.jar", "https://a.test/v2/spider.jar"] {
            _ = try await cache.dex(spider: address)
        }
        let count = await loader.requests
        XCTAssertEqual(count, 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 3)
    }

    func testConcurrentRequestsShareOneDownloadAndDiskSurvivesRestart() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = dex(), loader = Loader(dex())
        let cache = SpiderPluginCache(folder: folder, load: { try await loader.get($0) })
        async let first = cache.dex(spider: "https://a.test/spider.jar")
        async let second = cache.dex(spider: "https://a.test/spider.jar")
        let results = try await [first, second]
        XCTAssertEqual(results, [bytes, bytes])
        let restarted = SpiderPluginCache(folder: folder, load: { try await loader.get($0) })
        let restored = try await restarted.dex(spider: "https://a.test/spider.jar")
        XCTAssertEqual(restored, bytes)
        let count = await loader.requests
        XCTAssertEqual(count, 1)
    }

    func testChecksumChangeAndExplicitRefreshLoadNewPlugin() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let old = dex(1), new = dex(2), newest = dex(3)
        let loader = Loader(old)
        let cache = SpiderPluginCache(folder: folder, load: { try await loader.get($0) })
        let address = "https://a.test/spider.jar"
        _ = try await cache.dex(spider: address + ";md5;" + md5(old))
        await loader.replace(new)
        let updated = try await cache.dex(spider: address + ";md5;" + md5(new))
        XCTAssertEqual(updated, new)
        _ = try await cache.dex(spider: address)
        await loader.replace(newest)
        await cache.invalidate(spider: address)
        let refreshed = try await cache.dex(spider: address)
        XCTAssertEqual(refreshed, newest)
        let count = await loader.requests
        XCTAssertEqual(count, 4)
    }

    func testChecksumMismatchFailsAndIsNotCached() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let loader = Loader(dex())
        let cache = SpiderPluginCache(folder: folder, load: { try await loader.get($0) })
        do {
            _ = try await cache.dex(spider: "https://a.test/spider.jar;md5;" + String(repeating: "0", count: 32))
            XCTFail("损坏插件必须校验失败")
        } catch { XCTAssertTrue(error.localizedDescription.contains("MD5")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testConcurrentCatalogRequestsKeepDifferentPluginIdentity() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/spider", withExtension: "jar"))
        let bytes = try GuardContainer.innerDex(from: Data(contentsOf: fixture))
        let catalog = GuardRuleCatalog(loadDex: { _ in bytes })
        async let first = catalog.index(spider: "https://a.test/spider.jar")
        async let second = catalog.index(spider: "https://b.test/spider.jar")
        let (left, right) = try await (first, second)
        XCTAssertEqual(left.source, "https://a.test/spider.jar")
        XCTAssertEqual(right.source, "https://b.test/spider.jar")
        XCTAssertNotNil(left.profiles["Auete"])
        XCTAssertNotNil(right.profiles["Dm84"])
    }

    func testSpiderSourcePreservesVersionChecksum() {
        let source = SpiderSource()
        source.update("https://a.test/spider.jar;md5;" + String(repeating: "a", count: 32))
        XCTAssertTrue(source.url?.contains(";md5;") == true)
    }
}
