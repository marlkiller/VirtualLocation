import Foundation

struct LocationPreset: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let latitude: Double
    let longitude: Double
    let landmark: String
    let region: String

    var coordinateString: String {
        String(format: "%.4f, %.4f", latitude, longitude)
    }
}

extension LocationPreset {
    static let presets: [LocationPreset] = [
        LocationPreset(name: "天安门广场",  latitude: 39.9042, longitude: 116.3974, landmark: "天安门城楼",     region: "北京市东城区"),
        LocationPreset(name: "埃菲尔铁塔",  latitude: 48.8584, longitude: 2.2945,   landmark: "埃菲尔铁塔",    region: "法国巴黎"),
        LocationPreset(name: "自由女神像",  latitude: 40.6892, longitude: -74.0445, landmark: "自由女神像",    region: "美国纽约"),
        LocationPreset(name: "胡夫金字塔",  latitude: 29.9792, longitude: 31.1342,  landmark: "胡夫金字塔",    region: "埃及吉萨"),
        LocationPreset(name: "悉尼歌剧院",  latitude: -33.8568,longitude: 151.2153, landmark: "悉尼歌剧院",    region: "澳大利亚悉尼"),
        LocationPreset(name: "东京塔",     latitude: 35.6586, longitude: 139.7454, landmark: "东京塔",        region: "日本东京"),
        LocationPreset(name: "东方明珠塔",  latitude: 31.2397, longitude: 121.4997, landmark: "东方明珠塔",   region: "上海市浦东新区"),
        LocationPreset(name: "故宫博物院",  latitude: 39.9163, longitude: 116.3972, landmark: "太和殿",        region: "北京市东城区"),
        LocationPreset(name: "大本钟",     latitude: 51.5007, longitude: -0.1246,  landmark: "伊丽莎白塔",   region: "英国伦敦"),
        LocationPreset(name: "圣家堂",     latitude: 41.4036, longitude: 2.1744,   landmark: "圣家堂",        region: "西班牙巴塞罗那"),
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

enum CheckinStep: Int, CaseIterable, Comparable {
    case idle = -1
    case locate = 0
    case airplane = 1
    case offLocation = 2
    case waiting = 3
    case onLocation = 4
    case checkin = 5
    case done = 6

    var label: String {
        switch self {
        case .idle:       return ""
        case .locate:     return "设置虚拟位置（自动执行）"
        case .airplane:   return "开启飞行模式（关闭蜂窝+WiFi）"
        case .offLocation:return "关闭定位服务"
        case .waiting:    return "等待 5 秒"
        case .onLocation: return "重新打开定位服务"
        case .checkin:    return "打开企业微信 → 打卡"
        case .done:       return "打卡完成，关闭飞行模式"
        }
    }

    static func < (lhs: CheckinStep, rhs: CheckinStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
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
