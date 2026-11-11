import Foundation
import SwiftSoup

/// 将插件内置的 HTML 库接到 SwiftSoup。只匹配库方法签名，不包含站点域名或选择器。
enum DalvikHTMLSupport {
    static func install(_ vm: DalvikVM) {
        let elementName = "Lcom/github/catvod/spider/merge/hN;"
        let listName = "Lcom/github/catvod/spider/merge/kB;"
        let documentName = "Lcom/github/catvod/spider/merge/Va;"
        guard let element = vm.image.classes[elementName], let parentName = element.superName,
              element.methods["cS"]?.contains(where: { $0.params == ["Ljava/lang/String;"] && $0.ret == listName }) == true,
              vm.image.classes[listName]?.superName == "Ljava/util/ArrayList;" else { return }

        func wrap(_ node: Element?) -> DalvikValue {
            guard let node else { return .ref(nil) }
            let object = DalvikObject(className: node is Document ? documentName : elementName)
            object.payload = node
            return .ref(object)
        }
        func list(_ elements: [Element]) -> DalvikValue {
            let object = DalvikObject(className: listName)
            object.items = elements.map { wrap($0) }
            return .ref(object)
        }
        for info in vm.image.classes.values {
            for methods in info.methods.values {
                for method in methods where method.isStatic {
                    if method.params == ["Ljava/lang/String;"], method.ret == documentName {
                        vm.registerOverride(method.owner, method.name) { vm, _, args in
                            wrap(try SwiftSoup.parse(DalvikNatives.text(args.first), vm.httpLog.last?.url ?? ""))
                        }
                    } else if method.params == ["Ljava/lang/String;", elementName], method.ret == elementName {
                        vm.registerOverride(method.owner, method.name) { _, _, args in
                            guard let node = args[1].asObject?.payload as? Element else { return .ref(nil) }
                            return wrap(try node.select(DalvikNatives.text(args.first)).first())
                        }
                    }
                }
            }
        }
        vm.registerOverride(elementName, "cS") { _, this, args in
            guard let node = this?.payload as? Element else { return list([]) }
            return list(try node.select(DalvikNatives.text(args.first)).array())
        }
        vm.registerOverride(elementName, "OB") { _, this, args in
            guard let node = this?.payload as? Element else { return .ref(nil) }
            return wrap(try node.select(DalvikNatives.text(args.first)).first())
        }
        vm.registerOverride(elementName, "Fo") { _, this, _ in
            .ref(DalvikObject.string(try (this?.payload as? Element)?.text() ?? ""))
        }
        vm.registerOverride(elementName, "h") { _, this, _ in
            .ref(DalvikObject.string(try (this?.payload as? Element)?.html() ?? ""))
        }
        vm.registerOverride(elementName, "mG") { _, this, _ in
            .ref(DalvikObject.string(try (this?.payload as? Element)?.html() ?? ""))
        }
        for name in ["ee", "toString"] {
            vm.registerOverride(parentName, name) { _, this, _ in
                .ref(DalvikObject.string(try (this?.payload as? Element)?.outerHtml() ?? ""))
            }
        }
        vm.registerOverride(elementName, "nQ") { _, this, _ in
            .ref(DalvikObject.string((this?.payload as? Element)?.tagName() ?? ""))
        }
        vm.registerOverride(elementName, "Hj") { _, this, _ in
            .ref(DalvikObject.string(try (this?.payload as? Element)?.attr("id") ?? ""))
        }
        vm.registerOverride(elementName, "p") { _, this, args in
            .int((this?.payload as? Element)?.hasClass(DalvikNatives.text(args.first)) == true ? 1 : 0)
        }
        vm.registerOverride(parentName, "N") { _, this, args in
            guard let node = this?.payload as? Element else { return .ref(DalvikObject.string("")) }
            let key = DalvikNatives.text(args.first)
            let value = key.hasPrefix("abs:") ? try node.absUrl(String(key.dropFirst(4))) : try node.attr(key)
            return .ref(DalvikObject.string(value))
        }
        vm.registerOverride(parentName, "G4") { _, this, args in
            .int((this?.payload as? Element)?.hasAttr(DalvikNatives.text(args.first)) == true ? 1 : 0)
        }
        vm.registerOverride(listName, "tF") { _, this, _ in this?.items?.first ?? .ref(nil) }
        vm.registerOverride(listName, "zH") { _, this, _ in this?.items?.last ?? .ref(nil) }
        vm.registerOverride(listName, "t0") { _, this, _ in
            let texts = try (this?.items ?? []).compactMap { try ($0.asObject?.payload as? Element)?.text() }
            return .ref(DalvikObject.string(texts.joined(separator: " ")))
        }
        vm.registerOverride(listName, "yq") { _, this, args in
            let key = DalvikNatives.text(args.first)
            for value in this?.items ?? [] {
                if let node = value.asObject?.payload as? Element, node.hasAttr(key) {
                    return .ref(DalvikObject.string(try node.attr(key)))
                }
            }
            return .ref(DalvikObject.string(""))
        }
    }
}
