import Foundation
import Security
import Darwin

// MARK: - Proxy Configuration

struct ProxyConfig {
    var port: UInt16
    var targetLatitude: Double
    var targetLongitude: Double
    var targetAccuracy: Int
    var onLog: ((LogEntry.Level, String) -> Void)?
    var onWlocPatched: ((_ host: String, _ stats: WlocStats) -> Void)?
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
    private let queue = DispatchQueue(label: "com.vloc.proxy", attributes: .concurrent)
    private var activeConnections = Set<Int32>()
    private let connectionsLock = NSLock()
    private let certManager = CertificateManager.shared

    private var config: ProxyConfig

    init(config: ProxyConfig) {
        self.config = config
    }

    var port: UInt16 { config.port }

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

        // Accept connections in background
        queue.async { [weak self] in
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
                if isRunning { config.onLog?(.err, "accept 失败: \(errno)") }
                continue
            }
            trackConnection(clientFd)
            queue.async { [weak self] in
                self?.handleClient(clientFd)
                self?.untrackConnection(clientFd)
            }
        }
    }

    // MARK: - Connection Tracking

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

        do {
            // Set socket timeout
            var tv = timeval(tv_sec: 30, tv_usec: 0)
            setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            // Read the initial request bytes (accept both \r\n and \n line endings)
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
            let msg = error.localizedDescription
            if !msg.isEmpty {
                config.onLog?(.err, "代理处理失败: \(msg)")
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
        log(.info, "WLOC MITM: \(host)")

        // Send 200 Connection Established
        let response = "HTTP/1.1 200 Connection Established\r\n\r\n"
        try writeAll(fd: clientFd, data: Data(response.utf8))

        // Load server certificate for this host
        let (identity, _) = try certManager.certificateForHost(host)

        // Create server-side SSL context
        guard let sslCtx = SSLCreateContext(nil, .serverSide, .streamType) else {
            throw ProxyError.sslContextFailed
        }

        let certArray = [identity] as CFArray
        SSLSetCertificate(sslCtx, certArray)

        // Set custom I/O functions using the fd
        let fdPtr = UnsafeRawPointer(bitPattern: Int(clientFd))
        SSLSetConnection(sslCtx, fdPtr)
        SSLSetIOFuncs(sslCtx, sslReadCallback, sslWriteCallback)

        // TLS handshake with client
        var handshakeStatus = SSLHandshake(sslCtx)
        if handshakeStatus != errSSLWouldBlock && handshakeStatus != errSecSuccess {
            // Try once more for non-blocking
            handshakeStatus = SSLHandshake(sslCtx)
        }
        guard handshakeStatus == errSecSuccess else {
            log(.err, "TLS handshake failed: \(handshakeStatus)")
            return
        }

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

        // Copy relevant headers
        let forwardedHeaders: Set<String> = ["content-type", "content-length", "accept", "accept-language", "accept-encoding", "user-agent"]
        for (key, value) in reqHeaders {
            if forwardedHeaders.contains(key.lowercased()) {
                urlRequest.setValue(value, forHTTPHeaderField: key)
            }
        }

        log(.info, "转发 \(httpMethod) \(path)")

        // Send request via URLSession
        let (responseData, urlResponse) = try awaitURLSession(request: urlRequest)

        // Determine if this is a WLOC response
        let isWlocPath = path.lowercased().contains("/clls/wloc")

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
                log(.info, "✅ WLOC 已修补: \(result.stats.locations) 个位置, WiFi:\(result.stats.wifi) Cell:\(result.stats.cell)")
                config.onWlocPatched?(host, result.stats)
            } catch {
                log(.err, "WLOC 修补失败: \(error.localizedDescription)")
            }
        }

        // Construct and send HTTP response
        try sendHTTPResponse(sslCtx: sslCtx, urlResponse: urlResponse, data: finalData, isPatched: patchedStats != nil)
    }

    // MARK: - Read HTTP Request from TLS

    private func readHTTPRequest(from sslCtx: SSLContext) throws -> (method: String, path: String, headers: [String: String], body: Data)? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        // Read until we have headers
        while true {
            var processed = 0
            let status = SSLRead(sslCtx, &buffer, buffer.count, &processed)
            guard status == errSecSuccess || status == errSSLWouldBlock else {
                throw ProxyError.tlsReadFailed(status: Int(status))
            }
            if processed > 0 {
                data.append(buffer, count: processed)
            }
            if data.range(of: Data("\r\n\r\n".utf8)) != nil { break }
            if status == errSSLWouldBlock && processed == 0 {
                // Try again with a small delay
                usleep(1000)
                continue
            }
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
                let status = SSLRead(sslCtx, &bodyBuffer, min(bodyBuffer.count, contentLength - bodyData.count), &processed)
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

    private func sendHTTPResponse(sslCtx: SSLContext, urlResponse: URLResponse, data: Data, isPatched: Bool) throws {
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            let simple = "HTTP/1.1 200 OK\r\nContent-Length: \(data.count)\r\n\r\n"
            try writeAllSSL(sslCtx: sslCtx, data: Data(simple.utf8) + data)
            return
        }

        var responseHeader = "HTTP/1.1 \(httpResponse.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode))\r\n"
        responseHeader += "Content-Length: \(data.count)\r\n"

        // Copy response headers (skip transfer-encoding and content-encoding)
        for (key, value) in httpResponse.allHeaderFields {
            let keyStr = "\(key)"
            let lower = keyStr.lowercased()
            if lower == "transfer-encoding" || lower == "content-encoding" || lower == "content-length" {
                continue
            }
            responseHeader += "\(keyStr): \(value)\r\n"
        }

        if isPatched {
            responseHeader += "X-WLOC-Patched: 1\r\n"
        }

        responseHeader += "\r\n"

        try writeAllSSL(sslCtx: sslCtx, data: Data(responseHeader.utf8) + data)
    }

    // MARK: - Transparent Tunnel

    private func handleTunnel(clientFd: Int32, host: String, port: UInt16) throws {
        log(.info, "隧道: \(host):\(port)")

        // Connect to target
        let serverFd = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFd >= 0 else { throw ProxyError.socketFailed("socket") }

        defer {
            shutdown(serverFd, SHUT_RDWR)
            close(serverFd)
        }

        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(serverFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(serverFd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var serverAddr = sockaddr_in()
        serverAddr.sin_family = sa_family_t(AF_INET)
        serverAddr.sin_port = CFSwapInt16HostToBig(port)
        serverAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        // Resolve hostname
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let gaiErr = getaddrinfo(host, nil, &hints, &res)
        guard gaiErr == 0, let res else {
            if res != nil { freeaddrinfo(res) }
            throw ProxyError.dnsFailed(host)
        }
        defer { freeaddrinfo(res) }
        let addr = UnsafeRawPointer(res.pointee.ai_addr).assumingMemoryBound(to: sockaddr_in.self).pointee
        serverAddr.sin_addr = addr.sin_addr

        let connectResult = withUnsafePointer(to: &serverAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(serverFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else { throw ProxyError.connectFailed(host: host, port: port) }

        // Send 200 Connection Established
        let response = "HTTP/1.1 200 Connection Established\r\n\r\n"
        try writeAll(fd: clientFd, data: Data(response.utf8))

        // Bidirectional pipe
        pipeSockets(clientFd: clientFd, serverFd: serverFd)
    }

    private func pipeSockets(clientFd: Int32, serverFd: Int32) {
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            self.pipe(from: serverFd, to: clientFd)
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            self.pipe(from: clientFd, to: serverFd)
            group.leave()
        }

        group.wait()
    }

    private func pipe(from: Int32, to: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(from, &buffer, buffer.count)
            guard n > 0 else { break }
            var written = 0
            while written < n {
                let w = buffer.withUnsafeBytes { ptr in
                    write(to, ptr.baseAddress! + written, n - written)
                }
                guard w > 0 else { break }
                written += w
            }
        }
    }

    // MARK: - HTTP Request (CA Download)

    private func handleHTTPRequest(clientFd: Int32, rawData: Data) throws {
        guard let requestStr = String(data: rawData, encoding: .utf8) else { return }

        let lines = requestStr.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return }
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return }

        let method = parts[0]
        let path = parts[1]

        let requestPath = path.hasPrefix("http://") || path.hasPrefix("https://")
            ? (URL(string: path)?.path ?? path)
            : path

        switch requestPath {
        case "/ca.pem", "/download/ca.pem":
            try serveCADownload(clientFd: clientFd)
        case "/":
            serveHomePage(clientFd: clientFd)
        default:
            if method == "GET" || method == "HEAD" {
                serveHomePage(clientFd: clientFd)
            } else {
                let resp = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"
                try writeAll(fd: clientFd, data: Data(resp.utf8))
            }
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
                SSLWrite(sslCtx, ptr.baseAddress! + offset, data.count - offset, &processed)
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

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
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
