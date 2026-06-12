import Foundation

@MainActor
final class LocationService: ObservableObject {
    @Published var toolState: ToolState = .checking
    @Published var tunnelState: TunnelState = .disconnected
    @Published var status = AppStatus.ready
    @Published var device: DeviceInfo?
    @Published var logs: [LogEntry] = []
    @Published var manualUDID = ""
    @Published var checkinStep: CheckinStep = .idle
    @Published var checkinCountdown = 5

    private let deviceManager = DeviceManager()
    let pmd3Path = "\(NSHomeDirectory())/.venv_pmd3/bin/pymobiledevice3"
    private var dvtTask: Process?

    enum TunnelState: Equatable {
        case disconnected
        case starting
        case connected
        case failed(String)
    }

    init() {
        deviceManager.onLog = { [weak self] level, msg in
            DispatchQueue.main.async { self?.addLog(level, msg) }
        }
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
        do {
            let out = try await shell("/usr/bin/python3", args: [
                "-m", "venv", "\(NSHomeDirectory())/.venv_pmd3"
            ])
            addLog(.out, out)
            let pip = "\(NSHomeDirectory())/.venv_pmd3/bin/pip"
            let out2 = try await shell(pip, args: ["install", "pymobiledevice3"])
            addLog(.out, out2)
            addLog(.info, "✅ pymobiledevice3 安装完成")
            try? await Task.sleep(nanoseconds: 300_000_000)
            await checkTool()
        } catch {
            toolState = .missing
            addLog(.err, "安装失败: \(error.localizedDescription)")
            status = AppStatus.error("安装失败: \(error.localizedDescription)")
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
                            // 等待几秒让 daemon 完成初始化
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
        // 杀掉 tunneld 进程
        _ = try? await shell("/usr/bin/pkill", args: ["-f", "tunneld"])
        dvtTask?.terminate()
        dvtTask = nil
        tunnelState = .disconnected
        addLog(.info, "Tunneld 已停止")
        status = AppStatus.info("Tunneld 已断开")
    }

    // MARK: - Location

    func setLocation(lat: Double, lng: Double) async {
        guard case .present = toolState else {
            status = AppStatus.error("请先安装依赖"); return
        }
        guard let dev = device else {
            status = AppStatus.error("请先连接设备"); return
        }
        guard case .connected = tunnelState else {
            status = AppStatus.error("请先启动 Tunneld"); return
        }

        dvtTask?.terminate()
        dvtTask = nil

        let latStr = String(format: "%.6f", lat)
        let lngStr = String(format: "%.6f", lng)
        addLog(.cmd, "DVT 设置位置: \(latStr), \(lngStr) [设备: \(dev.id)]")
        status = AppStatus.info("正在设置位置 …")

        let dvt = Process()
        dvt.executableURL = URL(fileURLWithPath: pmd3Path)
        dvt.arguments = ["developer", "dvt", "simulate-location", "set",
                         "--tunnel", dev.id, "--", latStr, lngStr]

        do {
            try dvt.run()
            self.dvtTask = dvt
            addLog(.info, "✅ DVT 位置已设置 (\(latStr), \(lngStr))")
            status = AppStatus.info("✅ 位置已设为 \(latStr), \(lngStr)")
        } catch {
            addLog(.err, "启动 DVT 失败: \(error.localizedDescription)")
            status = AppStatus.error("设置失败: \(error.localizedDescription)")
        }
    }

    func clearLocation() async {
        guard let dev = device else {
            status = AppStatus.error("请先连接设备"); return
        }

        dvtTask?.terminate()
        dvtTask = nil
        addLog(.info, "DVT 进程已终止")

        do {
            let out = try await shell(pmd3Path, args: [
                "developer", "dvt", "simulate-location", "clear",
                "--tunnel", dev.id
            ])
            addLog(.out, out)
            addLog(.info, "✅ 位置已清除")
            status = AppStatus.info("✅ 位置已恢复真实 GPS")
        } catch {
            addLog(.info, "位置已恢复")
            status = AppStatus.info("位置已恢复")
        }
    }

    // MARK: - Check-in Mode

    func startCheckinMode(lat: Double, lng: Double) async {
        guard case .present = toolState else {
            status = AppStatus.error("请先安装依赖"); return
        }
        guard device != nil else {
            status = AppStatus.error("请先连接设备"); return
        }
        guard case .connected = tunnelState else {
            status = AppStatus.error("请先启动 Tunneld"); return
        }

        await setLocation(lat: lat, lng: lng)
        checkinStep = .locate
        addLog(.info, "📌 打卡模式启动，位置已设置")
    }

    func advanceCheckinStep() {
        guard checkinStep.rawValue < CheckinStep.done.rawValue else { return }
        let next = CheckinStep(rawValue: checkinStep.rawValue + 1) ?? .done
        checkinStep = next
        addLog(.cmd, "➡ 打卡步骤: \(next.label)")
        if next == .waiting {
            startCountdown()
        }
    }

    func resetCheckinMode() {
        checkinStep = .idle
        checkinCountdown = 5
        addLog(.info, "打卡模式已退出")
    }

    private func startCountdown() {
        checkinCountdown = 5
        Task {
            while checkinCountdown > 0 && checkinStep == .waiting {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                checkinCountdown -= 1
            }
            if checkinStep == .waiting {
                advanceCheckinStep()
            }
        }
    }

    // MARK: - Shell

    private func shell(_ path: String, args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = args
            let outPipe = Pipe(), errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe
            task.terminationHandler = { proc in
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                let errOut = String(data: errData, encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    cont.resume(returning: output)
                } else {
                    let msg = (errOut.isEmpty ? output : errOut).trimmingCharacters(in: .whitespacesAndNewlines)
                    cont.resume(throwing: LocationError.shellError(msg))
                }
            }
            do { try task.run() } catch { cont.resume(throwing: error) }
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
