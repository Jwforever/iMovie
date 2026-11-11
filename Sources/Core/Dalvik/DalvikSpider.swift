import Foundation

/// 用解释器执行插件里的采集器，得到和 OK影视 同一份结果。
///
/// 这是"实验"通道：插件跑在解释器里，选择器和请求逻辑全部来自插件自身，
/// 应用里没有任何站点常量。
enum DalvikSpiderAction {
    case home
    case category(id: String, page: String)
    case detail(id: String)
    case search(keyword: String)
    case player(flag: String, id: String)

    var methodName: String {
        switch self {
        case .home: return "homeContent"
        case .category: return "categoryContent"
        case .detail: return "detailContent"
        case .search: return "searchContent"
        case .player: return "playerContent"
        }
    }
}

struct DalvikRunResult {
    var className: String
    var method: String
    var json: String
    var requests: [(url: String, code: Int)]
    var steps: Int
    var seconds: Double

    var summary: String {
        let codes = requests.map { "\($0.code)" }.joined(separator: ",")
        return "\(method) · \(steps) 步 · \(String(format: "%.1f", seconds))s · 请求 \(requests.count) 次 [\(codes)]"
    }
}

enum DalvikSpider {
    private static let lock = NSLock()
    private static var blockedUntil: [String: Date] = [:]

    /// 刚失败过的采集器，短时间内不再重试，避免每次翻页都白等一遍。
    static func isBlocked(_ api: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let until = blockedUntil[api] else { return false }
        if until > Date() { return true }
        blockedUntil.removeValue(forKey: api)
        return false
    }

    static func block(_ api: String) {
        lock.lock(); defer { lock.unlock() }
        blockedUntil[api] = Date().addingTimeInterval(600)
    }

    static func resetFailures() {
        lock.lock(); defer { lock.unlock() }
        blockedUntil.removeAll()
    }

    /// 与静态规则提取共用同一份经过校验的插件。
    static func dex(spider: String?) async throws -> Data {
        try await SpiderPluginCache.shared.dex(spider: spider)
    }

    /// 在后台执行采集器，返回插件自己产出的 JSON。
    static func run(spider: String?, api: String, action: DalvikSpiderAction,
                    ext: String? = nil) async throws -> DalvikRunResult {
        let data = try await dex(spider: spider)
        guard let short = GuardRuleCatalog.className(fromAPI: api) else {
            throw ViewerError.message("\(api) 不是插件采集器。")
        }
        let control = DalvikExecutionControl()
        return try await withTaskCancellationHandler {
            let result = try await Task.detached(priority: .userInitiated) {
                try execute(dex: data, shortName: short, action: action, ext: ext ?? "", control: control)
            }.value
            try Task.checkCancellation()
            return result
        } onCancel: { control.cancel() }
    }

    static func execute(dex: Data, shortName: String, action: DalvikSpiderAction,
                        ext: String, control: DalvikExecutionControl = DalvikExecutionControl()) throws -> DalvikRunResult {
        try control.checkCancellation()
        let started = Date()
        let image = try DalvikImage(data: dex)
        let className = "Lcom/github/catvod/spider/\(shortName);"
        guard image.classes[className] != nil else {
            throw ViewerError.message("插件里没有 \(shortName) 这个采集器。")
        }
        let vm = DalvikVM(image: image, control: control)
        let spider = DalvikObject(className: className)

        if let ctor = vm.findMethod(className, "<init>", []) {
            _ = try vm.invoke(ctor, [], spider)
        }
        if let initializer = vm.findMethod(className, "init",
                                           ["Landroid/content/Context;", "Ljava/lang/String;"]) {
            let context = DalvikObject(className: "Landroid/content/Context;")
            _ = try vm.invoke(initializer, [.ref(context), .ref(DalvikObject.string(ext))], spider)
        }

        let result: DalvikValue?
        switch action {
        case .home:
            guard let method = vm.findMethod(className, "homeContent", ["Z"]) else {
                throw ViewerError.message("\(shortName) 没有 homeContent。")
            }
            result = try vm.invoke(method, [.int(1)], spider)
        case .category(let id, let page):
            guard let method = vm.findMethod(className, "categoryContent",
                                             ["Ljava/lang/String;", "Ljava/lang/String;",
                                              "Z", "Ljava/util/HashMap;"]) else {
                throw ViewerError.message("\(shortName) 没有 categoryContent。")
            }
            let params = DalvikObject(className: "Ljava/util/HashMap;")
            params.payload = [String: DalvikValue]()
            result = try vm.invoke(method, [.ref(DalvikObject.string(id)),
                                            .ref(DalvikObject.string(page)),
                                            .int(1), .ref(params)], spider)
        case .detail(let id):
            guard let method = vm.findMethod(className, "detailContent",
                                             ["Ljava/util/List;"]) else {
                throw ViewerError.message("\(shortName) 没有 detailContent。")
            }
            let list = DalvikObject(className: "Ljava/util/ArrayList;")
            list.items = [.ref(DalvikObject.string(id))]
            result = try vm.invoke(method, [.ref(list)], spider)
        case .player(let flag, let id):
            guard let method = vm.findMethod(className, "playerContent",
                                             ["Ljava/lang/String;", "Ljava/lang/String;",
                                              "Ljava/util/List;"]) else {
                throw ViewerError.message("\(shortName) 没有 playerContent。")
            }
            let list = DalvikObject(className: "Ljava/util/ArrayList;")
            list.items = []
            result = try vm.invoke(method, [.ref(DalvikObject.string(flag)),
                                            .ref(DalvikObject.string(id)),
                                            .ref(list)], spider)
        case .search(let keyword):
            guard let method = vm.findMethod(className, "searchContent",
                                             ["Ljava/lang/String;", "Z"]) else {
                throw ViewerError.message("\(shortName) 没有 searchContent。")
            }
            result = try vm.invoke(method, [.ref(DalvikObject.string(keyword)), .int(0)], spider)
        }

        let json: String
        if case .ref(let object)? = result, let text = object?.stringPayload {
            json = text
        } else {
            json = DalvikValue.describe(result)
        }
        return DalvikRunResult(className: shortName,
                               method: action.methodName,
                               json: json,
                               requests: vm.httpLog,
                               steps: vm.stepCount,
                               seconds: Date().timeIntervalSince(started))
    }
}

extension DalvikValue {
    static func describe(_ value: DalvikValue?) -> String {
        guard let value else { return "(无返回值)" }
        switch value {
        case .ref(let object):
            guard let object else { return "null" }
            return object.stringPayload ?? "<\(object.className)>"
        default:
            return value.display
        }
    }
}
