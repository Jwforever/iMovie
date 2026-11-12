import Foundation

extension DalvikNatives {
    /// 日期与格式化：插件的播放地址常带时间戳 / 有效期，会用到 SimpleDateFormat。
    static func dateSupport(_ vm: DalvikVM) {
        let millisKey = "JavaDate|millis"

        func millis(_ object: DalvikObject?) -> Int64 {
            (object?.payload as? Int64) ?? Int64(Date().timeIntervalSince1970 * 1000)
        }

        func dateObject(_ value: Int64) -> DalvikValue {
            let object = DalvikObject(className: "Ljava/util/Date;")
            object.payload = value
            return .ref(object)
        }

        vm.register("Ljava/util/Date;", "<init>") { _, this, args in
            this?.payload = args.first.map { Int64($0.longValue) } ?? Int64(Date().timeIntervalSince1970 * 1000)
            return .ref(nil)
        }
        vm.register("Ljava/util/Date;", "getTime") { _, this, _ in
            .long(millis(this))
        }
        vm.register("Ljava/util/Date;", "setTime") { _, this, args in
            this?.payload = Int64(args.first?.longValue ?? 0)
            return .ref(nil)
        }
        vm.register("Ljava/util/Date;", "toString") { _, this, _ in
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE MMM dd HH:mm:ss zzz yyyy"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let date = Date(timeIntervalSince1970: Double(millis(this)) / 1000)
            return .ref(DalvikObject.string(formatter.string(from: date)))
        }

        /// 插件面向国内站点，安卓设备默认东八区；解释器在任意环境跑都必须对齐，
        /// 否则时间戳签名（如易听的 key=yyyyMMddHHmm...）与服务端校验差 8 小时。
        func pluginTimeZone() -> TimeZone {
            TimeZone(identifier: "Asia/Shanghai") ?? TimeZone.current
        }

        func formatter(_ pattern: String) -> DateFormatter {
            let output = DateFormatter()
            output.locale = Locale(identifier: "en_US_POSIX")
            output.timeZone = pluginTimeZone()
            output.dateFormat = pattern.isEmpty ? "yyyy-MM-dd HH:mm:ss" : pattern
            return output
        }

        for className in ["Ljava/text/SimpleDateFormat;", "Ljava/text/DateFormat;"] {
            vm.register(className, "<init>") { _, this, args in
                let pattern = args.first.flatMap { $0.asObject?.stringPayload } ?? "yyyy-MM-dd HH:mm:ss"
                this?.payload = pattern
                return .ref(nil)
            }
            vm.register(className, "applyPattern") { _, this, args in
                this?.payload = args.first.flatMap { $0.asObject?.stringPayload } ?? ""
                return .ref(nil)
            }
            vm.register(className, "toPattern") { _, this, _ in
                .ref(DalvikObject.string(this?.payload as? String ?? ""))
            }
            vm.register(className, "format") { _, this, args in
                let pattern = this?.payload as? String ?? "yyyy-MM-dd HH:mm:ss"
                let value = millis(args.first?.asObject)
                let date = Date(timeIntervalSince1970: Double(value) / 1000)
                return .ref(DalvikObject.string(formatter(pattern).string(from: date)))
            }
            vm.register(className, "parse") { _, this, args in
                let pattern = this?.payload as? String ?? "yyyy-MM-dd HH:mm:ss"
                guard let text = args.first.flatMap({ $0.asObject?.stringPayload }),
                      let date = formatter(pattern).date(from: text) else { return .ref(nil) }
                return dateObject(Int64(date.timeIntervalSince1970 * 1000))
            }
            vm.register(className, "setTimeZone") { _, this, _ in .ref(this) }
            vm.register(className, "setLenient") { _, this, _ in .ref(nil) }
        }

        vm.register("Ljava/util/TimeZone;", "getDefault") { _, _, _ in
            .ref(DalvikObject(className: "Ljava/util/TimeZone;"))
        }
        vm.register("Ljava/util/TimeZone;", "getTimeZone") { _, _, _ in
            .ref(DalvikObject(className: "Ljava/util/TimeZone;"))
        }
        vm.register("Ljava/util/TimeZone;", "getID") { _, _, _ in
            .ref(DalvikObject.string(pluginTimeZone().identifier))
        }
        vm.register("Ljava/util/Locale;", "getDefault") { _, _, _ in
            .ref(DalvikObject(className: "Ljava/util/Locale;"))
        }
        vm.register("Ljava/util/Locale;", "US") { _, _, _ in
            .ref(DalvikObject(className: "Ljava/util/Locale;"))
        }
        vm.register("Ljava/util/Locale;", "CHINA") { _, _, _ in
            .ref(DalvikObject(className: "Ljava/util/Locale;"))
        }

        // Calendar：只补采集器最常问的字段。
        vm.register("Ljava/util/Calendar;", "getInstance") { _, _, _ in
            .ref(DalvikObject(className: "Ljava/util/Calendar;"))
        }
        vm.register("Ljava/util/Calendar;", "getTimeInMillis") { _, _, _ in
            .long(Int64(Date().timeIntervalSince1970 * 1000))
        }
        vm.register("Ljava/util/Calendar;", "get") { _, _, _ in .int(0) }
        vm.register("Ljava/util/Calendar;", "set") { _, this, _ in .ref(this) }
        vm.register("Ljava/util/Calendar;", "add") { _, this, _ in .ref(this) }
        vm.register("Ljava/util/Calendar;", "getTime") { _, _, _ in
            dateObject(Int64(Date().timeIntervalSince1970 * 1000))
        }
        _ = millisKey
    }
}
