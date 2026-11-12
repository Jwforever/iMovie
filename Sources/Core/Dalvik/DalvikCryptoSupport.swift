import Foundation
import CryptoKit
import CommonCrypto

extension DalvikNatives {
    static func cryptoSupport(_ vm: DalvikVM) {
        func bytes(_ value: DalvikValue?) -> Data {
            if let data = value?.asObject?.payload as? Data { return data }
            return Data((value?.asObject?.items ?? []).map { UInt8(truncatingIfNeeded: $0.intValue) })
        }
        func array(_ data: Data) -> DalvikValue {
            let object = DalvikObject(className: "[B"); object.items = data.map { .int(Int32(Int8(bitPattern: $0))) }; return .ref(object)
        }
        func exception(_ message: String) throws -> DalvikValue {
            let object = DalvikObject(className: "Ljava/security/GeneralSecurityException;"); object.payload = message; throw DalvikThrown(object: object)
        }
        vm.register("Landroid/util/Base64;", "decode") { _, _, args in
            var value = args.first?.asObject?.stringPayload ?? String(decoding: bytes(args.first), as: UTF8.self)
            value = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while value.count % 4 != 0 { value.append("=") }
            return array(Data(base64Encoded: value, options: [.ignoreUnknownCharacters]) ?? Data())
        }
        for name in ["encode", "encodeToString"] {
            vm.register("Landroid/util/Base64;", name) { _, _, args in
                let data = bytes(args.first), flags = args.last?.intValue ?? 0
                var value = data.base64EncodedString()
                if flags & 8 != 0 { value = value.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") }
                if flags & 1 != 0 { value = value.replacingOccurrences(of: "=", with: "") }
                return name == "encodeToString" ? .ref(DalvikObject.string(value)) : array(Data(value.utf8))
            }
        }
        vm.register("Ljava/security/MessageDigest;", "getInstance") { _, _, args in
            let object = DalvikObject(className: "Ljava/security/MessageDigest;")
            object.fields["algorithm"] = args.first; object.payload = Data(); return .ref(object)
        }
        vm.register("Ljava/security/MessageDigest;", "update") { _, this, args in
            var data = this?.payload as? Data ?? Data(); data.append(bytes(args.first)); this?.payload = data; return .ref(nil)
        }
        vm.register("Ljava/security/MessageDigest;", "reset") { _, this, _ in this?.payload = Data(); return .ref(nil) }
        vm.register("Ljava/security/MessageDigest;", "digest") { _, this, args in
            var data = this?.payload as? Data ?? Data()
            if let first = args.first { data.append(bytes(first)) }
            let algorithm = text(this?.fields["algorithm"]).uppercased().replacingOccurrences(of: "-", with: "")
            let result: Data
            switch algorithm {
            case "MD5": result = Data(Insecure.MD5.hash(data: data))
            case "SHA1": result = Data(Insecure.SHA1.hash(data: data))
            case "SHA256": result = Data(SHA256.hash(data: data))
            case "SHA384": result = Data(SHA384.hash(data: data))
            case "SHA512": result = Data(SHA512.hash(data: data))
            default: return try exception("尚未支持摘要算法 \(algorithm)")
            }
            this?.payload = Data(); return array(result)
        }
        vm.register("Ljava/security/MessageDigest;", "isEqual") { _, _, args in .int(bytes(args.first) == bytes(args.count > 1 ? args[1] : nil) ? 1 : 0) }
        for owner in ["Ljavax/crypto/spec/SecretKeySpec;", "Ljavax/crypto/spec/IvParameterSpec;"] {
            vm.register(owner, "<init>") { _, this, args in this?.payload = bytes(args.first); return .ref(nil) }
            vm.register(owner, "getEncoded") { _, this, _ in array(this?.payload as? Data ?? Data()) }
        }
        // 采集器普遍用 HmacSHA256 给播放接口签名。之前 Ljavax/ 被当成"无关框架"
        // 静默返回 null，签名位就是空的，站点直接 400。这里按 Java Mac 语义补齐。
        vm.register("Ljavax/crypto/Mac;", "getInstance") { _, _, args in
            let object = DalvikObject(className: "Ljavax/crypto/Mac;")
            object.fields["algorithm"] = args.first
            object.payload = Data()
            return .ref(object)
        }
        vm.register("Ljavax/crypto/Mac;", "init") { _, this, args in
            // init(Key) 或 init(Key, AlgorithmParameterSpec)，密钥都在最后一个 Key 里。
            this?.fields["key"] = args.last
            this?.payload = Data()
            return .ref(nil)
        }
        vm.register("Ljavax/crypto/Mac;", "update") { _, this, args in
            var data = this?.payload as? Data ?? Data()
            data.append(bytes(args.first))
            this?.payload = data
            return .ref(nil)
        }
        vm.register("Ljavax/crypto/Mac;", "reset") { _, this, _ in this?.payload = Data(); return .ref(nil) }
        vm.register("Ljavax/crypto/Mac;", "getMacLength") { _, this, _ in
            .int(Int32(macLength(text(this?.fields["algorithm"]))))
        }
        vm.register("Ljavax/crypto/Mac;", "doFinal") { _, this, args in
            var data = this?.payload as? Data ?? Data()
            if let first = args.first, !first.isNull { data.append(bytes(first)) }
            let key = bytes(this?.fields["key"])
            let algorithm = text(this?.fields["algorithm"]).uppercased()
                .replacingOccurrences(of: "-", with: "")
            guard let spec = macAlgorithm(algorithm) else {
                return try exception("尚未支持 MAC 算法 \(algorithm)")
            }
            let result = hmac(spec.algorithm, key: key, data: data, length: spec.length)
            this?.payload = Data()
            return array(result)
        }
        vm.register("Ljavax/crypto/Cipher;", "getInstance") { _, _, args in
            let object = DalvikObject(className: "Ljavax/crypto/Cipher;"); object.fields["algorithm"] = args.first; return .ref(object)
        }
        vm.register("Ljavax/crypto/Cipher;", "init") { _, this, args in
            this?.fields["mode"] = args.first
            this?.fields["key"] = args.count > 1 ? args[1] : .ref(nil)
            this?.fields["iv"] = args.count > 2 ? args[2] : .ref(nil)
            return .ref(nil)
        }
        vm.register("Ljavax/crypto/Cipher;", "doFinal") { _, this, args in
            let algorithm = text(this?.fields["algorithm"]).uppercased()
            guard algorithm.hasPrefix("AES") else { return try exception("尚未支持加密算法 \(algorithm)") }
            let key = bytes(this?.fields["key"]), iv = bytes(this?.fields["iv"])
            var input = bytes(args.first)
            if args.count >= 3 {
                let offset = max(0, Int(args[1].intValue)), count = max(0, Int(args[2].intValue))
                input = Data(input.dropFirst(offset).prefix(count))
            }
            var options: CCOptions = algorithm.contains("NOPADDING") ? 0 : CCOptions(kCCOptionPKCS7Padding)
            if algorithm.contains("ECB") { options |= CCOptions(kCCOptionECBMode) }
            var output = Data(count: input.count + kCCBlockSizeAES128), written = 0
            let capacity = output.count
            let operation = this?.fields["mode"]?.intValue == 1 ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt)
            let status = output.withUnsafeMutableBytes { destination in
                input.withUnsafeBytes { source in
                    key.withUnsafeBytes { secret in
                        iv.withUnsafeBytes { vector in
                            CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), options, secret.baseAddress, key.count,
                                    iv.isEmpty ? nil : vector.baseAddress, source.baseAddress, input.count,
                                    destination.baseAddress, capacity, &written)
                        }
                    }
                }
            }
            guard status == kCCSuccess else { return try exception("AES 解密失败 (\(status))") }
            output.count = written; return array(output)
        }
    }

    private static func macAlgorithm(_ name: String) -> (algorithm: CCHmacAlgorithm, length: Int)? {
        switch name {
        case "HMACMD5": return (CCHmacAlgorithm(kCCHmacAlgMD5), 16)
        case "HMACSHA1": return (CCHmacAlgorithm(kCCHmacAlgSHA1), 20)
        case "HMACSHA224": return (CCHmacAlgorithm(kCCHmacAlgSHA224), 28)
        case "HMACSHA256": return (CCHmacAlgorithm(kCCHmacAlgSHA256), 32)
        case "HMACSHA384": return (CCHmacAlgorithm(kCCHmacAlgSHA384), 48)
        case "HMACSHA512": return (CCHmacAlgorithm(kCCHmacAlgSHA512), 64)
        default: return nil
        }
    }

    private static func macLength(_ name: String) -> Int {
        macAlgorithm(name.uppercased().replacingOccurrences(of: "-", with: ""))?.length ?? 0
    }

    private static func hmac(_ algorithm: CCHmacAlgorithm, key: Data, data: Data, length: Int) -> Data {
        var output = Data(count: length)
        output.withUnsafeMutableBytes { destination in
            key.withUnsafeBytes { secret in
                data.withUnsafeBytes { message in
                    CCHmac(algorithm, secret.baseAddress, key.count,
                           message.baseAddress, data.count, destination.baseAddress)
                }
            }
        }
        return output
    }
}
