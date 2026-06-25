import Foundation

final class DeviceManager {
    private let xcrun = "/usr/bin/xcrun"
    var onLog: ((LogEntry.Level, String) -> Void)?

    struct DetectedDevice {
        let udid: String
        let name: String
        let osVersion: String
        let isOffline: Bool
    }

    func detectDevices() async -> [DetectedDevice] {
        log(.cmd, "执行: \(xcrun) xctrace list devices")
        do {
            let output = try await shell(xcrun, args: ["xctrace", "list", "devices"])
            log(.out, "输出:\n\(output)")
            let devices = parseXcrunOutput(output)
            let online = devices.filter { !$0.isOffline }
            let offline = devices.filter { $0.isOffline }
            log(.info, "检测到 \(online.count) 个在线设备, \(offline.count) 个离线设备")
            for d in devices {
                let tag = d.isOffline ? " [离线]" : ""
                log(.info, "  ├─ \(d.name)  iOS \(d.osVersion)  UDID: \(d.udid)\(tag)")
            }
            return devices
        } catch {
            log(.err, "xcrun 失败: \(error.localizedDescription)")
            return []
        }
    }

    private func parseXcrunOutput(_ raw: String) -> [DetectedDevice] {
        let lines = raw.split(separator: "\n").map(String.init)
        var devices: [DetectedDevice] = []
        var offline = false
        let pattern = try! NSRegularExpression(pattern: #"(.+?)\s+\(([\d.]+)\)\s+\((00008[0-9A-Fa-f]{3}-[0-9A-Fa-f]{16})\)"#)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("==") else {
                if trimmed.hasPrefix("== Devices Offline") { offline = true }
                continue
            }
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if let match = pattern.firstMatch(in: trimmed, range: range) {
                devices.append(DetectedDevice(
                    udid: (trimmed as NSString).substring(with: match.range(at: 3)),
                    name: (trimmed as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces),
                    osVersion: (trimmed as NSString).substring(with: match.range(at: 2)),
                    isOffline: offline))
            } else if !offline {
                log(.info, "跳过: \(trimmed)")
            }
        }
        return devices
    }

    private func shell(_ launchPath: String, args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: launchPath)
            task.arguments = args
            task.environment = ProcessInfo.processInfo.environment
            task.environment?["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
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
                    cont.resume(throwing: NSError(domain: "DeviceManager", code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: msg]))
                }
            }
            do { try task.run() } catch { cont.resume(throwing: error) }
        }
    }

    private func log(_ level: LogEntry.Level, _ msg: String) {
        onLog?(level, msg)
    }
}
