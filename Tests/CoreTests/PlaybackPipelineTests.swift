import Foundation
import XCTest
@testable import iMovieCore

/// 端到端播放管线回归：解析出真实播放地址后，验证设备实际取流通路——
/// 本地回环代理能否把 m3u8/mp4 变成播放器可消费的字节（m3u8 重写、分片、Range）。
///
/// 设备上这段路由由 mpv 消费；渲染（已由奥特源在真机验证）之外的所有数据问题
/// 都应该在这里复现，而不是等用户装包试错。
/// 默认跳过，CI 用 `IMOVIE_PIPELINE_DIAGNOSTICS=1` + `IMOVIE_PIPELINE_KEYS` 触发。
final class PlaybackPipelineTests: XCTestCase {
    private struct Pipeline {
        var key: String
        var title: String
        var originalURL: String
        var ok: Bool
        var detail: String
    }

    /// 与链路诊断一致的占位判定：`暂无预告$www` 不是可播放的选集。
    private static func looksLikePlayableID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed.hasPrefix("{") || trimmed.contains("/") || trimmed.hasPrefix("http") { return true }
        return trimmed.count >= 6
    }

    func testPlayURLServesMediaThroughLocalProxy() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["IMOVIE_PIPELINE_DIAGNOSTICS"] == "1" else {
            throw XCTSkip("默认跳过：需要 IMOVIE_PIPELINE_DIAGNOSTICS=1")
        }
        let keys = Set((environment["IMOVIE_PIPELINE_KEYS"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })

        let config = try await HTTPClient().config(at: "http://www.饭太硬.cc/tv")
        SpiderSource.shared.update(config.spider)
        let selected = config.sites.filter { $0.isPlugin && (keys.isEmpty || keys.contains($0.key)) }
        XCTAssertFalse(selected.isEmpty, "没有匹配到要测的来源")

        LocalStreamProxy.shared.prepare()
        var reports: [[String: Any]] = []
        var failures: [String] = []

        for site in selected {
            var pipeline: Pipeline
            do {
                let play = try await Self.resolvePlayURL(site: site, spider: config.spider, ext: site.extensionValue)
                let outcome = try await Self.fetchThroughProxy(play)
                pipeline = Pipeline(key: site.key, title: play.title,
                                    originalURL: String(play.url.prefix(160)),
                                    ok: outcome.ok, detail: outcome.detail)
            } catch {
                pipeline = Pipeline(key: site.key, title: "", originalURL: "",
                                    ok: false, detail: error.localizedDescription)
            }
            reports.append(["key": pipeline.key, "title": pipeline.title,
                            "url": pipeline.originalURL, "ok": pipeline.ok,
                            "detail": pipeline.detail])
            if !pipeline.ok { failures.append("\(pipeline.key): \(pipeline.detail)") }
            print("PIPELINE \(pipeline.key) \(pipeline.ok ? "ok" : "fail") — \(pipeline.detail)")
        }

        let reportData = try JSONSerialization.data(withJSONObject: ["pipelines": reports], options: [.prettyPrinted])
        try? FileManager.default.createDirectory(atPath: "dist", withIntermediateDirectories: true)
        try? reportData.write(to: URL(fileURLWithPath: "dist/playback-pipeline-report.json"))

        XCTAssertTrue(failures.isEmpty, "播放管线回归失败：\n" + failures.joined(separator: "\n"))
    }

    /// 首页 → 详情 → 选集 → 播放地址（与链路诊断同一段逻辑的紧凑版）。
    private static func resolvePlayURL(site: SourceSite, spider: String?, ext: String) async throws
        -> (title: String, url: URL, headers: [String: String]) {
        var homeRun = try await DalvikSpider.run(spider: spider, api: site.api, action: .home, ext: ext)
        var videos = CatVodPayload.page(homeRun.json)?.videos ?? []
        if videos.isEmpty, let category = CatVodPayload.page(homeRun.json)?.categories.first {
            let run = try await DalvikSpider.run(spider: spider, api: site.api,
                                                 action: .category(id: category.id, page: "1"), ext: ext)
            videos = CatVodPayload.page(run.json)?.videos ?? []
        }
        guard !videos.isEmpty else { throw ViewerError.message("首页没有影片") }

        var video: Video?
        var line: EpisodeLine?
        var episode: Episode?
        for candidate in videos.prefix(4) {
            let run = try await DalvikSpider.run(spider: spider, api: site.api,
                                                 action: .detail(id: candidate.id), ext: ext)
            guard let parsed = CatVodPayload.detail(run.json),
                  let parsedLine = parsed.lines.first,
                  let parsedEpisode = parsedLine.episodes.first,
                  looksLikePlayableID(parsedEpisode.value) else { continue }
            video = parsed; line = parsedLine; episode = parsedEpisode
            break
        }
        guard let video, let line, let episode else {
            throw ViewerError.message("前几条详情都没有真实选集")
        }

        let candidates = [episode.value, "\(episode.title)$\(episode.value)"]
        for identifier in candidates {
            let run = try await DalvikSpider.run(spider: spider, api: site.api,
                                                 action: .player(flag: line.name, id: identifier), ext: ext)
            guard let playback = CatVodPayload.playback(run.json), playback.url.hasPrefix("http"),
                  let url = HTTPAddress.optional(playback.url) else { continue }
            return (video.title, url, playback.headers)
        }
        throw ViewerError.message("插件没有解出播放地址")
    }

    /// 设备实际取流路径：https → 本地代理 → 上游。验证响应体形态，m3u8 再验证重写与分片。
    private static func fetchThroughProxy(_ play: (title: String, url: URL, headers: [String: String])) async throws
        -> (ok: Bool, detail: String) {
        guard play.url.scheme?.lowercased() == "https" else {
            // http 直链设备上由 mpv 直连，这里同样直接取流验证可达。
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: play.url, timeoutInterval: 40))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return ((200..<300).contains(status) && data.count > 1024, "http 直链 status=\(status) bytes=\(data.count)")
        }

        var proxied: URL?
        for _ in 0..<50 {
            if let candidate = LocalStreamProxy.shared.mediaURL(for: play.url, headers: play.headers) {
                proxied = candidate
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let proxied else { throw ViewerError.message("本地代理 5 秒内未就绪") }

        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: proxied, timeoutInterval: 60))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), !data.isEmpty else {
            return (false, "代理取流 status=\(status) bytes=\(data.count)")
        }

        let text = String(decoding: data.prefix(4096), as: UTF8.self)
        if text.hasPrefix("#EXTM3U") || text.contains("#EXT-X-") {
            // 播放列表：验证重写生效（分片地址应指向本地代理）。
            guard text.contains("127.0.0.1") else {
                return (false, "m3u8 未被重写，前 200 字节：\(text.prefix(200))")
            }
            let segment = text.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("#") }
            guard let segment, let segmentURL = URL(string: segment) else {
                return (false, "m3u8 重写后找不到可请求的分片")
            }
            var segmentRequest = URLRequest(url: segmentURL, timeoutInterval: 60)
            segmentRequest.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
            let (segmentData, segmentResponse) = try await URLSession.shared.data(for: segmentRequest)
            let segmentStatus = (segmentResponse as? HTTPURLResponse)?.statusCode ?? 0
            let segmentOK = [200, 206].contains(segmentStatus) && !segmentData.isEmpty
            return (segmentOK, "m3u8 重写 ok，分片 status=\(segmentStatus) bytes=\(segmentData.count)")
        }
        // mp4/直链：至少要像媒体字节而不是错误页。
        let head = String(decoding: data.prefix(256), as: UTF8.self).lowercased()
        let looksLikeHTML = head.contains("<!doctype") || head.contains("<html")
        let mediaOK = !looksLikeHTML && data.count > 10_240
        return (mediaOK, "直链 status=\(status) bytes=\(data.count) html=\(looksLikeHTML)")
    }
}
