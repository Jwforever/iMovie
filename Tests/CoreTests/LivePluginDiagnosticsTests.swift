import Foundation
import XCTest
@testable import iMovieCore

final class LivePluginDiagnosticsTests: XCTestCase {
    func testSourceDiagnosticsWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["IMOVIE_SOURCE_DIAGNOSTICS"] == "1" else { return }
        let url = try HTTPAddress.parse("http://www.饭太硬.cc/tv")
        let config = try await HTTPClient().config(at: url.absoluteString)
        let dex = try await SpiderPluginCache.shared.dex(spider: config.spider)
        let index = GuardRuleCatalog.decode(file: try DexFile(data: dex), source: config.spider ?? "")
        let requestedKeys = Set((ProcessInfo.processInfo.environment["IMOVIE_SOURCE_DIAGNOSTICS_KEYS"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let sites = config.sites.filter { $0.isPlugin && (requestedKeys.isEmpty || requestedKeys.contains($0.key) || requestedKeys.contains($0.pluginClassName ?? "")) }
        var reports: [[String: Any]] = []
        let destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/plugin-source-diagnostics.json")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let classCount = try DalvikImage(data: dex).classes.count
        func saveReports() throws {
            let data = try JSONSerialization.data(withJSONObject: ["spider": config.spider ?? "", "classes": classCount, "sources": reports], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: destination, options: .atomic)
        }
        // 同一个 collector 只诊断一次；保留所有配置条目及原始域名来源。
        // 插件解释器和 SwiftSoup 都会分配较大的临时对象，逐源执行以免并行诊断耗尽 runner 内存。
        for batchStart in stride(from: 0, to: sites.count, by: 1) {
            let batch = [sites[batchStart]]
            let output = await withTaskGroup(of: [String: Any].self) { group in
                for site in batch {
                    group.addTask {
                        var report: [String: Any] = ["key": site.key, "api": site.api]
                        let name = site.pluginClassName ?? ""
                        if let profile = index.profiles[name] {
                            report["hosts"] = profile.hosts
                            if let rule = GuardRuleBuilder.rule(for: profile, ext: site.extensionValue) {
                                report["rule"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(rule))) ?? [:]
                                do {
                                    let request = URLRequest(url: try HTTPAddress.parse(rule.baseURL), timeoutInterval: 8)
                                    let (bytes, response) = try await URLSession.shared.data(for: request)
                                    report["status"] = (response as? HTTPURLResponse)?.statusCode ?? 0
                                    report["finalURL"] = response.url?.absoluteString ?? ""
                                    do {
                                        let page = try GenericSourceAdapter.decodePage(bytes, baseURL: response.url ?? request.url!, rule: rule, page: 1)
                                        report["ruleVideos"] = page.videos.count
                                        report["firstTitle"] = page.videos.first?.title ?? ""
                                    } catch { report["ruleError"] = error.localizedDescription }
                                } catch { report["networkError"] = error.localizedDescription }
                            } else { report["ruleError"] = "未生成规则" }
                        }
                        do {
                            let output = try await Task.detached {
                                var output = try DalvikSpider.execute(dex: dex, shortName: name, action: .home, ext: site.extensionValue ?? "",
                                                         maximumSteps: 4_000_000, timeout: 12)
                                if let page = CatVodPayload.page(output.json), page.videos.isEmpty, let category = page.categories.first {
                                    let categoryOutput = try DalvikSpider.execute(dex: dex, shortName: name, action: .category(id: category.id, page: "1"), ext: site.extensionValue ?? "", maximumSteps: 4_000_000, timeout: 12)
                                    output = categoryOutput
                                }
                                return output
                            }.value
                            report["interpreterVideos"] = CatVodPayload.page(output.json)?.videos.count ?? 0
                            report["interpreterRequests"] = output.requests.map { ["url": $0.url, "status": $0.code] as [String: Any] }
                            report["output"] = String(output.json.prefix(200))
                            if let first = CatVodPayload.page(output.json)?.videos.first {
                                report["firstVideo"] = ["id": first.id, "title": first.title, "poster": first.poster]
                                do {
                                    let detail = try await Task.detached {
                                        try DalvikSpider.execute(dex: dex, shortName: name, action: .detail(id: first.id), ext: site.extensionValue ?? "", maximumSteps: 4_000_000, timeout: 12)
                                    }.value
                                    report["detailOutput"] = String(detail.json.prefix(500))
                                    report["detailRequests"] = detail.requests.map { ["url": $0.url, "status": $0.code] as [String: Any] }
                                    if let video = CatVodPayload.detail(detail.json) {
                                        report["detailTitle"] = video.title
                                        report["episodeCount"] = video.lines.reduce(0) { $0 + $1.episodes.count }
                                        if ["Auete", "Dm84", "Bttwoo", "Nmyswv"].contains(name), let line = video.lines.first, let episode = line.episodes.first {
                                            do {
                                                let output = try await Task.detached {
                                                    try DalvikSpider.execute(dex: dex, shortName: name, action: .player(flag: line.name, id: episode.value), ext: site.extensionValue ?? "", maximumSteps: 4_000_000, timeout: 12)
                                                }.value
                                                report["playerOutput"] = String(output.json.prefix(800))
                                                if let result = CatVodPayload.playback(output.json) {
                                                    report["playerURL"] = result.url
                                                    var media = MediaLink(title: video.title, url: result.url, headers: result.headers, kind: result.needsParsing ? .web : .direct)
                                                    media = try await MediaResolver().resolve(media)
                                                    report["resolvedMedia"] = media.url
                                                    var request = URLRequest(url: try HTTPAddress.parse(media.url), timeoutInterval: 10)
                                                    media.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
                                                    request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
                                                    let (data, response) = try await URLSession.shared.data(for: request)
                                                    report["mediaStatus"] = (response as? HTTPURLResponse)?.statusCode ?? 0
                                                    report["mediaBytes"] = data.count
                                                    report["mediaPrefix"] = String(decoding: data.prefix(80), as: UTF8.self)
                                                }
                                            } catch { report["playerError"] = error.localizedDescription }
                                        }
                                    }
                                } catch { report["detailError"] = error.localizedDescription }
                                if ["Auete", "Dm84", "Bttwoo", "Nmyswv"].contains(name) {
                                    do {
                                        let search = try await Task.detached {
                                            try DalvikSpider.execute(dex: dex, shortName: name, action: .search(keyword: "月"), ext: site.extensionValue ?? "", maximumSteps: 4_000_000, timeout: 12)
                                        }.value
                                        report["searchVideos"] = CatVodPayload.page(search.json)?.videos.count ?? 0
                                        report["searchRequests"] = search.requests.map { ["url": $0.url, "status": $0.code] as [String: Any] }
                                    } catch { report["searchError"] = error.localizedDescription }
                                }
                            }
                        } catch { report["interpreterError"] = error.localizedDescription }
                        return report
                    }
                }
                var result: [[String: Any]] = []
                for await value in group { result.append(value) }
                return result
            }
            reports += output
            for report in output {
                if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let text = String(data: bytes, encoding: .utf8) {
                    FileHandle.standardOutput.write(Data(("SOURCE_DIAGNOSTIC " + text + "\n").utf8))
                }
            }
            try saveReports()
        }
        try saveReports()
    }
}
