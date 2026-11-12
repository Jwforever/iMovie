import Foundation
import SwiftSoup

/// 将插件内置的 HTML 库接到 SwiftSoup。只匹配库方法签名，不包含站点域名或选择器。
/// 方法名与语义来自对插件内置 DOM 库的反编译：
///   Fo=text  lF=data  kR=ownText  h/mG=html  L/OW=parent  J=children  C/Dr=siblingIndex
///   o=nextElementSibling  u7=previousElementSibling  Cu=parents  N0=firstElementChild
///   I=tag  tl/nQ/v=tagName  Qz=text(String)  V=attr(k,v)  E1=appendChild  m=appendElement
enum DalvikHTMLSupport {
    static func install(_ vm: DalvikVM) {
        let elementName = "Lcom/github/catvod/spider/merge/hN;"
        let listName = "Lcom/github/catvod/spider/merge/kB;"
        let documentName = "Lcom/github/catvod/spider/merge/Va;"
        guard let element = vm.image.classes[elementName], let parentName = element.superName,
              element.methods["cS"]?.contains(where: { $0.params == ["Ljava/lang/String;"] && $0.ret == listName }) == true,
              vm.image.classes[listName]?.superName == "Ljava/util/ArrayList;" else { return }

        func wrap(_ node: Node?) -> DalvikValue {
            guard let node else { return .ref(nil) }
            return .ref(wrapObject(node))
        }
        func wrapObject(_ node: Node) -> DalvikObject {
            let object = DalvikObject(className: node is Document ? documentName : elementName)
            object.payload = node
            return object
        }
        func list(_ elements: [Node]) -> DalvikValue {
            let object = DalvikObject(className: listName)
            object.items = elements.map { wrap($0) }
            return .ref(object)
        }
        func elementOf(_ value: DalvikValue?) -> Element? {
            value?.asObject?.payload as? Element
        }
        func nodesOf(_ value: DalvikValue?) -> Node? {
            value?.asObject?.payload as? Node
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
                            guard let node = elementOf(args[1]) else { return .ref(nil) }
                            return wrap(try node.select(DalvikNatives.text(args.first)).first())
                        }
                    }
                }
            }
        }
        // MARK: 选择与文本
        vm.registerOverride(elementName, "cS") { _, this, args in
            guard let node = elementOf(this) else { return list([]) }
            return list(try node.select(DalvikNatives.text(args.first)).array())
        }
        vm.registerOverride(elementName, "OB") { _, this, args in
            guard let node = elementOf(this) else { return .ref(nil) }
            return wrap(try node.select(DalvikNatives.text(args.first)).first())
        }
        vm.registerOverride(elementName, "Fo") { _, this, _ in
            .ref(DalvikObject.string(try (elementOf(this))?.text() ?? ""))
        }
        vm.registerOverride(elementName, "kR") { _, this, _ in
            .ref(DalvikObject.string((elementOf(this))?.ownText() ?? ""))
        }
        vm.registerOverride(elementName, "lF") { _, this, _ in
            // data()：取 <script>/<style> 的原始内容，播放地址解析的关键路径。
            .ref(DalvikObject.string((elementOf(this))?.data() ?? ""))
        }
        vm.registerOverride(elementName, "h") { _, this, _ in
            .ref(DalvikObject.string(try (elementOf(this))?.html() ?? ""))
        }
        vm.registerOverride(elementName, "mG") { _, this, _ in
            .ref(DalvikObject.string(try (elementOf(this))?.html() ?? ""))
        }
        for name in ["ee", "toString"] {
            vm.registerOverride(parentName, name) { _, this, _ in
                .ref(DalvikObject.string(try (this?.payload as? Node).map { try $0.outerHtml() } ?? ""))
            }
        }
        // MARK: 结构导航
        vm.registerOverride(elementName, "L") { _, this, _ in wrap(elementOf(this)?.parent()) }
        vm.registerOverride(parentName, "OW") { _, this, _ in wrap((this?.payload as? Node)?.parent()) }
        vm.registerOverride(parentName, "b") { _, this, _ in
            var node = this?.payload as? Node
            while let parent = node?.parent() { node = parent }
            return wrap(node)
        }
        vm.registerOverride(elementName, "J") { _, this, _ in
            guard let node = elementOf(this) else { return list([]) }
            return list(node.children().array())
        }
        vm.registerOverride(parentName, "G") { _, this, _ in
            guard let node = this?.payload as? Node else { return list([]) }
            return list((try? node.childNodesCopy()) ?? [])
        }
        vm.registerOverride(elementName, "G") { _, this, _ in
            guard let node = elementOf(this) else { return list([]) }
            return list(node.children().array())
        }
        vm.registerOverride(elementName, "Cu") { _, this, _ in
            guard let node = elementOf(this) else { return list([]) }
            return list(node.parents().array())
        }
        vm.registerOverride(elementName, "N0") { _, this, _ in
            wrap(elementOf(this)?.children().first())
        }
        vm.registerOverride(elementName, "o") { _, this, _ in
            wrap(try elementOf(this)?.nextElementSibling())
        }
        vm.registerOverride(elementName, "u7") { _, this, _ in
            wrap(try elementOf(this)?.previousElementSibling())
        }
        vm.registerOverride(elementName, "ue") { _, this, _ in
            guard let node = elementOf(this), let parent = node.parent() else { return list([]) }
            let siblings = (try? parent.children().array()) ?? []
            return list(siblings.filter { $0 !== node })
        }
        vm.registerOverride(elementName, "C") { _, this, _ in
            guard let node = elementOf(this) else { return .int(0) }
            let index = (try? node.elementSiblingIndex()) ?? node.siblingIndex
            return .int(Int32(index))
        }
        vm.registerOverride(parentName, "Dr") { _, this, _ in
            .int(Int32((this?.payload as? Node)?.siblingIndex ?? 0))
        }
        vm.registerOverride(parentName, "F5") { _, this, _ in
            .int(((this?.payload as? Node)?.parent() != nil) ? 1 : 0)
        }
        vm.registerOverride(parentName, "W") { _, this, _ in
            guard let node = this?.payload as? Node, let parent = node.parent(),
                  let siblings = try? parent.childNodesCopy() else { return .ref(nil) }
            let next = node.siblingIndex + 1
            guard siblings.indices.contains(next) else { return .ref(nil) }
            return wrap(siblings[next])
        }
        vm.registerOverride(parentName, "i") { _, this, args in
            guard let node = this?.payload as? Node,
                  let children = try? node.childNodesCopy() else { return .ref(nil) }
            let index = Int(args.first?.intValue ?? 0)
            guard children.indices.contains(index) else { return .ref(nil) }
            return wrap(children[index])
        }
        // MARK: 名称与属性
        vm.registerOverride(elementName, "nQ") { _, this, _ in
            .ref(DalvikObject.string((elementOf(this))?.tagName() ?? ""))
        }
        vm.registerOverride(elementName, "tl") { _, this, _ in
            .ref(DalvikObject.string((elementOf(this))?.tagName() ?? ""))
        }
        vm.registerOverride(parentName, "v") { _, this, _ in
            guard let node = this?.payload as? Node else { return .ref(DalvikObject.string("")) }
            let name = (node as? Element)?.tagName() ?? (node is TextNode ? "#text" : "#node")
            return .ref(DalvikObject.string(name))
        }
        vm.registerOverride(elementName, "v") { _, this, _ in
            .ref(DalvikObject.string((elementOf(this))?.tagName() ?? ""))
        }
        vm.registerOverride(elementName, "Hj") { _, this, _ in
            .ref(DalvikObject.string(try (elementOf(this))?.attr("id") ?? ""))
        }
        vm.registerOverride(elementName, "p") { _, this, args in
            .int((elementOf(this))?.hasClass(DalvikNatives.text(args.first)) == true ? 1 : 0)
        }
        vm.registerOverride(parentName, "N") { _, this, args in
            guard let node = this?.payload as? Node else { return .ref(DalvikObject.string("")) }
            let key = DalvikNatives.text(args.first)
            let value = key.hasPrefix("abs:") ? try node.absUrl(String(key.dropFirst(4))) : try node.attr(key)
            return .ref(DalvikObject.string(value))
        }
        vm.registerOverride(parentName, "G4") { _, this, args in
            .int((this?.payload as? Node)?.hasAttr(DalvikNatives.text(args.first)) == true ? 1 : 0)
        }
        vm.registerOverride(elementName, "w") { _, this, _ in
            .int(((try elementOf(this)?.text()) ?? "").isEmpty ? 0 : 1)
        }
        vm.registerOverride(parentName, "zH") { _, this, _ in
            .ref(DalvikObject.string(""))
        }
        vm.registerOverride(elementName, "zH") { _, this, _ in
            .ref(DalvikObject.string(""))
        }
        vm.registerOverride(elementName, "b") { _, this, _ in
            var node = elementOf(this) as Node?
            while let parent = node?.parent() { node = parent }
            return wrap(node)
        }
        // MARK: 修改操作
        vm.registerOverride(elementName, "Qz") { _, this, args in
            guard let node = elementOf(this) else { return .ref(nil) }
            try node.text(DalvikNatives.text(args.first))
            return .ref(this)
        }
        vm.registerOverride(elementName, "V") { _, this, args in
            guard let node = elementOf(this) else { return .ref(nil) }
            try node.attr(DalvikNatives.text(args.first), DalvikNatives.text(args.count > 1 ? args[1] : nil))
            return .ref(this)
        }
        vm.registerOverride(elementName, "E1") { _, this, args in
            guard let node = elementOf(this), let child = nodesOf(args.first) else { return .ref(nil) }
            try node.appendChild(child)
            return .ref(this)
        }
        vm.registerOverride(elementName, "RQ") { _, this, args in
            guard let node = elementOf(this) else { return .ref(nil) }
            try node.appendChild(TextNode(DalvikNatives.text(args.first), node.getBaseUri()))
            return .ref(this)
        }
        vm.registerOverride(elementName, "m") { _, this, args in
            guard let node = elementOf(this) else { return .ref(nil) }
            return wrap(try node.appendElement(DalvikNatives.text(args.first)))
        }
        vm.registerOverride(elementName, "t0") { _, this, _ in
            guard let node = this?.payload as? Node else { return .int(0) }
            return .int(Int32((try? node.childNodesCopy())?.count ?? 0))
        }
        // MARK: Tag（Go）与 Attributes（a）
        let tagName = "Lcom/github/catvod/spider/merge/Go;"
        let attrName = "Lcom/github/catvod/spider/merge/a;"
        vm.registerOverride(elementName, "I") { _, this, _ in
            let object = DalvikObject(className: tagName)
            object.payload = elementOf(this)?.tagName() ?? ""
            return .ref(object)
        }
        for name in ["KJ", "SN", "v", "toString"] {
            vm.registerOverride(tagName, name) { _, this, _ in
                .ref(DalvikObject.string(this?.payload as? String ?? ""))
            }
        }
        for name in ["M", "N", "i", "q", "t0", "tF", "yq", "zH"] {
            vm.registerOverride(tagName, name) { _, _, _ in .int(0) }
        }
        for name in ["B", "G", "M"] {
            vm.registerOverride(attrName, name) { _, this, args in
                guard let node = this?.payload as? Node else { return .ref(DalvikObject.string("")) }
                let key = DalvikNatives.text(args.first)
                let value = key.hasPrefix("abs:") ? try node.absUrl(String(key.dropFirst(4))) : try node.attr(key)
                return .ref(DalvikObject.string(value))
            }
        }
        for name in ["Gd", "tF", "Nl"] {
            vm.registerOverride(attrName, name) { _, this, args in
                if let node = this?.payload as? Node, args.count > 1 {
                    try node.attr(DalvikNatives.text(args.first), DalvikNatives.text(args[1]))
                }
                return .ref(this)
            }
        }
        vm.registerOverride(attrName, "size") { _, this, _ in
            guard let node = this?.payload as? Node else { return .int(0) }
            return .int(Int32(node.attributes()?.size() ?? 0))
        }
        vm.registerOverride(elementName, "tF") { _, this, _ in
            let object = DalvikObject(className: attrName)
            object.payload = this?.payload as? Node
            return .ref(object)
        }
        // MARK: 列表（kB）
        vm.registerOverride(listName, "tF") { _, this, _ in this?.items?.first ?? .ref(nil) }
        vm.registerOverride(listName, "zH") { _, this, _ in this?.items?.last ?? .ref(nil) }
        vm.registerOverride(listName, "t0") { _, this, _ in
            var texts: [String] = []
            for value in this?.items ?? [] {
                guard let node = elementOf(value), try node.text().isEmpty == false else { continue }
                texts.append(try node.text())
            }
            return .ref(DalvikObject.string(texts.joined(separator: " ")))
        }
        vm.registerOverride(listName, "yq") { _, this, args in
            let key = DalvikNatives.text(args.first)
            for value in this?.items ?? [] {
                if let node = elementOf(value), node.hasAttr(key) {
                    return .ref(DalvikObject.string(try node.attr(key)))
                }
            }
            return .ref(DalvikObject.string(""))
        }
        vm.registerOverride(listName, "N") { _, this, args in
            let index = Int(args.first?.intValue ?? 0)
            guard let items = this?.items, items.indices.contains(index) else { return list([]) }
            let object = DalvikObject(className: listName)
            object.items = [items[index]]
            return .ref(object)
        }
        vm.registerOverride(listName, "SN") { _, this, _ in
            var texts: [DalvikValue] = []
            for value in this?.items ?? [] {
                guard let node = elementOf(value), try node.text().isEmpty == false else { continue }
                texts.append(.ref(DalvikObject.string(try node.text())))
            }
            let object = DalvikObject(className: "Ljava/util/ArrayList;")
            object.items = texts
            return .ref(object)
        }
        vm.registerOverride(listName, "i") { _, this, args in
            let selector = DalvikNatives.text(args.first)
            var seen = Set<ObjectIdentifier>()
            var merged: [Element] = []
            for value in this?.items ?? [] {
                guard let node = elementOf(value) else { continue }
                for hit in try node.select(selector).array() where !seen.contains(ObjectIdentifier(hit)) {
                    seen.insert(ObjectIdentifier(hit))
                    merged.append(hit)
                }
            }
            return list(merged)
        }
        vm.registerOverride(listName, "toString") { _, this, _ in
            let parts = try (this?.items ?? []).compactMap { try (elementOf($0))?.outerHtml() }
            return .ref(DalvikObject.string(parts.joined(separator: "\n")))
        }
    }
}
