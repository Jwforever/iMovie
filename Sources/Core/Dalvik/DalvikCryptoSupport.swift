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
}
