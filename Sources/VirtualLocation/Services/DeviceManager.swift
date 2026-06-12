import Foundation

final class DeviceManager {
    private let xcrun = "/usr/bin/xcrun"
    var onLog: ((LogEntry.Level, String) -> Void)?

    struct DetectedDevice {
        let udid: String
        let name: String
        let osVersion: String
    }

    func detectDevices() async -> [DetectedDevice] {
        log(.cmd, "执行: \(xcrun) xctrace list devices")
        do {
            let output = try await shell(xcrun, args: ["xctrace", "list", "devices"])
            log(.out, "输出:\n\(output)")
            let devices = parseXcrunOutput(output)
            log(.info, "检测到 \(devices.count) 个 iOS 设备")
            for d in devices {
                log(.info, "  ├─ \(d.name)  iOS \(d.osVersion)  UDID: \(d.udid)")
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
        let pattern = #/^(.+?)\s+\(([\d.]+)\)(?:.*?)\(([\w\-]+)\)$/#
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("==") else { continue }
            if let match = try? pattern.firstMatch(in: trimmed) {
                devices.append(DetectedDevice(
                    udid: String(match.3),
                    name: String(match.1).trimmingCharacters(in: .whitespaces),
                    osVersion: String(match.2)))
            } else {
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
