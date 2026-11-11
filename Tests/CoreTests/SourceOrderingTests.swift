import XCTest
@testable import iMovieCore

/// 排序必须在导入时定死，不能因为后台探测结果回来而跳动。
final class SourceOrderingTests: XCTestCase {
    private func site(_ key: String) -> SourceSite {
        SourceSite(key: key, name: key, api: "csp_\(key)Guard", searchable: true)
    }

    func testDefaultSourceAlwaysFirst() {
        let sites = [site("a"), site("b"), site("c")]
        let ordered = SourceOrdering.arrange(sites, ranks: ["a": 3, "b": 3, "c": 3], preferred: "b")
        XCTAssertEqual(ordered.map(\.key), ["b", "a", "c"])
    }

    func testWorkingSourcesRankAboveUntestedAndBroken() {
        let sites = [site("broken"), site("untested"), site("working")]
        let ranks = ["broken": 0, "working": 3]
        let ordered = SourceOrdering.arrange(sites, ranks: ranks, preferred: nil)
        XCTAssertEqual(ordered.map(\.key), ["working", "untested", "broken"])
    }

    func testEqualRanksKeepConfigurationOrder() {
        let sites = [site("x"), site("y"), site("z")]
        let ordered = SourceOrdering.arrange(sites, ranks: [:], preferred: nil)
        XCTAssertEqual(ordered.map(\.key), ["x", "y", "z"])
    }

    func testSavedOrderWinsOverLiveRanks() {
        let sites = [site("a"), site("b"), site("c")]
        // 已保存的顺序是 c,b,a；即使 health 变了，界面也不该重排。
        let applied = SourceOrdering.apply(order: ["c", "b", "a"], to: sites)
        XCTAssertEqual(applied.map(\.key), ["c", "b", "a"])
    }

    func testNewSourcesAppendAtEnd() {
        let sites = [site("a"), site("b"), site("new")]
        let applied = SourceOrdering.apply(order: ["b", "a"], to: sites)
        XCTAssertEqual(applied.map(\.key), ["b", "a", "new"])
    }
}
