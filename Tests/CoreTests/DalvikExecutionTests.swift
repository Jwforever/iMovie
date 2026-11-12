import Foundation
import XCTest
@testable import iMovieCore

/// 直接执行小段 DEX，检查指令结果；不依赖某个网站当前是否可访问。
final class DalvikExecutionTests: XCTestCase {
    struct Reference { var owner: String; var name: String; var params: [String]; var ret = "I" }

    private func machine(_ words: [UInt16], registers: Int = 8, params: [String] = [],
                         references: [Reference] = [], tries: Int = 0, tail: [UInt8] = [],
                         control: DalvikExecutionControl = DalvikExecutionControl(),
                         maximumSteps: Int = 20_000_000, timeout: TimeInterval = 5,
                         session: URLSession = .shared) throws -> (DalvikVM, DalvikMethod) {
        var bytes = Data(repeating: 0, count: 128)
        func put(_ value: Int, at offset: Int, width: Int = 4) {
            for i in 0..<width { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
        }
        func append(_ value: Int, width: Int = 4) {
            for i in 0..<width { bytes.append(UInt8(truncatingIfNeeded: value >> (8 * i))) }
        }
        var types: [String] = [], strings: [String] = []
        for type in params + references.flatMap({ [$0.owner, $0.ret] + $0.params }) where !types.contains(type) { types.append(type) }
        for string in types + references.map(\.name) where !strings.contains(string) { strings.append(string) }
        put(strings.count, at: 56); put(bytes.count, at: 60)
        let stringsOffset = bytes.count
        bytes.append(Data(repeating: 0, count: strings.count * 4))
        for (index, string) in strings.enumerated() {
            put(bytes.count, at: stringsOffset + index * 4)
            bytes.append(UInt8(string.utf8.count))
            bytes.append(contentsOf: string.utf8); bytes.append(0)
        }
        while bytes.count % 4 != 0 { bytes.append(0) }
        put(types.count, at: 64); put(bytes.count, at: 68)
        for type in types { append(strings.firstIndex(of: type)!) }
        put(references.count, at: 72); put(bytes.count, at: 76)
        let protoOffset = bytes.count
        bytes.append(Data(repeating: 0, count: references.count * 12))
        for (index, ref) in references.enumerated() {
            put(types.firstIndex(of: ref.ret)!, at: protoOffset + index * 12 + 4)
            if !ref.params.isEmpty {
                put(bytes.count, at: protoOffset + index * 12 + 8)
                append(ref.params.count)
                for param in ref.params { append(types.firstIndex(of: param)!, width: 2) }
                while bytes.count % 4 != 0 { bytes.append(0) }
            }
        }
        put(references.count, at: 88); put(bytes.count, at: 92)
        for (index, ref) in references.enumerated() {
            append(types.firstIndex(of: ref.owner)!, width: 2)
            append(index, width: 2); append(strings.firstIndex(of: ref.name)!)
        }
        let codeOffset = bytes.count
        append(registers, width: 2)
        append(params.reduce(0) { $0 + (["J", "D"].contains($1) ? 2 : 1) }, width: 2)
        append(8, width: 2); append(tries, width: 2); append(0); append(words.count)
        for word in words { append(Int(word), width: 2) }
        if tries > 0 && words.count % 2 != 0 { append(0, width: 2) }
        bytes.append(contentsOf: tail)
        let vm = DalvikVM(image: try DalvikImage(data: bytes), control: control,
                          maximumSteps: maximumSteps, timeout: timeout, httpSession: session)
        let method = DalvikMethod(owner: "Ltest;", name: "test", params: params, ret: "I", access: 8, codeOffset: codeOffset)
        return (vm, method)
    }

    func testReferenceZeroBranchesAndIdentity() throws {
        let (vm, method) = try machine([0x0238, 4, 0x1012, 0x000F, 0x0012, 0x000F], registers: 3,
                                       params: ["Ljava/lang/Object;"])
        XCTAssertEqual(try vm.invoke(method, [.ref(nil)], nil)?.intValue, 0)
        XCTAssertEqual(try vm.invoke(method, [.ref(DalvikObject.string(""))], nil)?.intValue, 1)
        let (nonzeroVM, nonzero) = try machine([0x0239, 4, 0x1012, 0x000F, 0x0012, 0x000F],
                                              registers: 3, params: ["Ljava/lang/Object;"])
        XCTAssertEqual(try nonzeroVM.invoke(nonzero, [.ref(DalvikObject.string("x"))], nil)?.intValue, 0)
        XCTAssertEqual(try nonzeroVM.invoke(nonzero, [.ref(nil)], nil)?.intValue, 1)
        let left = DalvikObject.string("same"), right = DalvikObject.string("same")
        XCTAssertFalse(DalvikValue.ref(left).equalsRegister(.ref(right)))
        XCTAssertTrue(DalvikValue.ref(left).equalsRegister(.ref(left)))
        XCTAssertTrue(DalvikValue.ref(nil).equalsRegister(.int(0)))
        XCTAssertTrue(DalvikValue.ref(left).equalsValue(.ref(right)), "容器查找仍使用 String.equals")
    }

    func testConstWideAndWideMove16KeepAllBits() throws {
        let (vm, method) = try machine([0x0118, 0xCDEF, 0x89AB, 0x4567, 0x8123,
                                       0x0006, 300, 1, 0x0305, 300, 0x0310], registers: 302)
        XCTAssertEqual(try vm.invoke(method, [], nil)?.longValue, Int64(bitPattern: 0x8123456789ABCDEF))
    }

    func testMove16UsesBothFullRegisterOperands() throws {
        let (vm, method) = try machine([0x0113, 1234, 0x0003, 300, 1, 0x0002, 300, 0x000F], registers: 301)
        XCTAssertEqual(try vm.invoke(method, [], nil)?.intValue, 1234)
        let object = DalvikObject.string("poster")
        let (objectVM, objectMethod) = try machine([0x0009, 300, 301, 0x0008, 300, 0x0011], registers: 302,
                                                   params: ["Ljava/lang/Object;"])
        XCTAssertTrue(try objectVM.invoke(objectMethod, [.ref(object)], nil)?.asObject === object)
    }

    func testLiteralArithmeticAndSignedShiftOperands() throws {
        for (op, literal, expected) in [(0xD8, -3, 7), (0xD9, -3, -13), (0xDA, -3, -30),
                                         (0xDF, -1, -11), (0xE0, 2, 40), (0xE1, 1, 5), (0xE2, -1, 0)] {
            let packed = UInt16(UInt8(bitPattern: Int8(literal))) << 8 | 1
            let (vm, method) = try machine([0x0113, 10, UInt16(op), packed, 0x000F])
            XCTAssertEqual(try vm.invoke(method, [], nil)?.intValue, Int32(expected), "opcode \(op)")
        }
        let (vm, method) = try machine([0x0113, 10, 0x10D1, 3, 0x000F])
        XCTAssertEqual(try vm.invoke(method, [], nil)?.intValue, -7)
    }

    func testArrayLengthDoesNotSkipFollowingReturn() throws {
        let array = DalvikObject(className: "[I"); array.items = [.int(1), .int(2), .int(3)]
        let (vm, method) = try machine([0x1021, 0x000F], registers: 2, params: ["[I"])
        XCTAssertEqual(try vm.invoke(method, [.ref(array)], nil)?.intValue, 3)
    }

    func testSparseSwitchUsesSeparateKeysAndTargets() throws {
        let words: [UInt16] = [0x002C, 6, 0, 0xF012, 0x000F, 0, 0x0200, 2,
                               10, 0, 20, 0, 16, 0, 18, 0, 0x1012, 0x000F, 0x2012, 0x000F]
        for (input, expected) in [(10, 1), (20, 2), (99, -1)] {
            let (vm, method) = try machine(words, registers: 1, params: ["I"])
            XCTAssertEqual(try vm.invoke(method, [.int(Int32(input))], nil)?.intValue, Int32(expected))
        }
    }

    func testInvokeAndFilledArrayKeepFifthRegister() throws {
        let constants: [UInt16] = [0x1012, 0x2112, 0x3212, 0x4312, 0x5412]
        let reference = Reference(owner: "Ljava/lang/Test;", name: "sum", params: Array(repeating: "I", count: 5))
        let (vm, method) = try machine(constants + [0x5471, 0, 0x3210, 0x000A, 0x000F], references: [reference])
        vm.register(reference.owner, reference.name) { _, _, args in .int(args.reduce(0) { $0 + $1.intValue }) }
        XCTAssertEqual(try vm.invoke(method, [], nil)?.intValue, 15)
        let (arrayVM, arrayMethod) = try machine(constants + [0x5424, 0, 0x3210, 0x000C, 0x0121, 0x010F],
                                                 registers: 6, params: ["[I"])
        XCTAssertEqual(try arrayVM.invoke(arrayMethod, [.ref(nil)], nil)?.intValue, 5)
    }

    func testCatchAllUsesByteHandlerOffsetsAndOddCodePadding() throws {
        // try_item(start=0,count=1,handler_off=1), handler list(size=1,catch_all=1)
        let tail: [UInt8] = [0,0,0,0, 1,0, 1,0, 1,0,1]
        let (vm, method) = try machine([0x0127, 0x000D, 0x0011], registers: 2,
                                       params: ["Ljava/lang/Throwable;"], tries: 1, tail: tail)
        let object = DalvikObject(className: "Ljava/lang/Throwable;")
        XCTAssertTrue(try vm.invoke(method, [.ref(object)], nil)?.asObject === object)
    }

    func testStaticInitialValuesAreLoadedBeforeClinit() throws {
        let (vm, _) = try machine([0x000E])
        let info = DalvikClassInfo(name: "Ltest;")
        info.staticValues["Ltest;|token"] = .long(9_000_000_001)
        vm.image.classes[info.name] = info
        XCTAssertEqual(try vm.staticValue(info.name, "token", "J").longValue, 9_000_000_001)
    }

    func testLoopStopsAtStepLimitAndDeadline() throws {
        let (vm, method) = try machine([0x0028], maximumSteps: 2048)
        XCTAssertThrowsError(try vm.invoke(method, [], nil)) { XCTAssertTrue($0.localizedDescription.contains("指令上限")) }
        let (timedVM, timed) = try machine([0x0028], timeout: 0)
        XCTAssertThrowsError(try timedVM.invoke(timed, [], nil)) { XCTAssertTrue($0.localizedDescription.contains("超时")) }
    }

    func testCancellationStopsRunningLoop() async throws {
        let control = DalvikExecutionControl()
        let (vm, method) = try machine([0x0028], control: control, maximumSteps: Int.max)
        let task = Task.detached { try vm.invoke(method, [], nil) }
        try await Task.sleep(nanoseconds: 10_000_000)
        control.cancel()
        do { _ = try await task.value; XCTFail("取消后应停止执行") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testOkHttpCallCarriesRequestAndParsesResponse() throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DalvikHTTPFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (vm, _) = try machine([0x000E], session: session)
        let request = DalvikObject(className: "Lokhttp3/Request;")
        request.payload = DalvikNatives.RequestBox(url: "https://plugin.test/home", headers: ["Referer": "https://plugin.test/"], method: "GET", body: nil)
        let newCall = try XCTUnwrap(vm.nativeBody("Lokhttp3/OkHttpClient;", "newCall"))
        let call = try newCall(vm, nil, [.ref(request)]).asObject
        let execute = try XCTUnwrap(vm.nativeBody("Lokhttp3/Call;", "execute"))
        let response = try execute(vm, call, []).asObject?.payload as? DalvikNatives.HTTPResult
        XCTAssertEqual(response?.code, 200)
        XCTAssertEqual(response?.body, Data("{\"list\":[]}".utf8))
        XCTAssertEqual(vm.httpLog.first?.url, "https://plugin.test/home")
    }

    func testFormBodyPostCarriesContentTypeAndFields() throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DalvikHTTPFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        DalvikHTTPFixture.lastRequest = nil
        let (vm, _) = try machine([0x000E], session: session)

        let builder = DalvikObject(className: "Lokhttp3/FormBody$Builder;")
        let initForm = try XCTUnwrap(vm.nativeBody("Lokhttp3/FormBody$Builder;", "<init>"))
        _ = try initForm(vm, builder, [])
        let add = try XCTUnwrap(vm.nativeBody("Lokhttp3/FormBody$Builder;", "add"))
        _ = try add(vm, builder, [.ref(DalvikObject.string("id")), .ref(DalvikObject.string("abc"))])
        _ = try add(vm, builder, [.ref(DalvikObject.string("type")), .ref(DalvikObject.string("music"))])
        let buildForm = try XCTUnwrap(vm.nativeBody("Lokhttp3/FormBody$Builder;", "build"))
        let body = try XCTUnwrap(buildForm(vm, builder, []).asObject)

        let requestBuilder = DalvikObject(className: "Lokhttp3/Request$Builder;")
        let initRequest = try XCTUnwrap(vm.nativeBody("Lokhttp3/Request$Builder;", "<init>"))
        _ = try initRequest(vm, requestBuilder, [])
        let url = try XCTUnwrap(vm.nativeBody("Lokhttp3/Request$Builder;", "url"))
        _ = try url(vm, requestBuilder, [.ref(DalvikObject.string("https://plugin.test/play.php"))])
        let post = try XCTUnwrap(vm.nativeBody("Lokhttp3/Request$Builder;", "post"))
        _ = try post(vm, requestBuilder, [.ref(body)])
        let buildRequest = try XCTUnwrap(vm.nativeBody("Lokhttp3/Request$Builder;", "build"))
        let request = try XCTUnwrap(buildRequest(vm, requestBuilder, []).asObject)
        let newCall = try XCTUnwrap(vm.nativeBody("Lokhttp3/OkHttpClient;", "newCall"))
        let call = try XCTUnwrap(newCall(vm, nil, [.ref(request)]).asObject)
        let execute = try XCTUnwrap(vm.nativeBody("Lokhttp3/Call;", "execute"))
        _ = try execute(vm, call, [])

        XCTAssertEqual(DalvikHTTPFixture.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(DalvikHTTPFixture.lastRequest?.value(forHTTPHeaderField: "Content-Type"),
                       "application/x-www-form-urlencoded")
        XCTAssertEqual(String(data: DalvikHTTPFixture.lastRequest?.httpBody ?? Data(), encoding: .utf8),
                       "id=abc&type=music")
        XCTAssertEqual(vm.httpTrace.first?.contentType, "application/x-www-form-urlencoded")
        XCTAssertEqual(vm.httpTrace.first?.bodyBytes, 17)
    }

    func testDetailPassesPluginEpisodeValueThroughUnchanged() throws {
        // 插件自己会把 `{playUrl=..., play_id=...}` 反解成 Map；应用不能替它"提取" URL。
        let raw = """
        {"list":[{"vod_id":"play/ch4rws7bw","vod_name":"谷雨","vod_play_from":"自动",\
        "vod_play_url":"1${playUrl=play/ch4rws7bw, play_id=41822, userlink=ABC}#2${playUrl=play/x, play_id=41823, userlink=ABC}"}]}
        """
        let video = try XCTUnwrap(CatVodPayload.detail(raw))
        XCTAssertEqual(video.lines.first?.episodes.first?.value,
                       "{playUrl=play/ch4rws7bw, play_id=41822, userlink=ABC}")
        XCTAssertEqual(video.lines.first?.episodes.count, 2)
    }

    func testCancellationStopsPendingHttpRequest() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DalvikHTTPFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let control = DalvikExecutionControl()
        let (vm, _) = try machine([0x000E], control: control, session: session)
        let request = DalvikNatives.RequestBox(url: "https://plugin.test/slow", headers: [:], method: "GET", body: nil)
        let task = Task.detached { try DalvikNatives.perform(vm, request) }
        try await Task.sleep(nanoseconds: 30_000_000)
        control.cancel()
        do { _ = try await task.value; XCTFail("取消后应停止网络等待") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testRealCollectorExecutesPluginHtmlParser() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/spider", withExtension: "jar"))
        let dex = try GuardContainer.innerDex(from: Data(contentsOf: fixture))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CollectorHTTPFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let result = try DalvikSpider.execute(dex: dex, shortName: "Auete", action: .home, ext: "", httpSession: session)
        let page = try XCTUnwrap(CatVodPayload.page(result.json), result.json)
        XCTAssertTrue(page.videos.contains { $0.title == "解释器执行样片" }, result.json)
        XCTAssertFalse(result.requests.isEmpty, "必须通过插件的 HTTP 垫片读取 HTML")
        XCTAssertGreaterThan(result.steps, 100)
        let detail = try DalvikSpider.execute(dex: dex, shortName: "Auete", action: .detail(id: "Movie/dzp/test"), ext: "", httpSession: session)
        let video = try XCTUnwrap(CatVodPayload.detail(detail.json), detail.json)
        XCTAssertEqual(video.title, "解释器执行样片")
        XCTAssertEqual(video.lines.first?.episodes.first?.title, "第 1 集", detail.json)
    }

    func testObjectHashCodeDispatchesToJavaStringForObfuscatedSwitch() throws {
        let (vm, method) = try machine([0x106E, 0, 0x0001, 0x000A, 0x000F], registers: 2,
            params: ["Ljava/lang/Object;"], references: [.init(owner: "Ljava/lang/Object;", name: "hashCode", params: [])])
        let input = "\u{06E2}\u{06DF}\u{06E7}"
        let expected = input.utf16.reduce(Int32(0)) { ($0 &* 31) &+ Int32($1) }
        XCTAssertEqual(try vm.invoke(method, [.ref(DalvikObject.string(input))], nil)?.intValue, expected)
        XCTAssertEqual(try vm.invoke(method, [.ref(DalvikObject.string(input))], nil)?.intValue, expected)
    }
}

private final class DalvikHTTPFixture: URLProtocol {
    static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "plugin.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        DalvikHTTPFixture.lastRequest = request
        if request.url?.path == "/slow" { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"list\":[]}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class CollectorHTTPFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let html = """
        <!doctype html><html><body><ul class="navbar-nav mr-auto"><li><a href="/Movie/index.html">电影</a></li></ul>
        <ul class="threadlist"><li><a class="pic" href="/Movie/dzp/test/"><img src="https://poster.test/cover.jpg"></a>
        <h2><a href="/Movie/dzp/test/" title="解释器执行样片">解释器执行样片</a></h2><span class="hdtag">HD</span></li></ul></body></html>
        <div class="detail-main-card"><h1 class="detail-title">解释器执行样片</h1></div>
        <div class="play-card" id="player_list"><div class="card-header"><span><b>云播B线</b></span></div>
        <ul class="episode-list"><li><a href="/Movie/dzp/test/play-1-1.html">第 1 集</a></li></ul></div>
        """
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
