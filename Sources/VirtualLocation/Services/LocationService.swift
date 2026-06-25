import Foundation
import MapKit

@MainActor
final class LocationService: ObservableObject {
    @Published var toolState: ToolState = .checking
    @Published var tunnelState: TunnelState = .disconnected
    @Published var status = AppStatus.ready
    @Published var device: DeviceInfo?
    @Published var detectedDevices: [DeviceManager.DetectedDevice] = []
    @Published var selectedDeviceUdid: String?
    @Published var tunnelInstallState: TunnelInstallState = .idle
    @Published var isRefreshingDevices = false
    @Published var isConnecting = false
    @Published var logs: [LogEntry] = []
    @Published var customPresets: [LocationPreset] = []
    @Published var locationState: LocationState = .idle
    @Published var searchHistory: [SearchHistoryItem] = []
    @Published var mapSelection = MapSelectionState()
    @Published var locationMode: LocationMode = .simple {
        didSet {
            saveLocationMode()
            if locationMode == .simple {
                Task { await checkTool() }
            }
        }
    }
    @Published var proxyState: ProxyState = .stopped
    @Published var proxySettings: ProxySettings = {
        if let data = UserDefaults.standard.data(forKey: "proxySettings"),
           let settings = try? JSONDecoder().decode(ProxySettings.self, from: data) {
            return settings
        }
        return .default
    }() {
        didSet { saveProxySettings() }
    }
    @Published var wlocPatchedCount: Int = 0
    @Published var showPasswordInput: Bool = false
    @Published var passwordInputValue: String = ""

    private var dvtExitError: String?

    var allPresets: [LocationPreset] { LocationPreset.builtin + customPresets }

    var isSimulating: Bool {
        if case .active = locationState { true } else { false }
    }

    var activeLat: Double {
        if case .active(let lat, _) = locationState { return lat }
        return mapSelection.selectedCoordinate?.latitude ?? 0
    }

    var activeLng: Double {
        if case .active(_, let lng) = locationState { return lng }
        return mapSelection.selectedCoordinate?.longitude ?? 0
    }

    var canStartTunnel: Bool {
        guard case .present = toolState else { return false }
        guard selectedDeviceUdid != nil || device != nil else { return false }
        return true
    }

    private let deviceManager = DeviceManager()
    let pmd3Path = "\(NSHomeDirectory())/.venv_pmd3/bin/pymobiledevice3"
    private var dvtTask: Process?
    private var proxyServer: ProxyServer?

    enum TunnelState: Equatable {
        case disconnected
        case starting
        case connected
        case failed(String)
    }

    enum TunnelInstallState: Equatable {
        case idle
        case installing
        case uninstalling
    }

    enum LocationState: Equatable {
        case idle
        case setting
        case active(lat: Double, lng: Double)
        case clearing
        case failed(String)
    }

    init() {
        loadCustomPresets()
        loadSearchHistory()
        loadLocationMode()
        deviceManager.onLog = { [weak self] level, msg in
            DispatchQueue.main.async { self?.addLog(level, msg) }
        }
    }

    // MARK: - Location Mode

    private func loadLocationMode() {
        let raw = UserDefaults.standard.string(forKey: "locationMode") ?? LocationMode.simple.rawValue
        locationMode = LocationMode(rawValue: raw) ?? .simple
    }

    private func saveLocationMode() {
        UserDefaults.standard.set(locationMode.rawValue, forKey: "locationMode")
    }

    private func saveProxySettings() {
        guard let data = try? JSONEncoder().encode(proxySettings) else { return }
        UserDefaults.standard.set(data, forKey: "proxySettings")
    }

    // MARK: - Proxy Mode

    private func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let name = String(cString: ptr.pointee.ifa_name)
            if name == "en0" || name == "en1" {
                let family = ptr.pointee.ifa_addr.pointee.sa_family
                if family == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(ptr.pointee.ifa_addr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    address = String(cString: hostname)
                }
            }
        }
        return address
    }

    private func makeProxyConfig(port: UInt16, lat: Double, lng: Double) -> ProxyConfig {
        ProxyConfig(
            port: port,
            targetLatitude: lat,
            targetLongitude: lng,
            targetAccuracy: 25,
            onLog: { [weak self] level, msg in
                Task { @MainActor in self?.addLog(level, msg) }
            },
            onWlocPatched: { [weak self] _, stats in
                Task { @MainActor in
                    self?.wlocPatchedCount += stats.locations
                }
            }
        )
    }

    func startProxy() async {
        guard locationMode == .proxy else { return }
        guard !proxyState.isActive, proxyState != .starting else { return }

        proxyState = .starting
        addLog(.info, "正在初始化 CA 证书…")

        do {
            // Ensure CA exists
            _ = try CertificateManager.shared.ensureCA()

            // Pre-load identity for WLOC hostnames
            try CertificateManager.shared.identityForHost("gs-loc.apple.com")
            try CertificateManager.shared.identityForHost("gs-loc-cn.apple.com")

            let port = proxySettings.port
            let config = makeProxyConfig(port: port, lat: activeLat, lng: activeLng)

            let server = ProxyServer(config: config)
            try server.start()
            self.proxyServer = server
            proxyState = .running(port: port)

            let ip = getLocalIPAddress() ?? "本机IP"
            addLog(.cmd, "✅ 代理已启动 :\(port)")
            addLog(.cmd, "   iPhone 配置步骤:")
            addLog(.cmd, "   ① WiFi 代理 → \(ip):\(port)")
            addLog(.cmd, "   ② Safari → http://\(ip):\(port)")
            addLog(.cmd, "      下载描述文件 → 设置 → 安装")
            addLog(.cmd, "   ③ 设置 → 通用 → 关于本机 → 证书信任设置 → 开启")
            addLog(.cmd, "   ④ App 选位置 → 点「应用」")
            addLog(.cmd, "   ⑤ iPhone 开关定位服务 → 打开目标 App")
            status = AppStatus.info("代理运行于 \(ip):\(port)")

        } catch {
            proxyState = .failed(error.localizedDescription)
            addLog(.err, "代理启动失败: \(error.localizedDescription)")
            status = AppStatus.error("代理启动失败")
        }
    }

    func stopProxy() {
        proxyServer?.stop()
        proxyServer = nil
        proxyState = .stopped
        wlocPatchedCount = 0
        addLog(.info, "代理服务器已停止")
        status = AppStatus.info("代理已停止")
        locationState = .idle
    }

    func applyProxyLocation(lat: Double, lng: Double) async {
        if case .running = proxyState {
            proxyServer?.updateTarget(lat: lat, lng: lng)
            locationState = .active(lat: lat, lng: lng)
            mapSelection.activeCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            mapSelection.centerCoordinate = mapSelection.activeCoordinate
            addLog(.info, "✅ 代理目标已更新: \(lat.coordinateString), \(lng.coordinateString)")
            status = AppStatus.info("代理目标已更新")
        }
    }

    // MARK: - Custom Presets

    func addCustomPreset(name: String, lat: Double, lng: Double) {
        let preset = LocationPreset(name: name, latitude: lat, longitude: lng, landmark: "", region: "自定义")
        customPresets.append(preset)
        saveCustomPresets()
        mapSelection.activeCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        addLog(.info, "已添加自定义地点: \(name)")
    }

    func removeCustomPreset(at index: Int) {
        guard index >= 0, index < customPresets.count else { return }
        let name = customPresets[index].name
        customPresets.remove(at: index)
        saveCustomPresets()
        addLog(.info, "已删除自定义地点: \(name)")
    }

    private func loadCustomPresets() {
        guard let data = UserDefaults.standard.data(forKey: "customPresets"),
              let presets = try? JSONDecoder().decode([LocationPreset].self, from: data) else { return }
        customPresets = presets
    }

    private func saveCustomPresets() {
        guard let data = try? JSONEncoder().encode(customPresets) else { return }
        UserDefaults.standard.set(data, forKey: "customPresets")
    }

    // MARK: - Search History

    func addToSearchHistory(query: String, lat: Double, lng: Double) {
        searchHistory.insert(SearchHistoryItem(query: query, latitude: lat, longitude: lng), at: 0)
        if searchHistory.count > 20 {
            searchHistory = Array(searchHistory.prefix(20))
        }
        saveSearchHistory()
    }

    func clearSearchHistory() {
        searchHistory.removeAll()
        saveSearchHistory()
    }

    private func loadSearchHistory() {
        guard let data = UserDefaults.standard.data(forKey: "searchHistory"),
              let items = try? JSONDecoder().decode([SearchHistoryItem].self, from: data) else { return }
        searchHistory = items
    }

    private func saveSearchHistory() {
        guard let data = try? JSONEncoder().encode(searchHistory) else { return }
        UserDefaults.standard.set(data, forKey: "searchHistory")
    }

    // MARK: - Map Search

    func searchLocation(query: String) async {
        guard !query.isEmpty else { return }
        mapSelection.isSearching = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]

        let search = MKLocalSearch(request: request)
        do {
            let response = try await search.start()
            mapSelection.searchResults = response.mapItems
            if let first = response.mapItems.first, let location = first.placemark.location {
                mapSelection.selectedCoordinate = location.coordinate
                mapSelection.selectedPlaceName = first.name ?? query
                mapSelection.centerCoordinate = location.coordinate
                addToSearchHistory(query: query, lat: location.coordinate.latitude, lng: location.coordinate.longitude)
            }
        } catch {
            addLog(.err, "搜索失败: \(error.localizedDescription)")
        }
        mapSelection.isSearching = false
    }

    // MARK: - Log

    func addLog(_ level: LogEntry.Level, _ msg: String) {
        logs.append(LogEntry(timestamp: Date(), level: level, message: msg))
    }

    func openCrashLog() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let crashLog = appSupport.appendingPathComponent("VirtualLocation/crash.log")
        if FileManager.default.fileExists(atPath: crashLog.path) {
            NSWorkspace.shared.open(crashLog)
            addLog(.info, "已打开崩溃日志")
        } else {
            addLog(.info, "暂无崩溃日志")
        }
    }

    // MARK: - Tool

    func checkTool() async {
        toolState = .checking
        addLog(.info, "检测 pymobiledevice3 …")
        if FileManager.default.isExecutableFile(atPath: pmd3Path) {
            toolState = .present(pmd3Path)
            addLog(.info, "✅ pymobiledevice3 已就绪")
            status = AppStatus.info("工具就绪")
        } else {
            toolState = .missing
            addLog(.err, "未找到 pymobiledevice3")
            status = AppStatus.error("pymobiledevice3 未安装")
        }
    }

    func installDependencies() async {
        tunnelInstallState = .installing
        toolState = .installing
        addLog(.info, "正在安装 pymobiledevice3 …")
        status = AppStatus.info("正在安装 … (约 1-2 分钟)")
        let venvOk = await launchProcess("/usr/bin/python3",
            args: ["-m", "venv", "\(NSHomeDirectory())/.venv_pmd3"],
            log: "venv", streaming: false)
        guard venvOk else {
            tunnelInstallState = .idle
            toolState = .missing
            status = AppStatus.error("venv 创建失败")
            return
        }
        let pip = "\(NSHomeDirectory())/.venv_pmd3/bin/pip"
        let pipOk = await launchProcess(pip, args: ["install", "pymobiledevice3"], log: "pip", streaming: true)
        if pipOk {
            addLog(.info, "✅ pymobiledevice3 安装完成")
            try? await Task.sleep(nanoseconds: 300_000_000)
            await checkTool()
        } else {
            tunnelInstallState = .idle
            toolState = .missing
            status = AppStatus.error("pip install 失败")
        }
        tunnelInstallState = .idle
    }

    func uninstallDependencies() async {
        tunnelInstallState = .uninstalling
        addLog(.info, "正在卸载 pymobiledevice3 …")
        status = AppStatus.info("正在卸载 …")

        let venvPath = "\(NSHomeDirectory())/.venv_pmd3"
        let fm = FileManager.default
        if fm.fileExists(atPath: venvPath) {
            do {
                try fm.removeItem(atPath: venvPath)
                addLog(.info, "✅ pymobiledevice3 已卸载")
                status = AppStatus.info("已卸载")
            } catch {
                addLog(.err, "卸载失败: \(error.localizedDescription)")
                status = AppStatus.error("卸载失败")
            }
        } else {
            addLog(.info, "pymobiledevice3 未安装")
            status = AppStatus.info("未安装")
        }

        toolState = .missing
        tunnelState = .disconnected
        tunnelInstallState = .idle
    }

    private func launchProcess(_ path: String, args: [String], log: String, streaming: Bool) async -> Bool {
        await withCheckedContinuation { cont in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe

            if streaming {
                outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                        Task { @MainActor [weak self] in
                            self?.addLog(.out, "[\(log)] \(str)")
                        }
                    }
                }
                errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                        Task { @MainActor [weak self] in
                            self?.addLog(.out, "[\(log)] \(str)")
                        }
                    }
                }
            }

            task.terminationHandler = { proc in
                if streaming {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                } else {
                    let o = (try? outPipe.fileHandleForReading.readToEnd()).flatMap {
                        String(data: $0, encoding: .utf8)
                    } ?? ""
                    let e = (try? errPipe.fileHandleForReading.readToEnd()).flatMap {
                        String(data: $0, encoding: .utf8)
                    } ?? ""
                    Task { @MainActor in
                        if !o.isEmpty { self.addLog(.out, "[\(log)] \(o)") }
                        if !e.isEmpty { self.addLog(.out, "[\(log)] \(e)") }
                    }
                }
                cont.resume(returning: proc.terminationStatus == 0)
            }
            try? task.run()
        }
    }

    // MARK: - Device

    func refreshDevices() async {
        isRefreshingDevices = true
        status = AppStatus.info("正在扫描设备 …")
        let devices = await deviceManager.detectDevices()
        detectedDevices = devices
        if devices.isEmpty {
            device = nil
            selectedDeviceUdid = nil
            addLog(.err, "未检测到设备")
            status = AppStatus.error("未检测到 iOS 设备")
        } else {
            if let selected = selectedDeviceUdid, devices.contains(where: { $0.udid == selected }) {
                // keep current selection
            } else {
                selectedDeviceUdid = nil
                device = nil
            }
            if device == nil {
                status = AppStatus.info("请选择设备并连接")
            }
        }
        isRefreshingDevices = false
    }

    func selectDevice(udid: String) {
        selectedDeviceUdid = udid
        if let dev = detectedDevices.first(where: { $0.udid == udid }) {
            addLog(.info, "已选择设备: \(dev.name)")
            if let currentDevice = device, currentDevice.id != udid {
                dvtTask?.terminate()
                dvtTask = nil
                device = nil
                locationState = .idle
                addLog(.info, "已断开原设备: \(currentDevice.name)")
            }
        } else {
            device = nil
        }
    }

    func disconnectDevice() {
        dvtTask?.terminate()
        dvtTask = nil
        device = nil
        selectedDeviceUdid = nil
        locationState = .idle
        addLog(.info, "设备已断开连接")
        status = AppStatus.info("已断开")
    }

    func connectToDevice() async {
        guard let udid = selectedDeviceUdid else {
            status = AppStatus.error("请先选择设备")
            return
        }
        guard let dev = detectedDevices.first(where: { $0.udid == udid }) else {
            status = AppStatus.error("设备未找到")
            return
        }
        guard !dev.isOffline else {
            addLog(.err, "设备 \(dev.name) 离线")
            status = AppStatus.error("设备 \(dev.name) 离线")
            return
        }

        isConnecting = true
        status = AppStatus.info("正在连接 \(dev.name) …")

        // Check if the device is visible via USB (usbmux) — required by pymobiledevice3
        let (ok, output) = await launchDVTWithTimeout(
            args: ["usbmux", "list"],
            timeout: 5)
        let visibleViaUsb = ok && output.contains(udid)
        if !visibleViaUsb {
            addLog(.err, "设备 \(dev.name) 未通过 USB 连接，请用 USB 连接 iPhone")
            status = AppStatus.error("请用 USB 连接 iPhone")
            isConnecting = false
            return
        }

        device = DeviceInfo(id: dev.udid, name: dev.name, osVersion: dev.osVersion)
        addLog(.info, "✅ 设备已就绪: \(dev.name)")
        status = AppStatus.info("已连接: \(dev.name)")
        try? await Task.sleep(nanoseconds: 300_000_000)
        isConnecting = false
    }

    // MARK: - Connection (no longer used)

    func startTunneld() async {
        // Legacy - no longer used, kept for UI compatibility
        tunnelState = .connected
        status = AppStatus.info("✅ 设备已就绪")
    }

    func stopTunneld() async {
        // Legacy - no longer used, kept for UI compatibility
        tunnelState = .disconnected
        status = AppStatus.info("已断开")
    }

    func confirmPassword(_ password: String) {
        showPasswordInput = false
        // No longer needed - we use --userspace for direct connection
    }

    func cancelPasswordInput() {
        showPasswordInput = false
        passwordInputValue = ""
        tunnelState = .disconnected
        status = AppStatus.info("已取消")
    }

    // MARK: - Location

    func selectCoordinate(_ coordinate: CLLocationCoordinate2D) {
        mapSelection.selectedCoordinate = coordinate
        mapSelection.selectedPlaceName = ""
        reverseGeocode(coordinate)
    }

    private func reverseGeocode(_ coordinate: CLLocationCoordinate2D) {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            guard let self else { return }
            if let placemark = placemarks?.first {
                let name = placemark.name ?? placemark.locality ?? "未知地点"
                Task { @MainActor in
                    self.mapSelection.selectedPlaceName = name
                }
            }
        }
    }

    func setLocation(lat: Double, lng: Double) async {
        guard case .present = toolState else {
            status = AppStatus.error("请先安装依赖"); return
        }
        guard let dev = device else {
            status = AppStatus.error("请先连接设备"); return
        }

        locationState = .setting

        let latStr = String(format: "%.6f", lat)
        let lngStr = String(format: "%.6f", lng)
        addLog(.cmd, "DVT 设置位置: \(latStr), \(lngStr) [设备: \(dev.id)]")
        status = AppStatus.info("正在设置位置 …")

        dvtTask?.terminate()
        dvtTask = nil
        dvtExitError = nil

        let task = Process()
        task.executableURL = URL(fileURLWithPath: pmd3Path)
        var env = ProcessInfo.processInfo.environment
        env["PYMOBILEDEVICE3_USERSPACE"] = "1"
        env["PYTHONWARNINGS"] = "ignore"
        task.environment = env
        task.arguments = ["developer", "dvt", "simulate-location", "set",
                          "--udid", dev.id, "--", latStr, lngStr]

        let errPipe = Pipe()
        task.standardOutput = FileHandle.nullDevice
        task.standardError = errPipe

        task.terminationHandler = { [weak self] proc in
            let errData = try? errPipe.fileHandleForReading.readToEnd()
            let errStr = errData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.dvtTask === task { self.dvtTask = nil }
                self.dvtExitError = errStr
                if !errStr.isEmpty {
                    self.addLog(.err, "DVT 进程退出: \(errStr)")
                    let hint = Self.friendlyHint(for: errStr)
                    if !hint.isEmpty { self.addLog(.info, "💡 \(hint)") }
                }
            }
        }

        do {
            try task.run()
            dvtTask = task
        } catch {
            addLog(.err, "启动 DVT 失败: \(error.localizedDescription)")
            locationState = .failed(error.localizedDescription)
            status = AppStatus.error("启动失败")
            return
        }

        try? await Task.sleep(nanoseconds: 2_000_000_000)

        if dvtTask?.isRunning == true {
            addLog(.info, "✅ DVT 位置已设置 (\(latStr), \(lngStr))")
            status = AppStatus.info("✅ 位置已设为 \(latStr), \(lngStr)")
            locationState = .active(lat: lat, lng: lng)
            mapSelection.activeCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            mapSelection.centerCoordinate = mapSelection.activeCoordinate
        } else {
            let err = dvtExitError ?? ""
            addLog(.err, "DVT 进程未能保持运行")
            let hint = Self.friendlyHint(for: err)
            if !hint.isEmpty { addLog(.info, "💡 \(hint)") }
            locationState = .failed("DVT 进程意外退出")
            status = AppStatus.error("位置设置失败")
        }
    }

    func setSelectedLocation() async {
        guard let coord = mapSelection.selectedCoordinate else {
            status = AppStatus.error("请先在地图上选择位置")
            return
        }

        if locationMode == .proxy {
            if case .running = proxyState {
                await applyProxyLocation(lat: coord.latitude, lng: coord.longitude)
            } else {
                status = AppStatus.error("代理未启动，请先启动代理")
            }
            return
        }

        await setLocation(lat: coord.latitude, lng: coord.longitude)
    }

    func clearLocation() async {
        if locationMode == .proxy {
            stopProxy()
            mapSelection.activeCoordinate = nil
            status = AppStatus.info("位置已清除")
            return
        }

        dvtTask?.terminate()
        dvtTask = nil

        guard let dev = device else {
            locationState = .idle
            status = AppStatus.error("请先连接设备"); return
        }

        locationState = .clearing
        status = AppStatus.info("正在恢复真实位置…")

        let (success, output) = await self.launchDVTWithTimeout(
            args: ["developer", "dvt", "simulate-location", "clear", "--udid", dev.id],
            timeout: 10)
        if success {
            if !output.isEmpty { addLog(.out, output) }
            addLog(.info, "✅ 位置已清除")
            status = AppStatus.info("✅ 位置已恢复真实 GPS")
        } else {
            addLog(.err, "清除位置失败: \(output)")
            let hint = Self.friendlyHint(for: output)
            if !hint.isEmpty { addLog(.info, "💡 \(hint)") }
            status = AppStatus.error("清除位置失败")
        }
        locationState = .idle
        mapSelection.activeCoordinate = nil
    }

    // MARK: - DVT Launch

    private func launchDVT(args: [String], completion: @escaping (Bool, String) -> Void) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: pmd3Path)
        task.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PYMOBILEDEVICE3_USERSPACE"] = "1"
        env["PYTHONWARNINGS"] = "ignore"
        if let udid = selectedDeviceUdid {
            env["PYMOBILEDEVICE3_UDID"] = udid
        }
        task.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        self.dvtTask = task

        task.terminationHandler = { proc in
            DispatchQueue.main.async {
                if self.dvtTask === task { self.dvtTask = nil }
            }
            let o = (try? outPipe.fileHandleForReading.readToEnd()).flatMap {
                String(data: $0, encoding: .utf8)
            } ?? ""
            let e = (try? errPipe.fileHandleForReading.readToEnd()).flatMap {
                String(data: $0, encoding: .utf8)
            } ?? ""
            let success = proc.terminationStatus == 0
            let output = success ? o : (e.isEmpty ? o : e)
            completion(success, output)
        }

        do {
            try task.run()
        } catch {
            self.dvtTask = nil
            completion(false, error.localizedDescription)
        }
    }

    private func launchDVTWithTimeout(args: [String], timeout: TimeInterval = 8) async -> (Bool, String) {
        await withCheckedContinuation { cont in
            var didFinish = false
            launchDVT(args: args) { success, output in
                if !didFinish {
                    didFinish = true
                    cont.resume(returning: (success, output))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if !didFinish {
                    didFinish = true
                    Task { @MainActor in
                        self.dvtTask?.terminate()
                        self.dvtTask = nil
                    }
                    cont.resume(returning: (false, "命令超时 (\(Int(timeout))s)"))
                }
            }
        }
    }

    // MARK: - GPX Parsing
    
    func loadGPX(from url: URL) async {
        addLog(.info, "正在加载 GPX: \(url.lastPathComponent)")
        guard let parser = XMLParser(contentsOf: url) else {
            addLog(.err, "无法读取 GPX 文件")
            return
        }
        
        let delegate = GPXParserDelegate()
        parser.delegate = delegate
        if parser.parse() {
            if let first = delegate.coordinates.first {
                mapSelection.selectedCoordinate = first
                mapSelection.centerCoordinate = first
                mapSelection.selectedPlaceName = url.lastPathComponent
                addLog(.info, "✅ GPX 加载成功 (\(delegate.coordinates.count)个点)")
            } else {
                addLog(.err, "GPX 中未找到坐标")
            }
        } else {
            addLog(.err, "GPX 解析失败")
        }
    }
    static func friendlyHint(for errorOutput: String) -> String {
        if errorOutput.contains("Device not found") || errorOutput.contains("No device found") || errorOutput.contains("Device is not connected") {
            return "请用 USB 连接 iPhone"
        }
        if errorOutput.contains("ConnectionResetError") || errorOutput.contains("reset by peer") {
            return """
            连接被重置。请检查：
            1️⃣ iPhone 和 Mac 是否在同一 WiFi 网络
            2️⃣ iPhone 的「开发者模式」是否已开启
            3️⃣ 尝试用 USB 连接一次
            """
        }
        if errorOutput.contains("Connection refused") || errorOutput.contains("refused") {
            return "连接被拒绝，请确认设备在线且可访问。"
        }
        if errorOutput.contains("Invalid device") || errorOutput.contains("InvalidDevice") {
            return "无效设备标识符，请重新选择设备。"
        }
        if errorOutput.contains("timeout") || errorOutput.contains("timed out") {
            return "连接超时，请检查网络或尝试 USB 连接。"
        }
        if errorOutput.contains("usbmux") || errorOutput.contains("USBMux") {
            return """
            USB 通信异常。请尝试：
            1️⃣ 重新插拔 USB 线
            2️⃣ 重启 usbmuxd: sudo killall usbmuxd
            """
        }
        if errorOutput.isEmpty {
            return """
            连接失败。请尝试：
            1️⃣ 用 USB 线连接 iPhone
            2️⃣ 确保 iPhone 已解锁并信任此电脑
            3️⃣ 在 iPhone 设置 → 隐私与安全性 → 开发者模式中检查
            """
        }
        return ""
    }
}

final class GPXParserDelegate: NSObject, XMLParserDelegate {
    var coordinates: [CLLocationCoordinate2D] = []
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        if ["wpt", "trkpt", "rtept"].contains(elementName) {
            if let latStr = attributeDict["lat"], let lonStr = attributeDict["lon"],
               let lat = Double(latStr), let lon = Double(lonStr) {
                coordinates.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
        }
    }
}

enum LocationError: LocalizedError {
    case tunnelError(String)
    var errorDescription: String? {
        switch self {
        case .tunnelError(let m): return "Tunneld 错误: \(m)"
        }
    }
}
