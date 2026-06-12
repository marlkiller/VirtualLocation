import Foundation

@MainActor
final class LocationService: ObservableObject {
    @Published var toolState: ToolState = .checking
    @Published var tunnelState: TunnelState = .disconnected
    @Published var status = AppStatus.ready
    @Published var device: DeviceInfo?
    @Published var logs: [LogEntry] = []
    @Published var manualUDID = ""
    @Published var customPresets: [LocationPreset] = []
    @Published var locationState: LocationState = .idle

    var allPresets: [LocationPreset] { LocationPreset.builtin + customPresets }

    private let deviceManager = DeviceManager()
    let pmd3Path = "\(NSHomeDirectory())/.venv_pmd3/bin/pymobiledevice3"
    private var dvtTask: Process?
    private var refreshTimer: Timer?
    private var currentLat: Double = 0
    private var currentLng: Double = 0

    enum TunnelState: Equatable {
        case disconnected
        case starting
        case connected
        case failed(String)
    }

    enum LocationState: Equatable {
        case idle
        case setting
        case active(lat: Double, lng: Double)
        case failed(String)
    }

    init() {
        loadCustomPresets()
        deviceManager.onLog = { [weak self] level, msg in
            DispatchQueue.main.async { self?.addLog(level, msg) }
        }
    }

    // MARK: - Custom Presets

    func addCustomPreset(name: String, lat: Double, lng: Double) {
        let preset = LocationPreset(name: name, latitude: lat, longitude: lng, landmark: "", region: "自定义")
        customPresets.append(preset)
        saveCustomPresets()
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

    // MARK: - Log

    func addLog(_ level: LogEntry.Level, _ msg: String) {
        logs.append(LogEntry(timestamp: Date(), level: level, message: msg))
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
            status = AppStatus.error("pymobiledevice3 未安装 → 点击安装")
        }
    }

    func installDependencies() async {
        toolState = .installing
        addLog(.info, "正在安装 pymobiledevice3 …")
        status = AppStatus.info("正在安装 … (约 1-2 分钟)")
        let venvOk = await launchBlocking("/usr/bin/python3",
            args: ["-m", "venv", "\(NSHomeDirectory())/.venv_pmd3"],
            log: "venv")
        guard venvOk else {
            toolState = .missing
            status = AppStatus.error("venv 创建失败")
            return
        }
        let pip = "\(NSHomeDirectory())/.venv_pmd3/bin/pip"
        let pipOk = await launchBlocking(pip, args: ["install", "pymobiledevice3"], log: "pip")
        if pipOk {
            addLog(.info, "✅ pymobiledevice3 安装完成")
            try? await Task.sleep(nanoseconds: 300_000_000)
            await checkTool()
        } else {
            toolState = .missing
            status = AppStatus.error("pip install 失败")
        }
    }

    private func launchBlocking(_ path: String, args: [String], log: String) async -> Bool {
        await withCheckedContinuation { cont in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe
            task.terminationHandler = { proc in
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
                cont.resume(returning: proc.terminationStatus == 0)
            }
            try? task.run()
        }
    }

    // MARK: - Device

    func refreshDevices() async {
        let manual = manualUDID.trimmingCharacters(in: .whitespaces)
        if !manual.isEmpty {
            device = DeviceInfo(id: manual, name: "手动 (\(manual.prefix(8))…)", osVersion: "")
            status = AppStatus.info("已使用手动 UDID")
            return
        }
        status = AppStatus.info("正在扫描设备 …")
        let devices = await deviceManager.detectDevices()
        if let first = devices.first {
            device = DeviceInfo(id: first.udid, name: first.name, osVersion: first.osVersion)
            addLog(.info, "✅ 设备: \(first.name) iOS \(first.osVersion)")
            status = AppStatus.info("已连接: \(first.name)")
        } else {
            device = nil
            addLog(.err, "未检测到设备")
            status = AppStatus.error("未检测到 iOS 设备")
        }
    }

    // MARK: - Tunneld

    func startTunneld() async {
        guard case .present = toolState else {
            status = AppStatus.error("请先安装依赖"); return
        }
        guard device != nil else {
            status = AppStatus.error("请先连接设备"); return
        }

        tunnelState = .starting
        status = AppStatus.info("正在启动 Tunneld …")
        addLog(.info, "启动 Tunneld 需要管理员权限，请在弹窗中输入密码")
        addLog(.cmd, "执行: sudo \(pmd3Path) remote tunneld --daemonize")

        let script = """
        do shell script "\(pmd3Path) remote tunneld --daemonize" with administrator privileges
        """

        let asProc = Process()
        asProc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        asProc.arguments = ["-e", script]
        let outPipe = Pipe()
        let errPipe = Pipe()
        asProc.standardOutput = outPipe
        asProc.standardError = errPipe

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                asProc.terminationHandler = { proc in
                    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    let errOut = String(data: errData, encoding: .utf8) ?? ""
                    Task { @MainActor in
                        if proc.terminationStatus == 0 {
                            self.addLog(.info, "✅ Tunneld 已启动")
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            self.tunnelState = .connected
                            self.status = AppStatus.info("✅ Tunneld 就绪")
                            cont.resume()
                        } else {
                            let msg = (errOut.isEmpty ? output : errOut)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            self.tunnelState = .failed(msg)
                            self.addLog(.err, "Tunneld 启动失败: \(msg)")
                            self.status = AppStatus.error("Tunneld 启动失败")
                            cont.resume(throwing: LocationError.tunnelError(msg))
                        }
                    }
                }
                do { try asProc.run() } catch { cont.resume(throwing: error) }
            }
        } catch {
            tunnelState = .disconnected
            addLog(.err, "启动异常: \(error.localizedDescription)")
            status = AppStatus.error("Tunneld 启动失败")
        }
    }

    func stopTunneld() async {
        dvtTask?.terminate()
        dvtTask = nil
        stopLocationRefresh()
        let killTask = Process()
        killTask.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killTask.arguments = ["-f", "tunneld"]
        try? killTask.run()
        tunnelState = .disconnected
        locationState = .idle
        addLog(.info, "Tunneld 已停止")
        status = AppStatus.info("Tunneld 已断开")
    }

    // MARK: - Location

    func setLocation(lat: Double, lng: Double) async {
        currentLat = lat
        currentLng = lng

        guard case .present = toolState else {
            status = AppStatus.error("请先安装依赖"); return
        }
        guard let dev = device else {
            status = AppStatus.error("请先连接设备"); return
        }
        guard case .connected = tunnelState else {
            status = AppStatus.error("请先启动 Tunneld"); return
        }

        locationState = .setting

        let latStr = String(format: "%.6f", lat)
        let lngStr = String(format: "%.6f", lng)
        addLog(.cmd, "DVT 设置位置: \(latStr), \(lngStr) [设备: \(dev.id)]")
        status = AppStatus.info("正在设置位置 …")

        let (success, output) = await launchDVTWithTimeout(
            args: ["developer", "dvt", "simulate-location", "set",
                   "--tunnel", dev.id, "--", latStr, lngStr],
            timeout: 10)
        if success {
            if !output.isEmpty { addLog(.out, output) }
            addLog(.info, "✅ DVT 位置已设置 (\(latStr), \(lngStr))")
            status = AppStatus.info("✅ 位置已设为 \(latStr), \(lngStr)")
        } else {
            addLog(.err, "DVT 超时/失败: \(output)")
            addLog(.info, "但已保存坐标，定时刷新会持续重试")
            status = AppStatus.info("位置已提交（后台刷新中）")
        }

        locationState = .active(lat: lat, lng: lng)
        startLocationRefresh()
    }

    func clearLocation() async {
        stopLocationRefresh()
        dvtTask?.interrupt()
        dvtTask = nil

        guard let dev = device else {
            locationState = .idle
            status = AppStatus.error("请先连接设备"); return
        }

        launchDVT(args: ["developer", "dvt", "simulate-location", "clear",
                         "--tunnel", dev.id]) { [weak self] success, output in
            DispatchQueue.main.async {
                guard let self else { return }
                if success { self.addLog(.out, output) }
                self.addLog(.info, "✅ 位置已清除")
                self.locationState = .idle
                self.status = AppStatus.info("✅ 位置已恢复真实 GPS")
            }
        }
    }

    // MARK: - Location Refresh

    private func startLocationRefresh() {
        stopLocationRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.refreshLocation()
            }
        }
        addLog(.info, "定时刷新已启动 (每 30s)")
    }

    private func stopLocationRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refreshLocation() async {
        guard case .active = locationState else { return }
        guard let dev = device, case .connected = tunnelState else { return }

        let latStr = String(format: "%.6f", currentLat)
        let lngStr = String(format: "%.6f", currentLng)

        let (success, output) = await launchDVTWithTimeout(
            args: ["developer", "dvt", "simulate-location", "set",
                   "--tunnel", dev.id, "--", latStr, lngStr],
            timeout: 10)
        if success {
            addLog(.info, "🔄 位置已刷新 (\(latStr), \(lngStr))")
        } else {
            addLog(.err, "刷新失败: \(output)")
        }
    }

    // MARK: - DVT Launch

    private func launchDVT(args: [String], completion: @escaping (Bool, String) -> Void) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: pmd3Path)
        task.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        self.dvtTask = task

        final class Flag: @unchecked Sendable { var value = false }
        let timedOut = Flag()
        task.terminationHandler = { proc in
            if timedOut.value { return }
            let o = (try? outPipe.fileHandleForReading.readToEnd()).flatMap {
                String(data: $0, encoding: .utf8)
            } ?? ""
            let e = (try? errPipe.fileHandleForReading.readToEnd()).flatMap {
                String(data: $0, encoding: .utf8)
            } ?? ""
            completion(proc.terminationStatus == 0, proc.terminationStatus == 0 ? o : (e.isEmpty ? o : e))
        }

        do {
            try task.run()
        } catch {
            completion(false, error.localizedDescription)
            return
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if task.isRunning {
                timedOut.value = true
                task.interrupt()
                completion(true, "已发送 SIGINT (DVT 正常退出)")
            }
        }
    }

    private func launchDVTWithTimeout(args: [String], timeout: TimeInterval = 8) async -> (Bool, String) {
        await withCheckedContinuation { cont in
            var didFinish = false
            launchDVT(args: args) { success, output in
                if !didFinish { didFinish = true; cont.resume(returning: (success, output)) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if !didFinish { didFinish = true; cont.resume(returning: (false, "超时")) }
            }
        }
    }
}

enum LocationError: LocalizedError {
    case tunnelError(String)
    case dvtError(String)
    case shellError(String)
    var errorDescription: String? {
        switch self {
        case .tunnelError(let m): return "Tunneld 错误: \(m)"
        case .dvtError(let m):    return "DVT 错误: \(m)"
        case .shellError(let m):  return m
        }
    }
}
