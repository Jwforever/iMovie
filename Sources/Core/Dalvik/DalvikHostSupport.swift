import Foundation

extension DalvikNatives {
    /// CatVod 宿主上下文由 iOS 提供，不启动插件 Android UI 或本地服务。
    static func hostSupport(_ vm: DalvikVM) {
        let context = DalvikObject(className: "Landroid/content/Context;")
        var preferences: [String: String] = [:]
        let owner = "Lcom/github/catvod/spider/InitOrigin;"
        for name in ["context", "getActivity"] { vm.registerOverride(owner, name) { _, _, _ in .ref(context) } }
        for name in ["init", "show", "stopShowingToast", "setClass"] { vm.registerOverride(owner, name) { _, _, _ in .ref(nil) } }
        vm.registerOverride(owner, "getSpStr") { _, _, args in
            .ref(DalvikObject.string(preferences[text(args.first)] ?? (args.count > 1 ? text(args[1]) : "")))
        }
        vm.registerOverride(owner, "setSpStr") { _, _, args in
            preferences[text(args.first)] = args.count > 1 ? text(args[1]) : ""; return .ref(nil)
        }
        vm.register("Landroid/content/Context;", "getSharedPreferences") { _, _, _ in .ref(DalvikObject(className: "Landroid/content/SharedPreferences;")) }
        vm.register("Landroid/content/SharedPreferences;", "getString") { _, _, args in
            .ref(DalvikObject.string(preferences[text(args.first)] ?? (args.count > 1 ? text(args[1]) : "")))
        }
        vm.register("Landroid/content/SharedPreferences;", "edit") { _, _, _ in .ref(DalvikObject(className: "Landroid/content/SharedPreferences$Editor;")) }
        vm.register("Landroid/content/SharedPreferences$Editor;", "putString") { _, this, args in
            preferences[text(args.first)] = args.count > 1 ? text(args[1]) : ""; return .ref(this)
        }
        vm.register("Landroid/content/SharedPreferences$Editor;", "apply") { _, _, _ in .ref(nil) }
        vm.register("Landroid/content/SharedPreferences$Editor;", "commit") { _, _, _ in .int(1) }
    }
}
