import Foundation
import XCTest
@testable import iMovieCore

/// 端到端链路自测：首页 → 详情 → 选集 → 播放地址。
///
/// 直接调解释器而不是走适配器，这样每一段都能拿到 `notes`
/// （插件内部 try/catch 吞掉的异常、缺实现的方法），失败原因才看得见。
/// 默认跳过，CI 用 `IMOVIE_CHAIN_DIAGNOSTICS=1` 触发。
final class PluginChainDiagnosticsTests: XCTestCase {
    private struct Stage {
        var name: String
        var ok: Bool
        var detail: String
    }

    func testWholeChainForSelectedSources() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["IMOVIE_CHAIN_DIAGNOSTICS"] == "1" else {
            throw XCTSkip("默认跳过：需要 IMOVIE_CHAIN_DIAGNOSTICS=1")
        }
        let keys = Set((environment["IMOVIE_CHAIN_KEYS"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })

        let config = try await HTTPClient().config(at: "http://www.饭太硬.cc/tv")
        SpiderSource.shared.update(config.spider)
        let selected = config.sites.filter { $0.isPlugin && (keys.isEmpty || keys.contains($0.key)) }
        XCTAssertFalse(selected.isEmpty, "没有匹配到要测的来源")

        var reports: [[String: Any]] = []
        for site in selected {
            var report: [String: Any] = ["key": site.key, "name": site.name, "api": site.api]
            var stages: [Stage] = []
            var notes: [[String: String]] = []

            do {
                // 1. 首页
                let homeRun = try await DalvikSpider.run(spider: config.spider, api: site.api,
                                                         action: .home, ext: site.extensionValue)
                notes += homeRun.notes.map { ["stage": "home", "note": $0] }
                let home = CatVodPayload.page(homeRun.json)
                let videos = home?.videos ?? []
                stages.append(Stage(name: "home", ok: !videos.isEmpty,
                                    detail: "分类 \(home?.categories.count ?? 0) / 影片 \(videos.count) / 输出 \(homeRun.json.count) 字节"))
                report["homeRaw"] = String(homeRun.json.prefix(400))
                guard let first = videos.first else { throw ViewerError.message("首页没有影片") }

                // 2. 详情
                let detailRun = try await DalvikSpider.run(spider: config.spider, api: site.api,
                                                           action: .detail(id: first.id),
                                                           ext: site.extensionValue)
                notes += detailRun.notes.map { ["stage": "detail", "note": $0] }
                let video = CatVodPayload.detail(detailRun.json)
                let lines = video?.lines ?? []
                stages.append(Stage(name: "detail", ok: !lines.isEmpty,
                                    detail: "《\(video?.title ?? "?")》线路 \(lines.count) / 集数 \(lines.map(\.episodes.count).reduce(0, +)) / 输出 \(detailRun.json.count) 字节"))
                report["detailRaw"] = String(detailRun.json.prefix(400))
                report["detailRequests"] = detailRun.requestTrace.map {
                    ["url": $0.url, "code": $0.code, "method": $0.method,
                     "bodyBytes": $0.bodyBytes, "contentType": $0.contentType] as [String: Any]
                }
                guard let line = lines.first, let episode = line.episodes.first else {
                    throw ViewerError.message("详情里没有选集")
                }

                // 3. 播放。CatVod 有两种传法：只给 `$` 后面的值，或整条 `名称$值`。
                // 两种都是协议内的合法形态，依次试，谁解出地址就用谁。
                report["episodeValue"] = String(episode.value.prefix(300))
                report["flag"] = line.name
                let candidates = [("value", episode.value),
                                  ("entry", "\(episode.title)$\(episode.value)")]
                var attempts: [[String: Any]] = []
                var chosen: DalvikRunResult?
                var chosenPlayback: (url: String, headers: [String: String], needsParsing: Bool)?
                for (label, identifier) in candidates {
                    let run = try await DalvikSpider.run(spider: config.spider, api: site.api,
                                                         action: .player(flag: line.name, id: identifier),
                                                         ext: site.extensionValue)
                    let playback = CatVodPayload.playback(run.json)
                    attempts.append([
                        "variant": label, "id": String(identifier.prefix(300)),
                        "json": String(run.json.prefix(400)),
                        "requests": run.requestTrace.map {
                            ["url": $0.url, "code": $0.code, "method": $0.method,
                             "bodyBytes": $0.bodyBytes, "contentType": $0.contentType] as [String: Any]
                        }
                    ] as [String: Any])
                    notes += run.notes.map { ["stage": "player", "note": $0] }
                    if chosen == nil { chosen = run }
                    if playback?.url.hasPrefix("http") == true {
                        chosen = run; chosenPlayback = playback
                        break
                    }
                }
                let playRun = chosen!
                let playback = chosenPlayback ?? CatVodPayload.playback(playRun.json)
                report["playAttempts"] = attempts
                stages.append(Stage(name: "player", ok: playback?.url.hasPrefix("http") == true,
                                    detail: "字段 \(CatVodPayload.keys(in: playRun.json).joined(separator: ",")) / \(playback?.url.prefix(110) ?? playRun.json.prefix(120))"))
                report["playRaw"] = String(playRun.json.prefix(400))
                report["playRequests"] = playRun.requestTrace.map {
                    ["url": $0.url, "code": $0.code, "method": $0.method,
                     "bodyBytes": $0.bodyBytes, "contentType": $0.contentType] as [String: Any]
                }
            } catch {
                stages.append(Stage(name: "error", ok: false, detail: error.localizedDescription))
                report["error"] = error.localizedDescription
            }
            report["stages"] = stages.map { ["name": $0.name, "ok": $0.ok, "detail": $0.detail] }
            report["notes"] = notes
            report["passed"] = stages.allSatisfy(\.ok) && !stages.isEmpty
            reports.append(report)
            print("CHAIN \(site.key) " + stages.map { "\($0.name):\($0.ok ? "ok" : "fail")" }.joined(separator: " "))
            for note in notes.prefix(6) { print("   NOTE \(note["stage"] ?? "") \(note["note"] ?? "")") }
        }

        let destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("dist/plugin-chain-report.json")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["sources": reports],
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: destination, options: .atomic)

        let failures = reports.filter { ($0["passed"] as? Bool) != true }
        XCTAssertTrue(failures.isEmpty, "有来源没跑通: \(failures.compactMap { $0["key"] as? String })")
    }
}
