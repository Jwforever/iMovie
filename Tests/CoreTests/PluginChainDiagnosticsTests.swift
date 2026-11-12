import Foundation
import XCTest
@testable import iMovieCore

/// 端到端链路自测：首页 → 详情 → 选集 → 播放地址。
///
/// 只挑几个已知能出内容的采集器，逐段断言"上一步的产物能喂给下一步"，
/// 并把每一段的实际请求和结果写进 `dist/plugin-chain-report.json`。
/// 默认不跑（会打真实站点），由 CI 用 `IMOVIE_CHAIN_DIAGNOSTICS=1` 触发。
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
        let keys = Set((environment["IMOVIE_CHAIN_KEYS"] ?? "YGP,MTV1")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })

        let config = try await HTTPClient().config(at: "http://www.饭太硬.cc/tv")
        let selected = config.sites.filter { $0.isPlugin && keys.contains($0.key) }
        XCTAssertFalse(selected.isEmpty, "没有匹配到要测的来源")

        var reports: [[String: Any]] = []
        for site in selected {
            var report: [String: Any] = ["key": site.key, "name": site.name, "api": site.api]
            var stages: [Stage] = []
            do {
                // 1. 首页
                let home = try await DalvikSourceAdapter(site: site)
                    .page(category: nil, search: nil, page: 1)
                stages.append(Stage(name: "home", ok: !home.videos.isEmpty,
                                    detail: "分类 \(home.categories.count) / 影片 \(home.videos.count)"))
                report["categories"] = home.categories.prefix(5).map { ["id": $0.id, "name": $0.name] }
                report["homeVideos"] = home.videos.prefix(5).map { ["id": $0.id, "title": $0.title] }

                guard let first = home.videos.first else {
                    throw ViewerError.message("首页没有影片")
                }

                // 2. 详情
                let detail = try await DalvikSourceAdapter(site: site).detail(id: first.id)
                let lines = detail.lines
                stages.append(Stage(name: "detail", ok: !lines.isEmpty,
                                    detail: "《\(detail.title)》线路 \(lines.count) / 集数 \(lines.map(\.episodes.count).reduce(0, +))"))
                report["detailTitle"] = detail.title
                report["playFrom"] = detail.playFrom
                report["episodes"] = lines.first?.episodes.prefix(3).map { ["title": $0.title, "value": $0.value] }

                guard let line = lines.first, let episode = line.episodes.first else {
                    throw ViewerError.message("详情里没有选集")
                }

                // 3. 播放地址
                let media = try await DalvikSourceAdapter(site: site)
                    .resolve(episode: episode, flag: line.name, title: detail.title)
                let playable = media.url.hasPrefix("http")
                stages.append(Stage(name: "player", ok: playable,
                                    detail: "\(media.kind == .web ? "需要解析" : "直链") \(media.url.prefix(110))"))
                report["mediaURL"] = media.url
                report["mediaKind"] = media.kind?.rawValue ?? "direct"
                report["mediaHeaders"] = media.headers
            } catch {
                stages.append(Stage(name: "error", ok: false, detail: error.localizedDescription))
                report["error"] = error.localizedDescription
            }
            report["stages"] = stages.map { ["name": $0.name, "ok": $0.ok, "detail": $0.detail] }
            report["passed"] = stages.allSatisfy(\.ok) && !stages.isEmpty
            reports.append(report)
            print("CHAIN \(site.key) -> " + stages.map { "\($0.name):\($0.ok ? "ok" : "fail")" }.joined(separator: " "))
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
