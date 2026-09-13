import Foundation
import Security

// MARK: - SecureTransport Bridging (avoid deprecated API warnings)

@_silgen_name("SSLCreateContext")
private func _SSLCreateContext(_ alloc: CFAllocator?, _ side: SSLProtocolSide, _ type: SSLConnectionType) -> SSLContext?

@_silgen_name("SSLSetCertificate")
@discardableResult
private func _SSLSetCertificate(_ context: SSLContext, _ certs: CFArray?) -> OSStatus

@_silgen_name("SSLSetConnection")
@discardableResult
private func _SSLSetConnection(_ context: SSLContext, _ connection: UnsafeRawPointer?) -> OSStatus

@_silgen_name("SSLSetIOFuncs")
@discardableResult
private func _SSLSetIOFuncs(_ context: SSLContext, _ readFunc: SSLReadFunc, _ writeFunc: SSLWriteFunc) -> OSStatus

@_silgen_name("SSLHandshake")
private func _SSLHandshake(_ context: SSLContext) -> OSStatus

@_silgen_name("SSLRead")
private func _SSLRead(_ context: SSLContext, _ data: UnsafeMutableRawPointer, _ dataLength: Int, _ processed: UnsafeMutablePointer<Int>) -> OSStatus

@_silgen_name("SSLWrite")
private func _SSLWrite(_ context: SSLContext, _ data: UnsafeRawPointer, _ dataLength: Int, _ processed: UnsafeMutablePointer<Int>) -> OSStatus

// MARK: - Proxy Configuration

struct ProxyConfig {
    var port: UInt16
    var targetLatitude: Double
    var targetLongitude: Double
    var targetAccuracy: Int
    var onLog: ((LogEntry.Level, String) -> Void)?
    var onWlocPatched: ((_ host: String, _ stats: WlocStats) -> Void)?
    /// 证书信任状态变化。true = 检测到设备疑似未信任 CA（TLS 握手被拒）；false = 已恢复信任
    var onCertTrust: ((_ untrusted: Bool) -> Void)?
    /// 本次启动以来首次与设备完成 TLS 握手。在此之前「设备是否信任 CA」是未知的，
    /// 不能因为「没检测到失败」就当作已信任。
    var onCertVerified: (() -> Void)?
    /// 本次启动以来收到的第一个入站 TCP 连接。
    /// 用来区分「设备还没连上来」和「连上了但握手失败」。
    var onFirstConnection: (() -> Void)?
}

// MARK: - SSL Callbacks

private let sslReadCallback: SSLReadFunc = { (connection, data, dataLength) -> OSStatus in
    let fd = Int32(truncatingIfNeeded: Int(bitPattern: connection))
    let len = read(fd, data, dataLength.pointee)
    if len > 0 {
        dataLength.pointee = len
        return errSecSuccess
    } else if len == 0 {
        return errSSLClosedGraceful
    } else {
        if errno == EAGAIN || errno == EWOULDBLOCK { return errSSLWouldBlock }
        return OSStatus(errSSLClosedAbort)
    }
}

private let sslWriteCallback: SSLWriteFunc = { (connection, data, dataLength) -> OSStatus in
    let fd = Int32(truncatingIfNeeded: Int(bitPattern: connection))
    let len = write(fd, data, dataLength.pointee)
    if len > 0 {
        dataLength.pointee = len
        return errSecSuccess
    } else {
        if errno == EAGAIN || errno == EWOULDBLOCK { return errSSLWouldBlock }
        return OSStatus(errSSLClosedAbort)
    }
}

// MARK: - Proxy Server

final class ProxyServer {
    private var listenFd: Int32 = -1
    private var isRunning = false
    private var activeConnections = Set<Int32>()
    private let connectionsLock = NSLock()
    private let certManager = CertificateManager.shared

    private var config: ProxyConfig

    // 证书信任检测 + 透传日志去重（多连接线程共享，需加锁）
    private let stateLock = NSLock()
    private var certUntrustedReported = false
    private var certVerifiedReported = false
    private var firstConnectionReported = false
    private var lastUntrustedLogAt = Date.distantPast
    private var loggedForwardHosts = Set<String>()

    // 上游请求走独立会话，禁用系统代理（避免 Mac 开了系统代理时 MITM 请求回环打到自己）
    private static let upstreamSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

    init(config: ProxyConfig) {
        self.config = config
    }

    var port: UInt16 { config.port }

    func updateTarget(lat: Double, lng: Double) {
        config.targetLatitude = lat
        config.targetLongitude = lng
    }

    // MARK: - Start / Stop

    func start() throws {
        guard !isRunning else { return }
        isRunning = true
        try startListener()
    }

    func stop() {
        isRunning = false
        if listenFd >= 0 {
            close(listenFd)
            listenFd = -1
        }
        connectionsLock.lock()
        let fds = activeConnections
        connectionsLock.unlock()
        for fd in fds {
            shutdown(fd, SHUT_RDWR)
        }
        config.onLog?(.info, "代理服务器已停止")
    }

    // MARK: - Listener

    private func startListener() throws {
        listenFd = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFd >= 0 else { throw ProxyError.socketFailed("socket") }

        var yes: Int32 = 1
        setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(config.port)
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw ProxyError.socketFailed("bind (port \(config.port) may be in use)") }

        let listenResult = listen(listenFd, 128)
        guard listenResult == 0 else { throw ProxyError.socketFailed("listen") }

        config.onLog?(.info, "代理服务器启动于 0.0.0.0:\(config.port)")

        // Accept connections in background (dedicated thread: accept() blocks forever,
        // and GCD's worker pool is too precious to occupy)
        Thread.detachNewThread { [weak self] in
            self?.acceptLoop()
        }
    }

    private func acceptLoop() {
        while isRunning {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenFd, $0, &addrLen)
                }
            }
            guard clientFd >= 0 else {
                if isRunning {
                    let err = errno
                    // EINTR is normal (signal interrupted), don't log it
                    if err != EINTR {
                        config.onLog?(.err, "accept 失败: errno=\(err)")
                    }
                }
                continue
            }
            trackConnection(clientFd)
            noteInboundConnection()
            Thread.detachNewThread { [weak self] in
                self?.handleClient(clientFd)
                self?.untrackConnection(clientFd)
            }
        }
    }

    // MARK: - Connection Tracking

    /// 首个入站连接只上报一次（后续连接不再打扰 UI）
    private func noteInboundConnection() {
        stateLock.lock()
        let first = !firstConnectionReported
        firstConnectionReported = true
        stateLock.unlock()
        if first { config.onFirstConnection?() }
    }

    private func trackConnection(_ fd: Int32) {
        connectionsLock.lock()
        activeConnections.insert(fd)
        connectionsLock.unlock()
    }

    private func untrackConnection(_ fd: Int32) {
        connectionsLock.lock()
        activeConnections.remove(fd)
        connectionsLock.unlock()
    }

    // MARK: - Client Handler

    private func handleClient(_ clientFd: Int32) {
        defer {
            shutdown(clientFd, SHUT_RDWR)
            close(clientFd)
        }

        var targetInfo = ""
        do {
            // 关闭 Nagle：隧道内小包往返不再被延迟合并（明显减少卡顿感）
            setTCPNoDelay(clientFd)

            var tv = timeval(tv_sec: 30, tv_usec: 0)
            setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            let rawData = try readRequestBytes(from: clientFd)
            guard let requestStr = String(data: rawData, encoding: .utf8) else {
                throw ProxyError.invalidUTF8
            }

            let lines = requestStr.components(separatedBy: "\r\n")
            guard let firstLine = lines.first else { throw ProxyError.invalidRequest }
            let parts = firstLine.components(separatedBy: " ")
            guard parts.count >= 2 else { throw ProxyError.invalidRequest }

            let method = parts[0].uppercased()
            let target = parts[1]
            targetInfo = "\(method) \(target)"

            if method == "CONNECT" {
                let hostPort = target.components(separatedBy: ":")
                guard hostPort.count == 2, let port = UInt16(hostPort[1]) else {
                    throw ProxyError.invalidTarget(target)
                }
                let targetHost = hostPort[0]

                if isWlocHost(targetHost) && (port == 443 || port == 80) {
                    try handleWlocConnect(clientFd: clientFd, host: targetHost)
                } else if port == config.port {
                    let resp = "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n"
                    try writeAll(fd: clientFd, data: Data(resp.utf8))
                } else {
                    try handleTunnel(clientFd: clientFd, host: targetHost, port: port)
                }
            } else {
                try handleHTTPRequest(clientFd: clientFd, rawData: rawData)
            }
        } catch {
            // 客户端没发请求就断开/空闲超时属正常噪音，静默处理
            if targetInfo.isEmpty, case ProxyError.readFailed = error { return }

            let msg = error.localizedDescription
            if !msg.isEmpty {
                let full = targetInfo.isEmpty ? msg : "[\(targetInfo)] \(msg)"
                let isWloc = targetInfo.contains("gs-loc.apple.com") || targetInfo.contains("gs-loc-cn.apple.com")
                // CONNECT 隧道 / 透传 HTTP 的失败属于设备侧常规网络波动，降噪为 info
                let isPassthrough = targetInfo.hasPrefix("CONNECT ") || targetInfo.contains(" http://")
                let isNoise = isPassthrough && !isWloc
                let tag = isNoise ? " [忽略]" : ""
                config.onLog?(isNoise ? .info : .err, "[代理]\(tag) \(full)")
            }
        }
    }

    // MARK: - Read Request Bytes

    private func readRequestBytes(from fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { throw ProxyError.readFailed }
            data.append(buffer, count: n)
            if data.range(of: Data("\r\n\r\n".utf8)) != nil { break }
            if data.count > 65536 { throw ProxyError.requestTooLarge }
        }
        return data
    }

    // MARK: - WLOC MITM Handler

    private func handleWlocConnect(clientFd: Int32, host: String) throws {
        // 未信任证书的重试洪流期间不再逐条刷 "WLOC MITM" 日志
        stateLock.lock()
        let quietMode = certUntrustedReported
        stateLock.unlock()
        if !quietMode {
            log(.info, "WLOC MITM: \(host)")
        }

        // Send 200 Connection Established
        let response = "HTTP/1.1 200 Connection Established\r\n\r\n"
        try writeAll(fd: clientFd, data: Data(response.utf8))

        // Load server identity for this host
        let identity = try certManager.identityForHost(host)

        // Create server-side SSL context
        guard let sslCtx = _SSLCreateContext(nil, SSLProtocolSide(rawValue: 0)!, SSLConnectionType(rawValue: 0)!) else {
            throw ProxyError.sslContextFailed
        }

        let certArray = [identity] as CFArray
        _SSLSetCertificate(sslCtx, certArray)

        // Set custom I/O functions using the fd
        let fdPtr = UnsafeRawPointer(bitPattern: Int(clientFd))
        _SSLSetConnection(sslCtx, fdPtr)
        _SSLSetIOFuncs(sslCtx, sslReadCallback, sslWriteCallback)

        // TLS handshake with client
        var handshakeStatus = _SSLHandshake(sslCtx)
        if handshakeStatus != errSSLWouldBlock && handshakeStatus != errSecSuccess {
            // Try once more for non-blocking
            handshakeStatus = _SSLHandshake(sslCtx)
        }
        guard handshakeStatus == errSecSuccess else {
            // 客户端主动拒绝我们的自签证书 → 几乎必然是设备未信任 CA
            reportHandshakeFailure(host: host, status: handshakeStatus)
            return
        }

        markHandshakeSuccess()
        log(.info, "TLS 握手成功: \(host)")

        // Read HTTP request from client TLS
        guard let (httpMethod, path, reqHeaders, reqBody) = try readHTTPRequest(from: sslCtx) else {
            return
        }

        // Forward to actual Apple server
        let urlStr = "https://\(host)\(path)"
        guard let url = URL(string: urlStr) else {
            throw ProxyError.invalidURL(urlStr)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = httpMethod
        urlRequest.httpBody = reqBody

        // Copy all client headers except those managed by URLSession
        let skipHeaders: Set<String> = ["host", "connection", "keep-alive", "proxy-connection",
                                         "proxy-authorization", "proxy-authenticate", "te", "trailer",
                                         "transfer-encoding", "upgrade"]
        for (key, value) in reqHeaders {
            if !skipHeaders.contains(key.lowercased()) {
                urlRequest.setValue(value, forHTTPHeaderField: key)
            }
        }

        // Send request via URLSession
        let (responseData, urlResponse) = try awaitURLSession(request: urlRequest)

        // Determine if this is a WLOC response (exact path match, strip query params)
        let pathOnly = path.split(separator: "?").first.map(String.init) ?? path
        let isWlocPath = pathOnly == "/clls/wloc"

        var finalData = responseData
        var patchedStats: WlocStats?

        if isWlocPath {
            do {
                let result = try patchWlocResponse(
                    responseData,
                    latitude: config.targetLatitude,
                    longitude: config.targetLongitude,
                    accuracy: config.targetAccuracy
                )
                finalData = result.patched
                patchedStats = result.stats
                log(.info, "✅ WLOC patched \(result.stats.locations) locs (WiFi:\(result.stats.wifi) Cell:\(result.stats.cell)) req:\(reqBody.count)B resp:\(responseData.count)B→\(finalData.count)B → \(config.targetLatitude),\(config.targetLongitude)")
                config.onWlocPatched?(host, result.stats)
            } catch {
                log(.err, "WLOC 修补失败: \(error.localizedDescription)")
            }
        }

        // Construct and send HTTP response
        try sendHTTPResponse(sslCtx: sslCtx, urlResponse: urlResponse, data: finalData, stats: patchedStats, originalDataLen: responseData.count)
    }

    // MARK: - Cert Trust Detection

    /// 设备拒绝了我们的自签证书（TLS 握手失败）。首次检测时上报 UI 并给出修复指引，
    /// 之后静默，仅每 60s 提醒一次，避免未信任期间的重试把日志刷爆。
    private func reportHandshakeFailure(host: String, status: OSStatus) {
        let shouldNotify: Bool
        let shouldLog: Bool
        stateLock.lock()
        if !certUntrustedReported {
            certUntrustedReported = true
            shouldNotify = true
        } else {
            shouldNotify = false
        }
        // 握手失败说明「已信任」结论不再成立
        certVerifiedReported = false
        let now = Date()
        shouldLog = now.timeIntervalSince(lastUntrustedLogAt) > 60
        if shouldLog { lastUntrustedLogAt = now }
        stateLock.unlock()

        if shouldNotify {
            log(.err, "⚠️ 设备疑似未信任 CA 证书 (TLS 握手被拒, status=\(status))，定位修补无法生效")
            log(.info, "💡 修复: iPhone Safari 打开 http://<Mac IP>:\(config.port) → 下载描述文件并安装 → 证书信任设置中启用")
            config.onCertTrust?(true)
        } else if shouldLog {
            log(.info, "TLS 握手仍失败 (status=\(status))，等待设备信任证书…")
        }
    }

    private func markHandshakeSuccess() {
        stateLock.lock()
        let wasReported = certUntrustedReported
        certUntrustedReported = false
        let firstVerification = !certVerifiedReported
        certVerifiedReported = true
        stateLock.unlock()
        if wasReported {
            log(.info, "✅ 证书已被设备信任，修补恢复生效")
            config.onCertTrust?(false)
        }
        if firstVerification {
            config.onCertVerified?()
        }
    }

    // MARK: - Read HTTP Request from TLS

    private func readHTTPRequest(from sslCtx: SSLContext) throws -> (method: String, path: String, headers: [String: String], body: Data)? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        // Read until we have headers
        var idleCycles = 0
        while true {
            var processed = 0
            let status = _SSLRead(sslCtx, &buffer, buffer.count, &processed)
            guard status == errSecSuccess || status == errSSLWouldBlock else {
                throw ProxyError.tlsReadFailed(status: Int(status))
            }
            if processed > 0 {
                data.append(buffer, count: processed)
            }
            if data.range(of: Data("\r\n\r\n".utf8)) != nil { break }
            if status == errSSLWouldBlock && processed == 0 {
                // Try again with a small delay; 30s total (socket RCVTIMEO keeps returning EAGAIN)
                idleCycles += 1
                if idleCycles > 30_000 { throw ProxyError.tlsReadFailed(status: -1) }
                usleep(1000)
                continue
            }
            idleCycles = 0
            if data.count > 65536 { throw ProxyError.requestTooLarge }
        }

        guard let requestStr = String(data: data, encoding: .utf8) else {
            throw ProxyError.invalidUTF8
        }

        let lines = requestStr.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { throw ProxyError.invalidRequest }
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { throw ProxyError.invalidRequest }

        let method = parts[0].uppercased()
        let path = parts[1]

        // Parse headers
        var headers: [String: String] = [:]
        for (i, line) in lines.enumerated() {
            if line.isEmpty { break }
            guard i > 0 else { continue }
            let colonIdx = line.firstIndex(of: ":")
            if let colonIdx = colonIdx {
                let key = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        // Read body if Content-Length is present
        var body = Data()
        if let contentLengthStr = headers["Content-Length"] ?? headers["content-length"],
           let contentLength = Int(contentLengthStr), contentLength > 0 {
            // Headers portion already read includes everything up to \r\n\r\n
            let headerEnd = data.range(of: Data("\r\n\r\n".utf8))!.upperBound
            var bodyData = data[headerEnd...]

            while bodyData.count < contentLength {
                var bodyBuffer = [UInt8](repeating: 0, count: 65536)
                var processed = 0
                let status = _SSLRead(sslCtx, &bodyBuffer, min(bodyBuffer.count, contentLength - bodyData.count), &processed)
                guard status == errSecSuccess else { throw ProxyError.tlsReadFailed(status: Int(status)) }
                if processed > 0 {
                    bodyData.append(bodyBuffer, count: processed)
                }
            }
            body = Data(bodyData)
        }

        return (method, path, headers, body)
    }

    // MARK: - Send HTTP Response over TLS

    private func sendHTTPResponse(sslCtx: SSLContext, urlResponse: URLResponse, data: Data, stats: WlocStats? = nil, originalDataLen: Int = 0) throws {
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            let simple = "HTTP/1.1 200 OK\r\nContent-Length: \(data.count)\r\n\r\n"
            try writeAllSSL(sslCtx: sslCtx, data: Data(simple.utf8) + data)
            return
        }

        var responseHeader = "HTTP/1.1 \(httpResponse.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode))\r\n"
        responseHeader += "Content-Length: \(data.count)\r\n"

        // Copy response headers (skip transfer-encoding, content-encoding and connection mgmt;
        // we close after a single request, so must not advertise keep-alive)
        for (key, value) in httpResponse.allHeaderFields {
            let keyStr = "\(key)"
            let lower = keyStr.lowercased()
            if lower == "transfer-encoding" || lower == "content-encoding" || lower == "content-length"
                || lower == "connection" || lower == "keep-alive" {
                continue
            }
            responseHeader += "\(keyStr): \(value)\r\n"
        }

        responseHeader += "Connection: close\r\n"

        if let stats {
            responseHeader += "X-WLOC-Patched: 1\r\n"
            responseHeader += "X-WLOC-Input-Len: \(originalDataLen)\r\n"
            responseHeader += "X-WLOC-Patched-Locations: \(stats.locations)\r\n"
            responseHeader += "X-WLOC-Patched-Wifi: \(stats.wifi)\r\n"
            responseHeader += "X-WLOC-Patched-Cell: \(stats.cell)\r\n"
            responseHeader += "X-WLOC-Skipped: \(stats.skipped)\r\n"
            responseHeader += "X-WLOC-Gzip: \(stats.gzip ? "1" : "0")\r\n"
            responseHeader += "X-WLOC-Target: \(config.targetLongitude),\(config.targetLatitude)\r\n"
        }

        responseHeader += "\r\n"

        try writeAllSSL(sslCtx: sslCtx, data: Data(responseHeader.utf8) + data)
    }

    // MARK: - Transparent Tunnel

    private func handleTunnel(clientFd: Int32, host: String, port: UInt16) throws {
        let serverFd = try connectUpstream(host: host, port: port)
        defer {
            shutdown(serverFd, SHUT_RDWR)
            close(serverFd)
        }

        // Send 200 Connection Established
        let response = "HTTP/1.1 200 Connection Established\r\n\r\n"
        try writeAll(fd: clientFd, data: Data(response.utf8))

        // 隧道建立后放宽空闲超时：长连接 (推送/SSE/视频) 不再被 30s 空闲切断
        setIdleTimeouts(clientFd, seconds: 300)
        setIdleTimeouts(serverFd, seconds: 300)

        // Bidirectional pipe
        pipeSockets(clientFd: clientFd, serverFd: serverFd)
    }

    /// DNS 解析 + 连接上游，返回已连接的 fd（已开 TCP_NODELAY）。失败时自行关闭 fd。
    private func connectUpstream(host: String, port: UInt16) throws -> Int32 {
        let serverFd = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFd >= 0 else { throw ProxyError.socketFailed("socket") }

        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let gaiErr = getaddrinfo(host, nil, &hints, &res)
        guard gaiErr == 0, let res else {
            if res != nil { freeaddrinfo(res) }
            close(serverFd)
            throw ProxyError.dnsFailed(host)
        }
        defer { freeaddrinfo(res) }

        var serverAddr = sockaddr_in()
        serverAddr.sin_family = sa_family_t(AF_INET)
        serverAddr.sin_port = CFSwapInt16HostToBig(port)
        serverAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        serverAddr.sin_addr = UnsafeRawPointer(res.pointee.ai_addr)
            .assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr

        let connectResult = withUnsafePointer(to: &serverAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(serverFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            close(serverFd)
            throw ProxyError.connectFailed(host: host, port: port)
        }

        setTCPNoDelay(serverFd)
        return serverFd
    }

    private func setTCPNoDelay(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    private func setIdleTimeouts(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func pipeSockets(clientFd: Int32, serverFd: Int32) {
        let group = DispatchGroup()

        group.enter()
        Thread.detachNewThread {
            self.pipe(from: serverFd, to: clientFd)
            group.leave()
        }

        group.enter()
        Thread.detachNewThread {
            self.pipe(from: clientFd, to: serverFd)
            group.leave()
        }

        group.wait()
    }

    private func pipe(from: Int32, to: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(from, &buffer, buffer.count)
            if n == 0 {
                // 对端半关闭：通知另一侧发送方向结束，让 HTTP keep-alive 的收尾及时到位
                shutdown(to, SHUT_WR)
                return
            }
            guard n > 0 else { return } // 超时或错误
            var written = 0
            while written < n {
                let w = buffer.withUnsafeBytes { ptr in
                    write(to, ptr.baseAddress! + written, n - written)
                }
                guard w > 0 else { return }
                written += w
            }
        }
    }

    // MARK: - HTTP Request (CA Download / Plain HTTP Forward)

    private func handleHTTPRequest(clientFd: Int32, rawData: Data) throws {
        guard let requestStr = String(data: rawData, encoding: .utf8) else { return }

        let lines = requestStr.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return }
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 3 else { return }

        let method = parts[0].uppercased()
        let target = parts[1]
        let version = parts[2]

        // 绝对形式（设备经代理发出的普通 HTTP 请求）→ 原样转发给真实服务器，
        // 不相干流量直接放行（captive portal 检测、应用内 http 接口等）
        if target.lowercased().hasPrefix("http://") {
            try forwardPlainHTTP(clientFd: clientFd, rawData: rawData,
                                 method: method, target: target, version: version)
            return
        }

        if target.lowercased().hasPrefix("https://") {
            // https 绝对形式应走 CONNECT，此处无法中继
            let resp = "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n"
            try writeAll(fd: clientFd, data: Data(resp.utf8))
            return
        }

        // 源形式（Safari 直接访问 http://MacIP:端口）→ 本地服务
        switch target {
        case "/ca.pem", "/download/ca.pem":
            try serveCADownload(clientFd: clientFd)
        case "/":
            serveHomePage(clientFd: clientFd)
        default:
            if method == "GET" || method == "HEAD" {
                serveHomePage(clientFd: clientFd)
            } else {
                let resp = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                try writeAll(fd: clientFd, data: Data(resp.utf8))
            }
        }
    }

    /// 把绝对形式的普通 HTTP 请求转发到真实服务器，之后双向裸管道：
    /// 请求体、chunked、keep-alive 后续请求全部原样透传，无需逐段解析。
    private func forwardPlainHTTP(clientFd: Int32, rawData: Data, method: String, target: String, version: String) throws {
        guard let comps = URLComponents(string: target), let host = comps.host, !host.isEmpty else {
            throw ProxyError.invalidTarget(target)
        }
        let port = UInt16(truncatingIfNeeded: comps.port ?? 80)

        let serverFd = try connectUpstream(host: host, port: port)
        defer {
            shutdown(serverFd, SHUT_RDWR)
            close(serverFd)
        }

        // 请求行改写为源形式（Host 头已指明目标主机），其余字节原样透传
        let afterScheme = target.dropFirst("http://".count)
        let path = afterScheme.drop(while: { $0 != "/" })
        let originForm = path.isEmpty ? "/" : String(path)

        var payload = Data("\(method) \(originForm) \(version)\r\n".utf8)
        if let firstLineEnd = rawData.range(of: Data("\r\n".utf8))?.upperBound, firstLineEnd < rawData.count {
            payload.append(Data(rawData[firstLineEnd...]))
        }
        try writeAll(fd: serverFd, data: payload)

        logFirstForward(host: host, port: port)

        setIdleTimeouts(clientFd, seconds: 300)
        setIdleTimeouts(serverFd, seconds: 300)
        pipeSockets(clientFd: clientFd, serverFd: serverFd)
    }

    /// 每个目标主机只记一次日志，避免刷屏
    private func logFirstForward(host: String, port: UInt16) {
        stateLock.lock()
        let isFirst = !loggedForwardHosts.contains(host)
        loggedForwardHosts.insert(host)
        stateLock.unlock()
        if isFirst {
            log(.info, "HTTP 透传: \(host):\(port)")
        }
    }

    private func serveCADownload(clientFd: Int32) throws {
        let caData = try certManager.caPEMData()
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/x-x509-ca-cert\r\nContent-Disposition: attachment; filename=\"VirtualLocation-CA.pem\"\r\nContent-Length: \(caData.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response += caData
        try writeAll(fd: clientFd, data: response)
        log(.info, "已提供 CA 证书下载")
    }

    private func serveHomePage(clientFd: Int32) {
        let body = """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>VirtualLocation Proxy</title>
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body { font-family: -apple-system, system-ui, sans-serif; padding: 2em; max-width: 640px; margin: auto; color: #1c1c1e; }
            h1 { font-size: 1.5em; margin-bottom: .5em; }
            .status { color: #34c759; font-weight: 600; }
            .info { color: #8e8e93; font-size: .9em; margin-bottom: 1.5em; }
            .card { background: #f2f2f7; border-radius: 12px; padding: 1.25em; margin-bottom: 1em; }
            .card h2 { font-size: 1.1em; margin-bottom: .5em; }
            .card p { font-size: .95em; color: #3a3a3c; margin-bottom: .75em; }
            .btn { display: inline-block; background: #007aff; color: #fff; text-decoration: none; padding: .6em 1.2em; border-radius: 8px; font-size: .95em; }
            .btn:hover { background: #0066d6; }
            .steps { font-size: .9em; color: #48484a; line-height: 1.6; }
        </style>
        </head>
        <body>
            <h1>VirtualLocation Proxy</h1>
            <p class="status">✚ 运行中</p>
            <p class="info">监听端口 \(config.port) · 目标 \(config.targetLatitude), \(config.targetLongitude)</p>

            <div class="card">
            <h2>📄 文件下载</h2>
            <p><a href="/ca.pem" class="btn">下载 CA 证书 (ca.pem)</a></p>
            <p style="margin-top: .5em; font-size: .85em; color: #8e8e93;">SHA1: 安装后前往 设置 > 通用 > 关于 > 证书信任设置 中启用</p>
            </div>

            <div class="card">
            <h2>📖 安装说明</h2>
            <ol class="steps">
            <li><strong>请使用 Safari 打开此页面</strong>，Chrome 下载证书可能无法正常安装</li>
            <li>点击上方按钮下载 CA 证书文件</li>
            <li>前往 iOS「设置」>「通用」>「VPN 与设备管理」安装描述文件</li>
            <li>在「设置」>「通用」>「关于」>「证书信任设置」中启用此证书</li>
            <li>确认代理 IP 和端口为本机 \(config.port)</li>
            </ol>
            </div>
        </body>
        </html>
        """
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response += Data(body.utf8)
        try? writeAll(fd: clientFd, data: response)
    }

    // MARK: - Helpers

    private func writeAll(fd: Int32, data: Data) throws {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { ptr in
                write(fd, ptr.baseAddress! + offset, data.count - offset)
            }
            guard n > 0 else { throw ProxyError.writeFailed }
            offset += n
        }
    }

    private func writeAllSSL(sslCtx: SSLContext, data: Data) throws {
        var offset = 0
        while offset < data.count {
            var processed = 0
            let status = data.withUnsafeBytes { ptr in
                _SSLWrite(sslCtx, ptr.baseAddress! + offset, data.count - offset, &processed)
            }
            guard status == errSecSuccess else { throw ProxyError.tlsWriteFailed(status: Int(status)) }
            offset += processed
        }
    }

    private func awaitURLSession(request: URLRequest) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultResponse: URLResponse?
        var resultError: Error?

        let task = Self.upstreamSession.dataTask(with: request) { data, response, error in
            resultData = data
            resultResponse = response
            resultError = error
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let error = resultError { throw error }
        guard let data = resultData, let response = resultResponse else {
            throw ProxyError.emptyResponse
        }
        return (data, response)
    }

    private func log(_ level: LogEntry.Level, _ msg: String) {
        config.onLog?(level, "[代理] \(msg)")
        print("[VirtualLocation] [代理] \(msg)")
    }
}

// MARK: - Errors

enum ProxyError: Error, LocalizedError {
    case socketFailed(String)
    case requestTooLarge
    case invalidUTF8
    case invalidRequest
    case invalidTarget(String)
    case invalidURL(String)
    case dnsFailed(String)
    case connectFailed(host: String, port: UInt16)
    case readFailed
    case writeFailed
    case sslContextFailed
    case tlsReadFailed(status: Int)
    case tlsWriteFailed(status: Int)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .socketFailed(let d):      return "Socket 失败: \(d)"
        case .requestTooLarge:          return "请求头过大"
        case .invalidUTF8:              return "无效的 UTF-8 数据"
        case .invalidRequest:           return "无效的 HTTP 请求"
        case .invalidTarget(let t):     return "无效的目标: \(t)"
        case .invalidURL(let u):        return "无效的 URL: \(u)"
        case .dnsFailed(let h):         return "DNS 解析失败: \(h)"
        case .connectFailed(let h, let p): return "连接失败: \(h):\(p)"
        case .readFailed:               return "读取失败"
        case .writeFailed:              return "写入失败"
        case .sslContextFailed:         return "SSL 上下文创建失败"
        case .tlsReadFailed(let s):     return "TLS 读取失败 (status: \(s))"
        case .tlsWriteFailed(let s):    return "TLS 写入失败 (status: \(s))"
        case .emptyResponse:            return "空响应"
        }
    }
}
