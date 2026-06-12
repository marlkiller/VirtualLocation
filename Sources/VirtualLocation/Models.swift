import Foundation

struct LocationPreset: Identifiable, Hashable, Codable {
    let id: UUID
    let name: String
    let latitude: Double
    let longitude: Double
    let landmark: String
    let region: String

    init(name: String, latitude: Double, longitude: Double, landmark: String, region: String) {
        self.id = UUID()
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.landmark = landmark
        self.region = region
    }

    var coordinateString: String {
        String(format: "%.4f, %.4f", latitude, longitude)
    }
}

extension LocationPreset {
    static let builtin: [LocationPreset] = [
        LocationPreset(name: "天安门广场",  latitude: 39.9042, longitude: 116.3974, landmark: "天安门城楼",   region: "北京市东城区"),
        LocationPreset(name: "东方明珠塔",  latitude: 31.2397, longitude: 121.4997, landmark: "东方明珠塔",  region: "上海市浦东新区"),
    ]
}

struct DeviceInfo: Identifiable {
    let id: String
    let name: String
    let osVersion: String

    var shortName: String {
        name.replacingOccurrences(of: "Voidm-", with: "")
    }
}

struct AppStatus: Equatable {
    let message: String
    let isError: Bool

    static let ready  = AppStatus(message: "就绪", isError: false)
    static func error(_ msg: String) -> AppStatus   { AppStatus(message: msg, isError: true) }
    static func info(_ msg: String) -> AppStatus    { AppStatus(message: msg, isError: false) }
}

enum ToolState: Equatable {
    case checking
    case missing
    case present(String)
    case installing
}

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: Level
    let message: String

    enum Level: String { case cmd, out, err, info }

    var formatted: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        let prefix: String
        switch level {
        case .cmd:  prefix = "▶"
        case .out:  prefix = "▸"
        case .err:  prefix = "✗"
        case .info: prefix = "·"
        }
        return "\(prefix) \(f.string(from: timestamp)) \(message)"
    }
}
