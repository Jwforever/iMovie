import Foundation

extension DalvikNatives {
    // MARK: - JSON

    static func json(_ vm: DalvikVM) {
        vm.register("Lorg/json/JSONObject;", "<init>") { _, this, args in
            var values: [String: DalvikValue] = [:]
            if let raw = string(args.first ?? .ref(nil)),
               let data = raw.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (key, value) in parsed { values[key] = box(value) }
            }
            this?.payload = values
            return .ref(nil)
        }
        vm.register("Lorg/json/JSONObject;", "put") { _, this, args in
            var values = map(this)
            let key = text(args.first)
            values[key] = args.count > 1 ? args[1] : .ref(nil)
            storeMap(this, values)
            return .ref(this)
        }
        vm.register("Lorg/json/JSONObject;", "get") { _, this, args in
            map(this)[text(args.first)] ?? .ref(nil)
        }
        vm.register("Lorg/json/JSONObject;", "getString") { _, this, args in
            .ref(DalvikObject.string(text(map(this)[text(args.first)])))
        }
        vm.register("Lorg/json/JSONObject;", "optString") { _, this, args in
            if let value = map(this)[text(args.first)], !value.isNull { return .ref(DalvikObject.string(text(value))) }
            return .ref(DalvikObject.string(args.count > 1 ? text(args[1]) : ""))
        }
        vm.register("Lorg/json/JSONObject;", "optInt") { _, this, args in
            if let value = map(this)[text(args.first)], !value.isNull { return .int(value.intValue) }
            return args.count > 1 ? .int(args[1].intValue) : .int(0)
        }
        vm.register("Lorg/json/JSONObject;", "optLong") { _, this, args in
            if let value = map(this)[text(args.first)], !value.isNull { return .long(value.longValue) }
            return .long(args.count > 1 ? args[1].longValue : 0)
        }
        vm.register("Lorg/json/JSONObject;", "optBoolean") { _, this, args in
            .int(map(this)[text(args.first)]?.intValue ?? 0)
        }
        vm.register("Lorg/json/JSONObject;", "has") { _, this, args in
            .int(map(this)[text(args.first)] != nil ? 1 : 0)
        }
        vm.register("Lorg/json/JSONObject;", "isNull") { _, this, args in
            .int((map(this)[text(args.first)]?.isNull ?? true) ? 1 : 0)
        }
        vm.register("Lorg/json/JSONObject;", "remove") { _, this, args in
            var values = map(this)
            let old = values.removeValue(forKey: text(args.first)) ?? .ref(nil)
            storeMap(this, values)
            return old
        }
        vm.register("Lorg/json/JSONObject;", "length") { _, this, _ in .int(Int32(map(this).count)) }
        vm.register("Lorg/json/JSONObject;", "keys") { _, this, _ in
            let object = DalvikObject(className: "Ljava/util/Iterator;")
            object.payload = IteratorBox(items: map(this).keys.map { .ref(DalvikObject.string($0)) }, index: 0)
            return .ref(object)
        }
        vm.register("Lorg/json/JSONObject;", "names") { _, this, _ in
            let object = DalvikObject(className: "[Ljava/lang/String;")
            object.items = map(this).keys.map { .ref(DalvikObject.string($0)) }
            return .ref(object)
        }
        vm.register("Lorg/json/JSONObject;", "optJSONObject") { _, this, args in
            let value = map(this)[text(args.first)]
            if let items = value?.asObject?.payload as? [String: DalvikValue] {
                let object = DalvikObject(className: "Lorg/json/JSONObject;")
                object.payload = items
                return .ref(object)
            }
            return .ref(nil)
        }
        vm.register("Lorg/json/JSONObject;", "optJSONArray") { _, this, args in
            let value = map(this)[text(args.first)]
            if let items = value?.asObject?.items {
                let object = DalvikObject(className: "Lorg/json/JSONArray;")
                object.items = items
                return .ref(object)
            }
            return .ref(nil)
        }
        vm.register("Lorg/json/JSONObject;", "toString") { _, this, _ in
            .ref(DalvikObject.string(encode(map(this))))
        }
        for (name, original) in [("getJSONObject", "optJSONObject"), ("getJSONArray", "optJSONArray"), ("getInt", "optInt"), ("getBoolean", "optBoolean")] {
            if let body = vm.nativeBody("Lorg/json/JSONObject;", original) { vm.register("Lorg/json/JSONObject;", name, body) }
        }

        vm.register("Lorg/json/JSONArray;", "<init>") { _, this, args in
            var items: [DalvikValue] = []
            if let raw = string(args.first ?? .ref(nil)),
               let data = raw.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                items = parsed.map { box($0) }
            } else if let source = args.first?.asObject?.items {
                items = source
            }
            this?.items = items
            return .ref(nil)
        }
        vm.register("Lorg/json/JSONArray;", "put") { _, this, args in
            var items = list(this)
            items.append(args.first ?? .ref(nil))
            store(this, items)
            return .ref(this)
        }
        vm.register("Lorg/json/JSONArray;", "length") { _, this, _ in .int(Int32(list(this).count)) }
        vm.register("Lorg/json/JSONArray;", "size") { _, this, _ in .int(Int32(list(this).count)) }
        vm.register("Lorg/json/JSONArray;", "get") { _, this, args in
            let items = list(this)
            let index = Int(args.first?.intValue ?? 0)
            return index >= 0 && index < items.count ? items[index] : .ref(nil)
        }
        vm.register("Lorg/json/JSONArray;", "optJSONObject") { _, this, args in
            let items = list(this)
            let index = Int(args.first?.intValue ?? -1)
            guard index >= 0, index < items.count,
                  let values = items[index].asObject?.payload as? [String: DalvikValue] else { return .ref(nil) }
            let object = DalvikObject(className: "Lorg/json/JSONObject;")
            object.payload = values
            return .ref(object)
        }
        vm.register("Lorg/json/JSONArray;", "optString") { _, this, args in
            let items = list(this)
            let index = Int(args.first?.intValue ?? -1)
            guard index >= 0, index < items.count else {
                return .ref(DalvikObject.string(args.count > 1 ? text(args[1]) : ""))
            }
            return .ref(DalvikObject.string(text(items[index])))
        }
        vm.register("Lorg/json/JSONArray;", "getString") { _, this, args in
            let items = list(this)
            let index = Int(args.first?.intValue ?? -1)
            guard index >= 0, index < items.count else { return .ref(DalvikObject.string("")) }
            return .ref(DalvikObject.string(text(items[index])))
        }
        vm.register("Lorg/json/JSONArray;", "toString") { _, this, _ in
            let values = list(this).map { plain($0) }
            if let data = try? JSONSerialization.data(withJSONObject: values, options: []),
               let text = String(data: data, encoding: .utf8) {
                return .ref(DalvikObject.string(text))
            }
            return .ref(DalvikObject.string("[]"))
        }
    }

    static func box(_ value: Any) -> DalvikValue {
        switch value {
        case let string as String:
            return .ref(DalvikObject.string(string))
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .int(number.boolValue ? 1 : 0)
            }
            if number.doubleValue == number.doubleValue.rounded(), abs(number.doubleValue) < 9e15 {
                if number.int64Value >= Int64(Int32.min), number.int64Value <= Int64(Int32.max) { return .int(number.int32Value) }
                return .long(number.int64Value)
            }
            return .double(number.doubleValue)
        case let dictionary as [String: Any]:
            let object = DalvikObject(className: "Lorg/json/JSONObject;")
            var values: [String: DalvikValue] = [:]
            for (key, item) in dictionary { values[key] = box(item) }
            object.payload = values
            return .ref(object)
        case let array as [Any]:
            let object = DalvikObject(className: "Lorg/json/JSONArray;")
            object.items = array.map { box($0) }
            return .ref(object)
        default:
            return .ref(nil)
        }
    }

    static func plain(_ value: DalvikValue) -> Any {
        switch value {
        case .int(let v): return Int(v)
        case .long(let v): return v
        case .float(let v): return Double(v)
        case .double(let v): return v
        case .ref(let object):
            guard let object else { return NSNull() }
            if let value = object.payload as? DalvikValue { return plain(value) }
            if let string = object.stringPayload { return string }
            if let values = object.payload as? [String: DalvikValue] {
                var output: [String: Any] = [:]
                for (key, item) in values { output[key] = plain(item) }
                return output
            }
            if let items = object.items { return items.map { plain($0) } }
            return object.className
        }
    }

    static func encode(_ values: [String: DalvikValue]) -> String {
        var output: [String: Any] = [:]
        for (key, value) in values { output[key] = plain(value) }
        guard let data = try? JSONSerialization.data(withJSONObject: output, options: []),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    // MARK: - IO

    static func io(_ vm: DalvikVM) {
        vm.register("Ljava/io/ByteArrayOutputStream;", "<init>") { _, this, _ in
            this?.payload = Data()
            return .ref(nil)
        }
        vm.register("Ljava/io/ByteArrayOutputStream;", "write") { _, this, args in
            var data = (this?.payload as? Data) ?? Data()
            if let items = args.first?.asObject?.items {
                data.append(contentsOf: items.map { UInt8(truncatingIfNeeded: $0.intValue) })
            } else {
                data.append(UInt8(truncatingIfNeeded: args.first?.intValue ?? 0))
            }
            this?.payload = data
            return .ref(nil)
        }
        vm.register("Ljava/io/ByteArrayOutputStream;", "toByteArray") { _, this, _ in
            let object = DalvikObject(className: "[B")
            object.items = ((this?.payload as? Data) ?? Data()).map { .int(Int32($0)) }
            return .ref(object)
        }
        vm.register("Ljava/io/ByteArrayOutputStream;", "size") { _, this, _ in
            .int(Int32(((this?.payload as? Data) ?? Data()).count))
        }
        vm.register("Ljava/io/ByteArrayOutputStream;", "toString") { _, this, _ in
            let data = (this?.payload as? Data) ?? Data()
            return .ref(DalvikObject.string(String(data: data, encoding: .utf8) ?? ""))
        }
        vm.register("Ljava/io/ByteArrayOutputStream;", "close") { _, _, _ in .ref(nil) }
        vm.register("Ljava/io/PrintStream;", "println") { _, _, _ in .ref(nil) }
        vm.register("Ljava/io/PrintStream;", "print") { _, _, _ in .ref(nil) }
    }

    // MARK: - 网络

    final class HTTPResult {
        let code: Int
        let body: Data
        let headers: [String: String]
        init(code: Int, body: Data, headers: [String: String]) {
            self.code = code
            self.body = body
            self.headers = headers
        }
    }

    static func network(_ vm: DalvikVM) {
        vm.register("Lokhttp3/OkHttpClient;", "<init>") { _, _, _ in .ref(nil) }
        vm.register("Lokhttp3/OkHttpClient;", "newBuilder") { _, _, _ in .ref(DalvikObject(className: "Lokhttp3/OkHttpClient$Builder;")) }
        vm.register("Lokhttp3/OkHttpClient;", "newCall") { _, _, args in
            let call = DalvikObject(className: "Lokhttp3/Call;")
            let request = args.first?.asObject
            if let box = request?.payload as? RequestBox {
                call.payload = box
            } else if let request {
                // 少数插件不走 Request.Builder，直接从字段里取地址。
                var url = ""
                var method = "GET"
                var headers: [String: String] = [:]
                for (key, value) in request.fields {
                    let name = key.split(separator: "|").last.map(String.init) ?? key
                    switch name {
                    case "url", "Url", "URL": url = text(value)
                    case "method": method = text(value)
                    case "headers", "header": if let map = value.asObject?.payload as? [String: String] { headers = map }
                    default: break
                    }
                }
                call.payload = RequestBox(url: url, headers: headers, method: method,
                                          body: request.fields.values.compactMap { $0.asObject?.payload as? Data }.first)
            }
            return .ref(call)
        }
        for name in ["connectTimeout", "readTimeout", "writeTimeout", "followRedirects",
                     "followSslRedirects", "retryOnConnectionFailure", "sslSocketFactory",
                     "addInterceptor", "cookieJar", "hostnameVerifier", "proxy", "dns", "connectionSpecs", "cache"] {
            vm.register("Lokhttp3/OkHttpClient$Builder;", name) { _, this, _ in .ref(this) }
        }
        vm.register("Lokhttp3/OkHttpClient$Builder;", "<init>") { _, _, _ in .ref(nil) }
        vm.register("Lokhttp3/OkHttpClient$Builder;", "build") { _, _, _ in
            .ref(DalvikObject(className: "Lokhttp3/OkHttpClient;"))
        }
        vm.register("Lokhttp3/Request$Builder;", "<init>") { _, this, _ in
            this?.payload = RequestBox(url: "", headers: [:], method: "GET", body: nil)
            return .ref(nil)
        }
        vm.register("Lokhttp3/Request$Builder;", "url") { _, this, args in
            (this?.payload as? RequestBox)?.url = string(args.first ?? .ref(nil)) ?? ""
            return .ref(this)
        }
        vm.register("Lokhttp3/Request$Builder;", "addHeader") { _, this, args in
            if args.count > 1 {
                (this?.payload as? RequestBox)?.headers[text(args[0])] = text(args[1])
            }
            return .ref(this)
        }
        vm.register("Lokhttp3/Request$Builder;", "header") { _, this, args in
            if args.count > 1 {
                (this?.payload as? RequestBox)?.headers[text(args[0])] = text(args[1])
            }
            return .ref(this)
        }
        vm.register("Lokhttp3/Request$Builder;", "removeHeader") { _, this, _ in .ref(this) }
        vm.register("Lokhttp3/Request$Builder;", "get") { _, this, _ in
            (this?.payload as? RequestBox)?.method = "GET"
            return .ref(this)
        }
        vm.register("Lokhttp3/Request$Builder;", "post") { _, this, args in
            let box = this?.payload as? RequestBox
            box?.method = "POST"
            if let body = args.first?.asObject {
                if let data = body.payload as? Data { box?.body = data }
                box?.contentType = contentType(of: body)
            }
            return .ref(this)
        }
        vm.register("Lokhttp3/Request$Builder;", "method") { _, this, args in
            let box = this?.payload as? RequestBox
            box?.method = text(args.first)
            if args.count > 1, let body = args[1].asObject {
                if let data = body.payload as? Data { box?.body = data }
                box?.contentType = contentType(of: body)
            }
            return .ref(this)
        }
        vm.register("Lokhttp3/Request$Builder;", "build") { _, this, _ in
            let request = DalvikObject(className: "Lokhttp3/Request;")
            request.payload = this?.payload
            return .ref(request)
        }
        vm.register("Lokhttp3/Call;", "execute") { vm, this, _ in
            let request = this?.payload as? RequestBox
            let result = try perform(vm, request)
            let response = DalvikObject(className: "Lokhttp3/Response;")
            response.payload = result
            return .ref(response)
        }
        vm.register("Lokhttp3/Call;", "enqueue") { _, _, _ in .ref(nil) }
        vm.register("Lokhttp3/Call;", "cancel") { _, _, _ in .ref(nil) }
        vm.register("Lokhttp3/Response;", "code") { _, this, _ in
            .int(Int32((this?.payload as? HTTPResult)?.code ?? 0))
        }
        vm.register("Lokhttp3/Response;", "isSuccessful") { _, this, _ in
            let code = (this?.payload as? HTTPResult)?.code ?? 0
            return .int(code >= 200 && code < 400 ? 1 : 0)
        }
        vm.register("Lokhttp3/Response;", "message") { _, _, _ in .ref(DalvikObject.string("")) }
        vm.register("Lokhttp3/Response;", "close") { _, _, _ in .ref(nil) }
        vm.register("Lokhttp3/Response;", "body") { _, this, _ in
            let body = DalvikObject(className: "Lokhttp3/ResponseBody;")
            body.payload = (this?.payload as? HTTPResult)?.body ?? Data()
            return .ref(body)
        }
        vm.register("Lokhttp3/ResponseBody;", "string") { _, this, _ in
            let data = (this?.payload as? Data) ?? Data()
            return .ref(DalvikObject.string(decode(data)))
        }
        vm.register("Lokhttp3/ResponseBody;", "bytes") { _, this, _ in
            let data = (this?.payload as? Data) ?? Data()
            let object = DalvikObject(className: "[B")
            object.items = data.map { .int(Int32($0)) }
            return .ref(object)
        }
        vm.register("Lokhttp3/ResponseBody;", "contentLength") { _, this, _ in
            .int(Int32(((this?.payload as? Data) ?? Data()).count))
        }
        vm.register("Lokhttp3/ResponseBody;", "close") { _, _, _ in .ref(nil) }
        vm.register("Lokhttp3/RequestBody;", "create") { vm, _, args in
            // 老版 okhttp3 是 create(MediaType, String)，新版是 create(String, MediaType)。
            // 借调用点的形参描述符判断哪个是 MIME、哪个是正文，别靠猜字符串长度。
            let parameters = vm.invocationParameters
            var media: String?
            var content = ""
            var sawMediaType = false
            for (index, arg) in args.enumerated() {
                let descriptor = index < parameters.count ? parameters[index] : ""
                if descriptor.contains("MediaType") {
                    media = text(arg)
                    sawMediaType = true
                } else {
                    content = text(arg)
                }
            }
            if !sawMediaType, args.count > 1 {
                // 没有描述符信息时，把看起来像 MIME 的短串当媒体类型。
                let candidates = args.map { text($0) }
                media = candidates.first { $0.contains("/") && $0.count < 80 }
                content = candidates.first { $0 != media } ?? content
            }
            let body = DalvikObject(className: "Lokhttp3/RequestBody;")
            body.payload = Data(content.utf8)
            if let media, !media.isEmpty { body.fields["contentType"] = .ref(DalvikObject.string(media)) }
            return .ref(body)
        }
        vm.register("Lokhttp3/FormBody$Builder;", "<init>") { _, this, _ in
            this?.payload = [(String, String)]()
            return .ref(nil)
        }
        vm.register("Lokhttp3/FormBody$Builder;", "add") { _, this, args in
            var pairs = (this?.payload as? [(String, String)]) ?? []
            pairs.append((text(args.first), args.count > 1 ? text(args[1]) : ""))
            this?.payload = pairs
            return .ref(this)
        }
        vm.register("Lokhttp3/FormBody$Builder;", "build") { _, this, _ in
            let pairs = (this?.payload as? [(String, String)]) ?? []
            let body = pairs.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
            let object = DalvikObject(className: "Lokhttp3/RequestBody;")
            object.payload = Data(body.utf8)
            // okhttp3 的 FormBody 会自动带这个头；PHP 的 $_POST 依赖它，
            // 少了就会当成空表单，插件拿不到任何字段。
            object.fields["contentType"] = .ref(DalvikObject.string("application/x-www-form-urlencoded"))
            return .ref(object)
        }
        vm.register("Lokhttp3/MediaType;", "parse") { _, _, args in
            .ref(DalvikObject.string(text(args.first)))
        }
        vm.register("Ljava/net/URLEncoder;", "encode") { _, _, args in
            .ref(DalvikObject.string(escape(text(args.first))))
        }
        vm.register("Ljava/net/URLDecoder;", "decode") { _, _, args in
            .ref(DalvikObject.string(text(args.first).removingPercentEncoding ?? text(args.first)))
        }
    }

    /// RequestBody 把 MIME 记在 fields 里，payload 留给真正的字节。
    static func contentType(of body: DalvikObject?) -> String? {
        guard let value = body?.fields["contentType"] else { return nil }
        let name = string(value) ?? ""
        return name.isEmpty ? nil : name
    }

    static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func decode(_ data: Data) -> String {
        for encoding in [String.Encoding.utf8, .init(rawValue: 0x80000632), .init(rawValue: 0x80000421)] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// 同步 HTTP。插件代码本身就是同步调用，这里用信号量等结果。
    static func perform(_ vm: DalvikVM, _ request: RequestBox?) throws -> HTTPResult {
        try vm.checkExecution()
        let raw = (request?.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var target = URL(string: raw)
        if target?.host == nil, let base = vm.baseURL,
           let resolved = URL(string: raw, relativeTo: base)?.absoluteURL {
            // 插件里常见 `site + "?filter=true"` 只拼了查询串，这里按上一次的主机补全。
            target = resolved
        }
        guard let request, let url = target,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            let address = raw.isEmpty ? "(null)" : raw
            vm.log(address, 0)
            throw DalvikError.runtime("插件生成的请求地址无效：" + String(address.prefix(200)))
        }
        var mutable = URLRequest(url: url, timeoutInterval: 25)
        mutable.httpMethod = request.method
        for (key, value) in request.headers { mutable.setValue(value, forHTTPHeaderField: key) }
        if let body = request.body { mutable.httpBody = body }
        if mutable.value(forHTTPHeaderField: "Content-Type") == nil,
           let type = request.contentType, request.body != nil {
            mutable.setValue(type, forHTTPHeaderField: "Content-Type")
        }
        if mutable.value(forHTTPHeaderField: "User-Agent") == nil {
            mutable.setValue(BrowserProfile.userAgent, forHTTPHeaderField: "User-Agent")
        }

        final class Box {
            private let lock = NSLock()
            private var result: Result<HTTPResult, Error>?
            func store(_ value: Result<HTTPResult, Error>) {
                lock.lock(); defer { lock.unlock() }
                result = value
            }
            func get() throws -> HTTPResult {
                lock.lock(); defer { lock.unlock() }
                guard let result else { throw URLError(.timedOut) }
                return try result.get()
            }
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let task = vm.httpSession.dataTask(with: mutable) { data, response, error in
            if let error { box.store(.failure(error)) }
            else if let http = response as? HTTPURLResponse {
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    headers[String(describing: key)] = String(describing: value)
                }
                box.store(.success(HTTPResult(code: http.statusCode, body: data ?? Data(), headers: headers)))
            } else {
                box.store(.failure(URLError(.badServerResponse)))
            }
            semaphore.signal()
        }
        task.resume()
        defer { task.cancel() }
        while semaphore.wait(timeout: .now() + 0.05) == .timedOut { try vm.checkExecution() }
        try vm.checkExecution()
        let result = try box.get()
        vm.log(request.url, result.code, method: request.method,
               bodyBytes: request.body?.count ?? 0,
               contentType: mutable.value(forHTTPHeaderField: "Content-Type") ?? "",
               bodyPreview: request.body.map { DalvikNatives.decode(Data($0.prefix(600))) } ?? "",
               response: DalvikNatives.decode(Data(result.body.prefix(4096))))
        return result
    }

    final class RequestBox {
        var url: String
        var headers: [String: String]
        var method: String
        var body: Data?
        var contentType: String?
        init(url: String, headers: [String: String], method: String, body: Data?,
             contentType: String? = nil) {
            self.url = url
            self.headers = headers
            self.method = method
            self.body = body
            self.contentType = contentType
        }
    }

    // MARK: - 安卓宿主

    static func android(_ vm: DalvikVM) {
        vm.register("Landroid/content/Context;", "getApplicationContext") { _, this, _ in .ref(this) }
        vm.register("Landroid/content/Context;", "getPackageName") { _, _, _ in
            .ref(DalvikObject.string("com.github.catvod"))
        }
        vm.register("Landroid/content/Context;", "getFilesDir") { _, _, _ in
            .ref(DalvikObject(className: "Ljava/io/File;"))
        }
        vm.register("Landroid/content/Context;", "getCacheDir") { _, _, _ in
            .ref(DalvikObject(className: "Ljava/io/File;"))
        }
        vm.register("Landroid/content/Context;", "getExternalFilesDir") { _, _, _ in
            .ref(DalvikObject(className: "Ljava/io/File;"))
        }
        vm.register("Ljava/io/File;", "getAbsolutePath") { _, _, _ in
            .ref(DalvikObject.string(NSTemporaryDirectory()))
        }
        vm.register("Landroid/text/TextUtils;", "isEmpty") { _, _, args in
            .int(args.first?.isZero != false || text(args.first).isEmpty ? 1 : 0)
        }
        vm.register("Landroid/text/TextUtils;", "join") { _, _, args in
            let values = args.count > 1 ? args[1].asObject?.items ?? (args[1].asObject?.payload as? IteratorBox)?.items ?? [] : []
            return .ref(DalvikObject.string(values.map(text).joined(separator: text(args.first))))
        }
        vm.register("Lcom/github/catvod/crawler/SpiderDebug;", "log") { _, _, _ in .ref(nil) }
        vm.register("Lcom/github/catvod/crawler/Spider;", "<init>") { _, _, _ in .ref(nil) }
        vm.register("Lcom/github/catvod/crawler/Spider;", "client") { _, _, _ in .ref(DalvikObject(className: "Lokhttp3/OkHttpClient;")) }
        vm.register("Lcom/github/catvod/crawler/Spider;", "safeDns") { _, _, _ in .ref(DalvikObject(className: "Lokhttp3/Dns;")) }
        vm.register("Lcom/github/catvod/crawler/Spider;", "init") { vm, this, args in
            if args.count == 2, let this, let method = vm.findMethod(this.className, "init", ["Landroid/content/Context;"]) {
                _ = try vm.invoke(method, [args[0]], this)
            }
            return .ref(nil)
        }
        vm.register("Lcom/github/catvod/crawler/Spider;", "homeVideoContent") { _, _, _ in
            .ref(DalvikObject.string("{}"))
        }
        vm.register("Lcom/github/catvod/crawler/Spider;", "manualVideoCheck") { _, _, _ in .int(0) }
        vm.register("Lcom/github/catvod/crawler/Spider;", "destroy") { _, _, _ in .ref(nil) }
        vm.register("Lcom/github/catvod/crawler/Spider;", "getName") { _, _, _ in
            .ref(DalvikObject.string(""))
        }
    }

    // MARK: - 数学

    /// 采集器用 BigDecimal 做播放地址参数计算（奥特等站的内置库静态初始化就要它）。
    static func math(_ vm: DalvikVM) {
        func fail(_ message: String) throws -> DalvikValue {
            throw DalvikError.java(message)
        }
        func decimal(_ value: DalvikValue?) -> Decimal {
            if let number = value?.asObject?.payload as? Decimal { return number }
            if let raw = string(value ?? .ref(nil)) { return Decimal(string: raw) ?? 0 }
            if let value { return Decimal(Double(value.doubleValue)) }
            return 0
        }
        func box(_ number: Decimal) -> DalvikValue {
            let object = DalvikObject(className: "Ljava/math/BigDecimal;")
            object.payload = number
            return .ref(object)
        }
        vm.register("Ljava/math/BigDecimal;", "<init>") { _, this, args in
            this?.payload = decimal(args.first)
            return .ref(nil)
        }
        vm.register("Ljava/math/BigDecimal;", "add") { _, this, args in
            box(((this?.payload as? Decimal) ?? 0) + decimal(args.first))
        }
        vm.register("Ljava/math/BigDecimal;", "subtract") { _, this, args in
            box(((this?.payload as? Decimal) ?? 0) - decimal(args.first))
        }
        vm.register("Ljava/math/BigDecimal;", "multiply") { _, this, args in
            box(((this?.payload as? Decimal) ?? 0) * decimal(args.first))
        }
        vm.register("Ljava/math/BigDecimal;", "divide") { _, this, args in
            let value = (this?.payload as? Decimal) ?? 0
            let divisor = decimal(args.first)
            // Java 这里会抛 ArithmeticException，但除数只出现在画质分级辅助计算里，
            // 数据差异导致除零时抛异常会杀死整个播放解析，这里退回原值。
            return box(divisor == 0 ? value : value / divisor)
        }
        vm.register("Ljava/math/BigDecimal;", "remainder") { _, this, args in
            let divisor = decimal(args.first)
            guard divisor != 0 else { return box(0) }
            let dividend = NSDecimalNumber(decimal: (this?.payload as? Decimal) ?? 0)
            let behavior = NSDecimalNumberHandler(roundingMode: .down, scale: 0, raiseOnExactness: false,
                                                  raiseOnOverflow: false, raiseOnUnderflow: false,
                                                  raiseOnDivideByZero: false)
            let quotient = dividend.dividing(by: NSDecimalNumber(decimal: divisor), withBehavior: behavior)
            let remainder = dividend.subtracting(quotient.multiplying(by: NSDecimalNumber(decimal: divisor)))
            return box(remainder.decimalValue)
        }
        vm.register("Ljava/math/BigDecimal;", "negate") { _, this, _ in
            box(-((this?.payload as? Decimal) ?? 0))
        }
        vm.register("Ljava/math/BigDecimal;", "abs") { _, this, _ in
            let value = (this?.payload as? Decimal) ?? 0
            return box(value < 0 ? -value : value)
        }
        vm.register("Ljava/math/BigDecimal;", "stripTrailingZeros") { _, this, _ in
            box((this?.payload as? Decimal) ?? 0)
        }
        vm.register("Ljava/math/BigDecimal;", "setScale") { _, this, _ in .ref(this) }
        vm.register("Ljava/math/BigDecimal;", "valueOf") { _, _, args in
            let number: Decimal
            if let raw = string(args.first ?? .ref(nil)) {
                number = Decimal(string: raw) ?? 0
            } else if let value = args.first {
                number = Decimal(Double(value.doubleValue))
            } else {
                number = 0
            }
            return box(number)
        }
        vm.register("Ljava/math/BigDecimal;", "intValue") { _, this, _ in
            .int(NSDecimalNumber(decimal: (this?.payload as? Decimal) ?? 0).int32Value)
        }
        vm.register("Ljava/math/BigDecimal;", "longValue") { _, this, _ in
            .long(NSDecimalNumber(decimal: (this?.payload as? Decimal) ?? 0).int64Value)
        }
        vm.register("Ljava/math/BigDecimal;", "doubleValue") { _, this, _ in
            .double(NSDecimalNumber(decimal: (this?.payload as? Decimal) ?? 0).doubleValue)
        }
        vm.register("Ljava/math/BigDecimal;", "toString") { _, this, _ in
            .ref(DalvikObject.string(NSDecimalNumber(decimal: (this?.payload as? Decimal) ?? 0).stringValue))
        }
        vm.register("Ljava/math/BigDecimal;", "toPlainString") { _, this, _ in
            .ref(DalvikObject.string(NSDecimalNumber(decimal: (this?.payload as? Decimal) ?? 0).stringValue))
        }
        vm.register("Ljava/math/BigDecimal;", "compareTo") { _, this, args in
            let left = (this?.payload as? Decimal) ?? 0
            let right = decimal(args.first)
            return .int(left == right ? 0 : (left < right ? -1 : 1))
        }
    }

    // MARK: - 接口别名

    static func aliases(_ vm: DalvikVM) {
        let mapping: [(String, [String])] = [
            ("Ljava/util/List;", ["Ljava/util/ArrayList;"]),
            ("Ljava/util/Collection;", ["Ljava/util/ArrayList;"]),
            ("Ljava/util/Map;", ["Ljava/util/HashMap;"]),
            ("Ljava/lang/CharSequence;", ["Ljava/lang/String;"]),
            ("Ljava/lang/Iterable;", ["Ljava/util/ArrayList;"])
        ]
        for (iface, impls) in mapping {
            for impl in impls {
                for name in ["<init>", "add", "get", "size", "isEmpty", "clear", "contains",
                             "indexOf", "iterator", "put", "getOrDefault", "containsKey",
                             "remove", "keySet", "values", "entrySet", "addAll", "length", "charAt"] {
                    if let body = vm.nativeBody(impl, name) {
                        vm.registerAlias(iface, name, body)
                    }
                }
            }
        }
    }
}
