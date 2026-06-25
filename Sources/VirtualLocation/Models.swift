import Foundation
import MapKit

// MARK: - Location Preset
struct LocationPreset: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
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

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var coordinateString: String {
        String(format: "%.4f, %.4f", latitude, longitude)
    }
}

extension LocationPreset {
    static let builtin: [LocationPreset] = [
        LocationPreset(name: "Apple Park", latitude: 37.3349, longitude: -122.0090, landmark: "Apple Park", region: "Cupertino, CA"),
        LocationPreset(name: "东京塔", latitude: 35.6586, longitude: 139.7454, landmark: "东京塔", region: "东京都港区"),
        LocationPreset(name: "天安门广场", latitude: 39.9042, longitude: 116.3974, landmark: "天安门城楼", region: "北京市东城区"),
        LocationPreset(name: "公司", latitude: 39.966777, longitude: 116.375921, landmark: "王府井大街", region: "北京市东城区"),
        LocationPreset(name: "东方明珠塔", latitude: 31.2397, longitude: 121.4997, landmark: "东方明珠塔", region: "上海市浦东新区"),
    ]
}

// MARK: - Device Info
struct DeviceInfo: Identifiable {
    let id: String
    let name: String
    let osVersion: String

    var shortName: String {
        name.replacingOccurrences(of: "Voidm-", with: "")
    }
}

// MARK: - App Status
struct AppStatus: Equatable {
    let message: String
    let isError: Bool

    static let ready  = AppStatus(message: "就绪", isError: false)
    static func error(_ msg: String) -> AppStatus   { AppStatus(message: msg, isError: true) }
    static func info(_ msg: String) -> AppStatus    { AppStatus(message: msg, isError: false) }
}

// MARK: - Tool State
enum ToolState: Equatable {
    case checking
    case missing
    case present(String)
    case installing
}

// MARK: - Log Entry
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

// MARK: - Search History
struct SearchHistoryItem: Identifiable, Codable {
    let id: UUID
    let query: String
    let latitude: Double
    let longitude: Double
    let timestamp: Date

    init(query: String, latitude: Double, longitude: Double) {
        self.id = UUID()
        self.query = query
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = Date()
    }

    var coordinateString: String {
        String(format: "%.4f, %.4f", latitude, longitude)
    }
}

// MARK: - Location Mode
enum LocationMode: String, CaseIterable, Codable {
    case simple = "普通模式"
    case proxy = "代理模式"

    var icon: String {
        switch self {
        case .simple: return "antenna.radiowaves.left.and.right"
        case .proxy:  return "network.badge.shield.half.filled"
        }
    }
}

// MARK: - Proxy State
enum ProxyState: Equatable {
    case stopped
    case starting
    case running(port: UInt16)
    case failed(String)

    var isActive: Bool {
        if case .running = self { true } else { false }
    }
}

// MARK: - Proxy Settings
struct ProxySettings: Codable {
    var port: UInt16 = 8888
    var autoStart: Bool = false

    static let `default` = ProxySettings()
}

// MARK: - Map Selection State
struct MapSelectionState {
    var selectedCoordinate: CLLocationCoordinate2D? = nil
    var selectedPlaceName: String = ""
    var activeCoordinate: CLLocationCoordinate2D? = nil
    var centerCoordinate: CLLocationCoordinate2D? = nil
    var searchResults: [MKMapItem] = []
    var isSearching: Bool = false
}
