import Foundation
import Security

final class CertificateManager {
    static let shared = CertificateManager()

    private let password = "virtual"
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

    private var certCache: [String: (identity: SecIdentity, cert: SecCertificate)] = [:]
    private let cacheQueue = DispatchQueue(label: "com.vloc.cert.cache")

    // MARK: - Public API

    func ensureCA() throws -> (cert: SecCertificate, key: SecKey) {
        if !fileManager.fileExists(atPath: caP12.path) {
            try generateCA()
        }
        return try loadCAFromP12()
    }

    func certificateForHost(_ host: String) throws -> (identity: SecIdentity, cert: SecCertificate) {
        var cached: (identity: SecIdentity, cert: SecCertificate)?
        cacheQueue.sync { cached = certCache[host] }
        if let cached { return cached }

        let serverP12 = supportDir.appendingPathComponent("\(host).p12")

        if !fileManager.fileExists(atPath: serverP12.path) {
            try generateServerCert(for: host)
        }

        let identity = try loadIdentityFromP12(serverP12)
        var cert: SecCertificate?
        SecIdentityCopyCertificate(identity, &cert)
        guard let cert else { throw CertError.failedToExtractCertificate }

        let result = (identity, cert)
        cacheQueue.sync { certCache[host] = result }
        return result
    }

    func caPEMData() throws -> Data {
        return try Data(contentsOf: caCertPEM)
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
            "-passout", "pass:\(password)"
        ])
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

        try runOpenssl(args: [
            "x509", "-req",
            "-in", csr.path,
            "-CA", caCertPEM.path,
            "-CAkey", caKeyPEM.path,
            "-CAcreateserial",
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
            "-passout", "pass:\(password)"
        ])
    }

    // MARK: - Loading via P12 (reliable)

    private func loadCAFromP12() throws -> (cert: SecCertificate, key: SecKey) {
        let identity = try loadIdentityFromP12(caP12)

        var cert: SecCertificate?
        SecIdentityCopyCertificate(identity, &cert)
        guard let cert else { throw CertError.failedToExtractCertificate }

        var key: SecKey?
        SecIdentityCopyPrivateKey(identity, &key)
        guard let key else { throw CertError.failedToExtractKey }

        return (cert, key)
    }

    private func loadIdentityFromP12(_ url: URL) throws -> SecIdentity {
        guard fileManager.fileExists(atPath: url.path) else {
            throw CertError.p12FileNotFound
        }

        let p12Data = try Data(contentsOf: url)
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password,
            "noexp": true
        ]

        var items: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)

        guard status == errSecSuccess,
              let items = items as? [[String: Any]],
              let first = items.first else {
            throw CertError.failedToImportP12(status: Int(status))
        }

        return first[kSecImportItemIdentity as String] as! SecIdentity
    }

    // MARK: - Helpers

    private func createTempDir() throws -> URL {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vloc-certs-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        return tmpDir
    }

    @discardableResult
    private func runOpenssl(args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
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
            throw CertError.opensslFailed(status: process.terminationStatus, message: errMsg)
        }

        return outputData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func resetCertificates() throws {
        cacheQueue.sync { certCache.removeAll() }
        for url in [caCertPEM, caKeyPEM, caP12] {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
        // Also remove server certs
        let contents = try fileManager.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil)
        for url in contents {
            if url.lastPathComponent.hasSuffix(".p12") || url.lastPathComponent.hasSuffix(".pem") || url.lastPathComponent.hasSuffix(".srl") {
                try fileManager.removeItem(at: url)
            }
        }
    }
}

// MARK: - Errors

enum CertError: Error, LocalizedError {
    case failedToExtractCertificate
    case failedToExtractKey
    case failedToImportP12(status: Int)
    case p12FileNotFound
    case opensslFailed(status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .failedToExtractCertificate:       return "Failed to extract certificate from identity"
        case .failedToExtractKey:               return "Failed to extract private key from identity"
        case .failedToImportP12(let s):         return "Failed to import P12 (status: \(s))"
        case .p12FileNotFound:                  return "P12 file not found"
        case .opensslFailed(let s, let m):      return "openssl failed (status: \(s)): \(m)"
        }
    }
}
