import SwiftUI

private enum TBFont {
    static let icon: CGFloat = 11
    static let label: CGFloat = 11
    static let subtitle: CGFloat = 9
    static let button: CGFloat = 10
    static let micro: CGFloat = 8
}

struct TopToolbarView: View {
    @ObservedObject var service: LocationService
    var onStartSimulation: () -> Void
    var onStopSimulation: () -> Void
    var onRefreshDevice: () -> Void
    var onStartTunnel: () -> Void
    var onStopTunnel: () -> Void
    var onToggleSearchPanel: () -> Void
    var onInstallTunnel: () -> Void
    var onUninstallTunnel: () -> Void
    var onSelectDevice: (String) -> Void

    @State private var pulseAnim = false

    private var isSimulating: Bool { service.isSimulating }
    private var hasDevice: Bool { service.device != nil }
    private var deviceName: String { service.device?.shortName ?? "未选择" }
    private var hasDetectedDevices: Bool { service.detectedDevices.count > 0 }
    private var isRefreshing: Bool { service.isRefreshingDevices }
    private var deviceLabel: String {
        if let udid = service.selectedDeviceUdid,
           let dev = service.detectedDevices.first(where: { $0.udid == udid }) {
            return dev.name
        }
        return "选择设备…"
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: 68)

            toggleSearchButton
            separator
            modePicker
            separator
            if service.locationMode == .simple {
                deviceSection
                separator
            }
            connectionSection
            separator
            statusSection
            Spacer()
            hintBadge
            actionsSection
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .nativeGlass(material: .headerView, blendingMode: .withinWindow)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 6)
    }

    // MARK: - Toggle Search

    private var toggleSearchButton: some View {
        Button(action: onToggleSearchPanel) {
            Image(systemName: "sidebar.left")
                .font(.system(size: TBFont.icon, weight: .medium))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.iconButton(size: 26))
        .help("显示/隐藏搜索面板")
    }

    // MARK: - Device

    private var deviceSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: TBFont.icon))
                .foregroundColor(hasDevice ? .dsSuccess : .secondary)

            if hasDetectedDevices {
                Menu {
                    Button(action: { onSelectDevice("") }) {
                        HStack(spacing: 6) {
                            Text("选择设备…")
                            if service.selectedDeviceUdid == nil {
                                Spacer()
                                Image(systemName: "checkmark")
                                    .font(.system(size: TBFont.button))
                                    .foregroundColor(.dsAccent)
                            }
                        }
                    }
                    ForEach(service.detectedDevices, id: \.udid) { dev in
                        Button(action: { onSelectDevice(dev.udid) }) {
                            HStack(spacing: 6) {
                                Text("\(dev.name) (iOS \(dev.osVersion))")
                                if dev.udid == service.selectedDeviceUdid {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                        .font(.system(size: TBFont.button))
                                        .foregroundColor(.dsAccent)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(deviceLabel)
                            .font(.system(size: TBFont.label, weight: .medium))
                            .foregroundColor(.primary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: TBFont.micro))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .fixedSize()
                .disabled(isRefreshing)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(deviceName)
                        .font(.system(size: TBFont.label, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: 100, alignment: .leading)
                    HStack(spacing: 3) {
                        StatusDot(color: hasDevice ? .dsSuccess : .dsError, size: 4)
                        Text(hasDevice ? "已连接" : "未连接")
                            .font(.system(size: TBFont.subtitle))
                            .foregroundColor(hasDevice ? .dsSuccess : .secondary)
                    }
                }
            }

            Button(action: onRefreshDevice) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: TBFont.icon, weight: .medium))
            }
            .buttonStyle(.iconButton(size: 22))
            .help("刷新设备")
            .disabled(isRefreshing)
        }
    }

    // MARK: - Mode Picker

    private var modePicker: some View {
        Menu {
            ForEach(LocationMode.allCases, id: \.self) { mode in
                Button(action: { switchMode(to: mode) }) {
                    HStack(spacing: 6) {
                        Image(systemName: mode.icon)
                            .frame(width: 14)
                        Text(mode.rawValue)
                            .font(.system(size: TBFont.label))
                        if mode == service.locationMode {
                            Spacer()
                            Image(systemName: "checkmark")
                                .font(.system(size: TBFont.button))
                                .foregroundColor(.dsAccent)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: service.locationMode.icon)
                    .font(.system(size: TBFont.icon))
                Text(service.locationMode.rawValue)
                    .font(.system(size: TBFont.label, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: TBFont.micro))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .fixedSize()
    }

    private func switchMode(to mode: LocationMode) {
        guard mode != service.locationMode else { return }
        if mode == .proxy {
            if service.isSimulating {
                Task { await service.clearLocation() }
            }
        } else {
            if service.proxyState.isActive {
                service.stopProxy()
            }
        }
        service.locationMode = mode
    }

    // MARK: - Connection (Tunnel or Proxy)

    @ViewBuilder
    private var connectionSection: some View {
        if service.locationMode == .simple {
            tunnelSection
        } else {
            proxySection
        }
    }

    // MARK: - Tunnel

    private var tunnelSection: some View {
        HStack(spacing: 5) {
            Image(systemName: "cable.connector")
                .font(.system(size: TBFont.icon))
                .foregroundColor(tunnelColor)

            VStack(alignment: .leading, spacing: 0) {
                Text("Tunneld")
                    .font(.system(size: TBFont.label, weight: .medium))
                    .foregroundColor(.primary)
                Text(tunnelLabel)
                    .font(.system(size: TBFont.subtitle))
                    .foregroundColor(tunnelColor)
            }

            if case .installing = service.tunnelInstallState {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.4)
                        .frame(width: 8, height: 8)
                    Text("安装中…")
                        .font(.system(size: TBFont.button))
                        .foregroundColor(.dsWarning)
                }
            } else if case .uninstalling = service.tunnelInstallState {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.4)
                        .frame(width: 8, height: 8)
                    Text("卸载中…")
                        .font(.system(size: TBFont.button))
                        .foregroundColor(.dsWarning)
                }
            } else if case .missing = service.toolState {
                installButton
            } else {
                HStack(spacing: 3) {
                    tunnelActionButton
                    uninstallButton
                }
            }
        }
    }

    @ViewBuilder
    private var installButton: some View {
        Button(action: onInstallTunnel) {
            Text("安装")
                .font(.system(size: TBFont.button, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.dsAccent)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("安装 pymobiledevice3")
    }

    @ViewBuilder
    private var uninstallButton: some View {
        Button(action: onUninstallTunnel) {
            Text("卸载")
                .font(.system(size: TBFont.button, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.dsError.opacity(0.12))
                .foregroundColor(.dsError)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("卸载 pymobiledevice3")
    }

    @ViewBuilder
    private var tunnelActionButton: some View {
        switch service.tunnelState {
        case .disconnected:
            Button(action: onStartTunnel) {
                Text("启动")
                    .font(.system(size: TBFont.button, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(service.canStartTunnel ? Color.dsAccent : Color.secondary.opacity(0.2))
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!service.canStartTunnel)
            .help("启动 Tunneld")
        case .starting:
            ProgressView()
                .scaleEffect(0.4)
                .frame(width: 32)
        case .connected:
            Button(action: onStopTunnel) {
                Text("停止")
                    .font(.system(size: TBFont.button, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.dsError.opacity(0.12))
                    .foregroundColor(.dsError)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("停止 Tunneld")
        case .failed:
            Button(action: onStartTunnel) {
                Text("重试")
                    .font(.system(size: TBFont.button, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.dsWarning)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("重试 Tunneld")
        }
    }

    private var tunnelColor: Color {
        switch service.tunnelState {
        case .disconnected: return .secondary
        case .starting: return .dsWarning
        case .connected: return .dsSuccess
        case .failed: return .dsError
        }
    }

    private var tunnelLabel: String {
        switch service.tunnelState {
        case .disconnected: return "未启动"
        case .starting: return "启动中…"
        case .connected: return "已连接"
        case .failed: return "失败"
        }
    }

    // MARK: - Proxy

    private var proxySection: some View {
        HStack(spacing: 5) {
            Image(systemName: "network.badge.shield.half.filled")
                .font(.system(size: 11))
                .foregroundColor(proxyColor)

            VStack(alignment: .leading, spacing: 0) {
                Text("代理")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                Text(proxyLabel)
                    .font(.system(size: 8))
                    .foregroundColor(proxyColor)
            }

            proxyActionButton
        }
    }

    @ViewBuilder
    private var proxyActionButton: some View {
        switch service.proxyState {
        case .stopped:
            Button(action: { Task { await service.startProxy() } }) {
                Text("启动")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.dsAccent)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("启动代理模式")
        case .starting:
            ProgressView()
                .scaleEffect(0.4)
                .frame(width: 32)
        case .running:
            Button(action: { service.stopProxy() }) {
                Text("停止")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.dsError.opacity(0.12))
                    .foregroundColor(.dsError)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("停止代理")
        case .failed:
            Button(action: { Task { await service.startProxy() } }) {
                Text("重试")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.dsWarning)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("重试代理")
        }
    }

    private var proxyColor: Color {
        switch service.proxyState {
        case .stopped: return .secondary
        case .starting: return .dsWarning
        case .running: return .dsSuccess
        case .failed: return .dsError
        }
    }

    private var proxyLabel: String {
        switch service.proxyState {
        case .stopped: return "未启动"
        case .starting: return "启动中…"
        case .running(let port): return ":\(port)"
        case .failed: return "失败"
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        HStack(spacing: 6) {
            Image(systemName: service.locationMode == .proxy ? "network.badge.shield.half.filled" : "location.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(statusIconColor)
                .scaleEffect(isSimulating && pulseAnim ? 1.15 : 1)
                .animation(isSimulating
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default, value: pulseAnim)
                .onChange(of: isSimulating) { _, newValue in
                    pulseAnim = newValue
                }

            VStack(alignment: .leading, spacing: 0) {
                Text(statusTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                Text(statusSubtitle)
                    .font(.system(size: 8))
                    .foregroundColor(statusSubtitleColor)
            }
        }
    }

    private var statusTitle: String {
        if isSimulating { return "模拟中" }
        return service.locationMode == .proxy ? "代理" : "GPS"
    }

    private var statusSubtitle: String {
        if isSimulating { return "已注入" }
        if service.locationMode == .proxy {
            switch service.proxyState {
            case .running: return "就绪"
            case .starting: return "启动中…"
            case .failed: return "失败"
            case .stopped: return "待启动"
            }
        }
        return "待命"
    }

    private var statusIconColor: Color {
        if isSimulating { return .dsSuccess }
        if service.locationMode == .proxy {
            if case .running = service.proxyState { return .dsWarning }
            if case .failed = service.proxyState { return .dsError }
        }
        return .secondary
    }

    private var statusSubtitleColor: Color {
        if isSimulating { return .dsSuccess }
        if service.locationMode == .proxy {
            if case .running = service.proxyState { return .dsWarning }
            if case .failed = service.proxyState { return .dsError }
        }
        return .secondary
    }

    // MARK: - Hint

    @ViewBuilder
    private var hintBadge: some View {
        let hint: String = {
            if service.locationMode == .proxy {
                return "应用位置后，关闭再打开系统定位服务以清除缓存"
            } else if !service.isSimulating {
                return "设备需开启开发者模式，信任此电脑后生效"
            }
            return ""
        }()
        if !hint.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.dsAccent)
                Text(hint)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.primary.opacity(0.75))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.dsAccent.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .padding(.trailing, 4)
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        HStack(spacing: 5) {
            switch service.locationState {
            case .active:
                Button(action: onStopSimulation) {
                    Label("恢复", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.glass(tint: .dsError, prominent: true))
                .controlSize(.small)
                .shadow(color: .dsError.opacity(pulseAnim ? 0.4 : 0), radius: 6)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulseAnim)
                .help("恢复真实位置")

            default:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: service.locationState)
    }
}
