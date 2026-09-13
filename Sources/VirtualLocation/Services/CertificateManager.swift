import Foundation
import Security
import CryptoKit

// MARK: - Deprecated-but-necessary C API

/// `SecKeychainCreate` 自 macOS 10.10 起被标记为 deprecated，但至今**没有替代 API**
/// 可以创建一个非登录钥匙串（`SecItem*` 系列只能操作已存在的钥匙串）。
/// 这里用 `@_silgen_name` 直接绑定 C 符号绕过弃用警告 —— 与 `ProxyServer` 里绑定 `SSL*` 的做法一致。
@_silgen_name("SecKeychainCreate")
private func _SecKeychainCreate(
    _ pathName: UnsafePointer<CChar>,
    _ passwordLength: UInt32,
    _ password: UnsafePointer<CChar>?,
    _ promptUser: Bool,
    _ initialAccess: SecAccess?,
    _ keychain: UnsafeMutablePointer<SecKeychain?>
) -> OSStatus

/// 同样被弃用但无可替代：打开 / 解锁一个已有钥匙串。
/// 光删磁盘文件并不能把钥匙串从 securityd 的注册表里摘掉，注册项还在的话
/// `SecKeychainCreate` 会返回 `errSecDuplicateKeychain` (-25296) —— 所以宁可复用，不要重建。
@_silgen_name("SecKeychainOpen")
private func _SecKeychainOpen(
    _ pathName: UnsafePointer<CChar>,
    _ keychain: UnsafeMutablePointer<SecKeychain?>
) -> OSStatus

/// 复用旧钥匙串时要先解锁：系统在休眠 / 锁屏时会把所有钥匙串锁上，
/// 锁着的话 `SecPKCS12Import` 会以 `errSecInteractionNotAllowed` 失败。
@_silgen_name("SecKeychainUnlock")
private func _SecKeychainUnlock(
    _ keychain: SecKeychain?,
    _ passwordLength: UInt32,
    _ password: UnsafePointer<CChar>?,
    _ usePassword: Bool
) -> OSStatus

// MARK: - Certificate Metadata

/// CA 证书的可展示元数据（用于设置面板）
struct CACertificateInfo: Equatable {
    var commonName: String
    var serialNumber: String
    var notBefore: Date?
    var notAfter: Date?
    var sha256Fingerprint: String

    var isExpired: Bool {
        guard let notAfter else { return false }
        return notAfter < Date()
    }

    /// 距过期剩余天数（已过期为负数）
    var daysRemaining: Int? {
        guard let notAfter else { return nil }
        return Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: Date()),
            to: notAfter
        ).day
    }

    var validityText: String {
        guard let notBefore, let notAfter else { return "未知" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return "\(f.string(from: notBefore)) → \(f.string(from: notAfter))"
    }
}

// MARK: - Certificate Manager

final class CertificateManager: @unchecked Sendable {
    static let shared = CertificateManager()

    private let fileManager = FileManager.default

    private var supportDir: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("VirtualLocation")
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var caCertPEM: URL { supportDir.appendingPathComponent("ca-cert.pem") }
    private var caKeyPEM: URL { supportDir.appendingPathComponent("ca-key.pem") }
    private var caP12: URL { supportDir.appendingPathComponent("ca.p12") }

    /// 应用专属钥匙串文件（放在配置目录里，**不使用**用户的登录钥匙串）
    private var appKeychainURL: URL { supportDir.appendingPathComponent("VirtualLocation.keychain-db") }
    private var appKeychain: SecKeychain?
    private let appKeychainLock = NSLock()

    private let p12Password = "vloc"
    private let appKeychainPassword = "VirtualLocation-local"
    private var identityCache: [String: SecIdentity] = [:]
    private let cacheQueue = DispatchQueue(label: "com.vloc.cert.cache")

    /// 供 UI 展示的 P12 导出密码
    var exportPassword: String { p12Password }

    /// CA 文件所在目录，供「在访达中显示」使用
    var storageDirectory: URL { supportDir }

    // MARK: - Public API

    func ensureCA() throws -> (cert: SecCertificate, key: SecKey) {
        if !fileManager.fileExists(atPath: caCertPEM.path) {
            try generateCA()
        }
        let identity = try importP12(caP12)
        var cert: SecCertificate?
        var key: SecKey?
        SecIdentityCopyCertificate(identity, &cert)
        SecIdentityCopyPrivateKey(identity, &key)
        guard let cert, let key else {
            throw CertError.failedToExtractIdentity
        }
        return (cert, key)
    }

    /// Returns a SecIdentity for the given host (cached in memory).
    /// Imports from the per-host P12 file into the keychain with ACL
    /// that grants the current app access without prompting.
    func identityForHost(_ host: String) throws -> SecIdentity {
        var cached: SecIdentity?
        cacheQueue.sync { cached = identityCache[host] }
        if let cached { return cached }

        let serverP12 = supportDir.appendingPathComponent("\(host).p12")

        if !fileManager.fileExists(atPath: serverP12.path) {
            try generateServerCert(for: host)
        }

        let identity = try importP12(serverP12)
        cacheQueue.sync { identityCache[host] = identity }
        return identity
    }

    /// The raw CA certificate PEM data (for download by clients/iPhones).
    func caPEMData() throws -> Data {
        if !fileManager.fileExists(atPath: caCertPEM.path) {
            try generateCA()
        }
        return try Data(contentsOf: caCertPEM)
    }

    // MARK: - Certificate Inspection

    /// 当前 CA 的 `SecCertificate`（必要时自动生成）
    func currentCACertificate() throws -> SecCertificate {
        if !fileManager.fileExists(atPath: caCertPEM.path) {
            try generateCA()
        }
        let pem = try Data(contentsOf: caCertPEM)
        guard let der = Self.derData(fromPEM: pem),
              let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw CertError.invalidCertificateData
        }
        return cert
    }

    /// 解析任意证书的元数据
    func info(for cert: SecCertificate) -> CACertificateInfo {
        let summary = SecCertificateCopySubjectSummary(cert) as String? ?? ""

        var serial = ""
        if let serialData = SecCertificateCopySerialNumberData(cert, nil) as Data? {
            var bytes = [UInt8](serialData)
            // DER INTEGER 在最高位为 1 时会补一个前导 0x00 保持正数。
            // openssl / 钥匙串访问显示序列号时都会去掉它，这里跟着去掉，
            // 否则界面上会多出两位（00CE827D… vs CE827D…），跟别的工具对不上。
            if bytes.count > 1 && bytes[0] == 0x00 {
                bytes.removeFirst()
            }
            serial = bytes.map { String(format: "%02X", $0) }.joined()
        }

        let der = SecCertificateCopyData(cert) as Data
        let fingerprint = SHA256.hash(data: der)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")

        var notBefore: Date?
        var notAfter: Date?
        let keys = [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray
        if let values = SecCertificateCopyValues(cert, keys, nil) as NSDictionary? {
            notBefore = Self.date(from: values[kSecOIDX509V1ValidityNotBefore])
            notAfter = Self.date(from: values[kSecOIDX509V1ValidityNotAfter])
        }

        return CACertificateInfo(
            commonName: summary,
            serialNumber: serial,
            notBefore: notBefore,
            notAfter: notAfter,
            sha256Fingerprint: fingerprint
        )
    }

    // MARK: - Import / Export

    /// 导出 CA 证书包（P12，含私钥，密码为 `exportPassword`）
    func exportCAIdentity(to url: URL) throws {
        if !fileManager.fileExists(atPath: caP12.path) {
            try generateCA()
        }
        let data = try Data(contentsOf: caP12)
        try data.write(to: url, options: .atomic)
    }

    /// 导入 P12 证书包作为新的 CA（同时替换证书与私钥）
    /// - Parameters:
    ///   - url: 来源 .p12 / .pfx 文件
    ///   - password: P12 密码
    func importCAIdentity(from url: URL, password: String) throws {
        let tmpDir = try createTempDir()
        defer { try? fileManager.removeItem(at: tmpDir) }

        let source = tmpDir.appendingPathComponent("import.p12")
        try fileManager.copyItem(at: url, to: source)

        // 用 openssl 拆分出证书与私钥（自动兼容加密/未加密的 P12）
        let certOut = tmpDir.appendingPathComponent("ca-cert.pem")
        let keyOut = tmpDir.appendingPathComponent("ca-key.pem")

        try runOpenssl(args: [
            "pkcs12", "-in", source.path, "-clcerts", "-nokeys",
            "-passin", "pass:\(password)",
            "-out", certOut.path,
        ])
        try runOpenssl(args: [
            "pkcs12", "-in", source.path, "-nocerts", "-nodes",
            "-passin", "pass:\(password)",
            "-out", keyOut.path,
        ])

        // 校验：必须是一张 CA 证书，且证书与私钥匹配
        let text = try runOpenssl(args: ["x509", "-in", certOut.path, "-noout", "-text"])
        guard text.contains("CA:TRUE") else {
            throw CertError.notACertificateAuthority
        }

        let certPub = try runOpenssl(args: [
            "x509", "-in", certOut.path, "-noout", "-pubkey",
        ])
        let keyPub = try runOpenssl(args: [
            "rsa", "-in", keyOut.path, "-pubout",
        ])
        guard certPub.trimmingCharacters(in: .whitespacesAndNewlines)
                == keyPub.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw CertError.certificateKeyMismatch
        }

        // 落盘：覆盖现有 CA，并清空派生的服务器证书
        try clearDerivedCertificates()
        // 换 CA 后旧身份全部作废：丢弃钥匙串引用，下次使用时会重新接管并清空旧 CA 留下的条目
        appKeychain = nil
        for url in [caCertPEM, caKeyPEM, caP12] {
            try? fileManager.removeItem(at: url)
        }

        // 不能直接把 pkcs12 拆出来的文件 copy 过来：`openssl pkcs12 -out` 会在 PEM 前面
        // 写上 `Bag Attributes` / `localKeyID:` / `subject=` / `issuer=` 这些行。
        // ca-cert.pem 既要被 app 自己解析、又要通过 HTTP 发给 iPhone 安装，混着这些行会解析失败。
        // 用 x509 / pkey 重新输出一遍洗掉，结果与 generateCA 产出的文件完全一致。
        try runOpenssl(args: ["x509", "-in", certOut.path, "-out", caCertPEM.path])
        try runOpenssl(args: ["pkey", "-in", keyOut.path, "-out", caKeyPEM.path])
        restrictToOwner(caKeyPEM)

        try runOpenssl(args: [
            "pkcs12", "-export",
            "-in", caCertPEM.path,
            "-inkey", caKeyPEM.path,
            "-out", caP12.path,
            "-passout", "pass:\(p12Password)",
        ])
        restrictToOwner(caP12)
    }

    // MARK: - Regeneration

    /// 删除本地 CA 与所有派生的服务器证书（不动钥匙串）
    func clearLocalCertificates() throws {
        cacheQueue.sync { identityCache.removeAll() }
        // 丢弃缓存的专属钥匙串引用：下次使用时会重建，避免残留旧 CA 的身份
        appKeychain = nil
        try clearDerivedCertificates()
        for url in [caCertPEM, caKeyPEM, caP12] {
            try? fileManager.removeItem(at: url)
        }
        // 清掉旧版本留下的 `openssl -CAcreateserial` 序列号文件。
        // 现在签服务器证书用的是随机序列号（见 generateServerCert），不再产生这种文件。
        if let entries = try? fileManager.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil) {
            for url in entries where url.pathExtension == "srl" {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// 重新生成一套全新的 CA
    func regenerateCA() throws {
        try clearLocalCertificates()
        try generateCA()
    }

    private func clearDerivedCertificates() throws {
        cacheQueue.sync { identityCache.removeAll() }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: supportDir,
            includingPropertiesForKeys: nil
        ) else { return }
        let caPaths = Set([caCertPEM.path, caKeyPEM.path, caP12.path])
        for url in entries where !caPaths.contains(url.path) {
            let name = url.lastPathComponent
            let isDerived = name.hasSuffix(".p12")
                || name.hasSuffix("-cert.pem")
                || name.hasSuffix("-key.pem")
            if isDerived {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    // MARK: - Keychain Import

    /// 应用专属钥匙串 —— **完全不碰用户的登录钥匙串**。
    ///
    /// 为什么必须这样：`SecPKCS12Import` 默认会把私钥写进登录钥匙串，而条目的访问控制（ACL）
    /// 绑定的是**导入它的那份二进制的代码签名**。本应用是 ad-hoc 签名，且每次构建都会重新签名，
    /// 签名一变系统就认为"不是当初那个程序"，于是弹框索要登录钥匙串密码。
    ///
    /// 这里改成每次进程启动**清空**一个应用专属钥匙串里的条目：它们永远由「当前这份二进制」
    /// 重新导入，ACL 必然匹配，所以不会弹框；登录钥匙串也不会再被写入。
    ///
    /// 注意是"清空条目"而不是"删掉钥匙串再重建" —— 同路径重建会踩 `errSecDuplicateKeychain`
    /// (-25296)：只要文件还在、或上一轮的 `SecKeychainRef` 还没释放，`SecKeychainCreate`
    /// 就会失败，代理直接起不来。复用一个已存在的钥匙串则完全安全。
    private func sharedKeychain() throws -> SecKeychain {
        appKeychainLock.lock()
        defer { appKeychainLock.unlock() }

        if let appKeychain { return appKeychain }

        let path = appKeychainURL.path

        // 1) 首选：复用已存在的钥匙串，只清空里面的条目（不删、不重建，无 -25296 风险）
        if fileManager.fileExists(atPath: path), let existing = adoptable(at: path) {
            return existing
        }

        // 2) 文件缺失或损坏：清掉残留（含 WAL 边车文件）后新建
        for suffix in ["", "-shm", "-wal"] {
            try? fileManager.removeItem(atPath: path + suffix)
        }
        var created: SecKeychain?
        var status = createKeychain(at: path, handle: &created)

        // 3) 同路径仍被别处注册（旧句柄未释放）→ 直接打开复用，别跟它较劲
        if status == errSecDuplicateKeychain {
            created = nil
            if let existing = adoptable(at: path) { return existing }
            status = createKeychain(at: path, handle: &created)
        }

        guard status == errSecSuccess, let result = created else {
            throw CertError.keychainCreateFailed(status: Int(status))
        }
        appKeychain = result
        return result
    }

    /// 调一次 `SecKeychainCreate`（不弹任何 UI）
    private func createKeychain(at path: String, handle: inout SecKeychain?) -> OSStatus {
        _SecKeychainCreate(
            path,
            UInt32(appKeychainPassword.utf8.count),
            appKeychainPassword,
            false,
            nil,
            &handle
        )
    }

    /// 试着"接管"一个已存在的钥匙串：能解锁才算数，然后清空条目。
    ///
    /// 为什么用解锁当判据：`SecKeychainOpen` 对**不存在的路径**也返回 `errSecSuccess`
    /// （拿到的句柄一用就报 `errSecNoSuchKeychain` -25294），所以返回码不能用来判断存在性。
    /// 拿得到句柄 + 解锁成功，才说明它是个真能用的钥匙串。
    private func adoptable(at path: String) -> SecKeychain? {
        var keychain: SecKeychain?
        guard _SecKeychainOpen(path, &keychain) == errSecSuccess, let keychain else { return nil }
        guard _SecKeychainUnlock(
            keychain,
            UInt32(appKeychainPassword.utf8.count),
            appKeychainPassword,
            true
        ) == errSecSuccess else { return nil }

        purgeItems(in: keychain)
        appKeychain = keychain
        return keychain
    }

    /// 清空钥匙串里的全部私钥与证书，逼它们由当前这份二进制重新导入（= ACL 重新绑定）
    private func purgeItems(in keychain: SecKeychain) {
        for cls in [kSecClassKey, kSecClassCertificate] {
            let query: [String: Any] = [
                kSecClass as String: cls,
                kSecMatchSearchList as String: [keychain],
                kSecMatchLimit as String: kSecMatchLimitAll,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    /// 把一个 P12（证书 + 私钥）导入**应用专属钥匙串**，返回 SecIdentity。
    private func importP12(_ url: URL) throws -> SecIdentity {
        guard fileManager.fileExists(atPath: url.path) else {
            throw CertError.p12NotFound
        }

        let keychain = try sharedKeychain()
        let p12Data = try Data(contentsOf: url)
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: p12Password,
            kSecImportExportKeychain as String: keychain,
        ]

        var rawItems: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &rawItems)

        guard status == errSecSuccess,
              let items = rawItems as? [[String: Any]],
              let first = items.first,
              let identity = first[kSecImportItemIdentity as String] else {
            throw CertError.p12ImportFailed(status: Int(status))
        }

        return identity as! SecIdentity
    }

    // MARK: - Certificate Generation

    private func generateCA() throws {
        let tmpDir = try createTempDir()
        defer { try? fileManager.removeItem(at: tmpDir) }

        let caConf = tmpDir.appendingPathComponent("ca.conf")
        try """
        [req]
        distinguished_name = dn
        x509_extensions = v3_ca
        prompt = no
        [dn]
        CN = VirtualLocation WLOC CA
        [v3_ca]
        basicConstraints = critical, CA:TRUE
        keyUsage = critical, keyCertSign, cRLSign
        subjectKeyIdentifier = hash
        authorityKeyIdentifier = keyid:always, issuer:always
        """.write(to: caConf, atomically: true, encoding: .utf8)

        try runOpenssl(args: [
            "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", caKeyPEM.path,
            "-out", caCertPEM.path,
            "-days", "3650",
            "-nodes",
            "-config", caConf.path
        ])

        try runOpenssl(args: [
            "pkcs12", "-export",
            "-in", caCertPEM.path,
            "-inkey", caKeyPEM.path,
            "-out", caP12.path,
            "-passout", "pass:\(p12Password)"
        ])

        // 私钥与证书包收紧到 0600（否则 openssl 默认 0644，同机其他用户可读）
        restrictToOwner(caKeyPEM)
        restrictToOwner(caP12)
    }

    private func generateServerCert(for host: String) throws {
        let tmpDir = try createTempDir()
        defer { try? fileManager.removeItem(at: tmpDir) }

        let serverCertPEM = supportDir.appendingPathComponent("\(host)-cert.pem")
        let serverKeyPEM = supportDir.appendingPathComponent("\(host)-key.pem")
        let serverP12 = supportDir.appendingPathComponent("\(host).p12")

        let serverConf = tmpDir.appendingPathComponent("server.conf")
        try """
        [req]
        distinguished_name = dn
        req_extensions = v3_req
        prompt = no
        [dn]
        CN = \(host)
        [v3_req]
        basicConstraints = CA:FALSE
        keyUsage = digitalSignature, keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = DNS:\(host)
        """.write(to: serverConf, atomically: true, encoding: .utf8)

        let csr = tmpDir.appendingPathComponent("server.csr")
        try runOpenssl(args: [
            "req", "-new", "-newkey", "rsa:2048",
            "-keyout", serverKeyPEM.path,
            "-out", csr.path,
            "-nodes",
            "-config", serverConf.path
        ])

        // 序列号用**随机值**，不用 `-CAcreateserial` 的递增计数器。
        //
        // 计数器文件（ca-cert.srl）是每台机器各自维护的：两台 Mac 共用同一套 CA 时，
        // 两边都从 1 开始数，于是会给**同一个签发者**签出重复的序列号。
        // RFC 5280 §4.1.2.2 要求序列号在同一 CA 下唯一，随机值天然不会撞，
        // 也省掉了那个需要跟着 CA 一起清理的 .srl 状态文件。
        let serial = String(format: "%016llX", UInt64.random(in: 1...UInt64.max))

        try runOpenssl(args: [
            "x509", "-req",
            "-in", csr.path,
            "-CA", caCertPEM.path,
            "-CAkey", caKeyPEM.path,
            "-set_serial", "0x\(serial)",
            "-out", serverCertPEM.path,
            "-days", "365",
            "-extfile", serverConf.path,
            "-extensions", "v3_req"
        ])

        try runOpenssl(args: [
            "pkcs12", "-export",
            "-in", serverCertPEM.path,
            "-inkey", serverKeyPEM.path,
            "-out", serverP12.path,
            "-passout", "pass:\(p12Password)"
        ])

        restrictToOwner(serverKeyPEM)
        restrictToOwner(serverP12)
    }

    // MARK: - Helpers

    /// 把含私钥的文件权限收紧为 0600（仅属主可读写）
    private func restrictToOwner(_ url: URL) {
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func createTempDir() throws -> URL {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vloc-certs-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        return tmpDir
    }

    private static func date(from entry: Any?) -> Date? {
        guard let dict = entry as? NSDictionary,
              let number = dict[kSecPropertyKeyValue] as? NSNumber else { return nil }
        return Date(timeIntervalSinceReferenceDate: number.doubleValue)
    }

    /// PEM → DER
    ///
    /// 只取 `-----BEGIN`/`-----END` **之间**的内容。不能简单地"排除以 ----- 开头的行、
    /// 其余全当 base64"：`openssl pkcs12 -out` 会在 PEM 前面写上
    /// `Bag Attributes` / `localKeyID:` / `subject=` / `issuer=` 这类行，
    /// 那样拼出来的 base64 是非法的，`Data(base64Encoded:)` 直接返回 nil
    /// —— 表现就是导入后报"证书文件格式无法解析"。
    static func derData(fromPEM pem: Data) -> Data? {
        guard let text = String(data: pem, encoding: .utf8) else { return nil }
        var collecting = false
        var base64 = ""
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("-----BEGIN") {
                collecting = true
                continue
            }
            if trimmed.hasPrefix("-----END") {
                break
            }
            if collecting {
                base64 += trimmed
            }
        }
        guard !base64.isEmpty else { return nil }
        return Data(base64Encoded: base64)
    }

    @discardableResult
    private func runOpenssl(args: [String]) throws -> String {
        try run(tool: "/usr/bin/openssl", args: args)
    }

    @discardableResult
    private func run(tool: String, args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let outputData = try? outPipe.fileHandleForReading.readToEnd()
        let errorData = try? errPipe.fileHandleForReading.readToEnd()

        if process.terminationStatus != 0 {
            let errMsg = errorData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw CertError.commandFailed(
                tool: (tool as NSString).lastPathComponent,
                status: process.terminationStatus,
                message: errMsg.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return outputData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

// MARK: - Errors

enum CertError: Error, LocalizedError {
    case failedToExtractIdentity
    case p12NotFound
    case p12ImportFailed(status: Int)
    case invalidCertificateData
    case notACertificateAuthority
    case certificateKeyMismatch
    case keychainCreateFailed(status: Int)
    case commandFailed(tool: String, status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .failedToExtractIdentity:
            return "无法从证书身份中提取证书或私钥"
        case .p12NotFound:
            return "找不到 P12 文件"
        case .p12ImportFailed(let s):
            return "P12 导入失败 (status: \(s))，请检查密码是否正确"
        case .invalidCertificateData:
            return "证书文件格式无法解析"
        case .notACertificateAuthority:
            return "该证书不是 CA 证书（缺少 CA:TRUE），无法用于签发服务器证书"
        case .certificateKeyMismatch:
            return "证书与私钥不匹配"
        case .keychainCreateFailed(let s):
            return "创建应用专属钥匙串失败 (status: \(s))"
        case .commandFailed(let tool, let status, let message):
            let detail = message.isEmpty ? "" : "：\(message)"
            return "\(tool) 执行失败 (status: \(status))\(detail)"
        }
    }
}
