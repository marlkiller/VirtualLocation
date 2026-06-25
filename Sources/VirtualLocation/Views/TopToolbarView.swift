import SwiftUI

struct TopToolbarView: View {
    @ObservedObject var service: LocationService
    var onStartSimulation: () -> Void
    var onStopSimulation: () -> Void
    var onRefreshDevice: () -> Void
    var onStartTunnel: () -> Void
    var onStopTunnel: () -> Void
    var onToggleSearchPanel: () -> Void

    @State private var pulseAnim = false

    private var isSimulating: Bool { service.isSimulating }
    private var hasDevice: Bool { service.device != nil }
    private var deviceName: String { service.device?.shortName ?? "未检测到设备" }

    var body: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: 68)

            toggleSearchButton
            separator
            deviceSection
            separator
            modePicker
            separator
            connectionSection
            separator
            statusSection
            Spacer()
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
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.iconButton(size: 26))
        .help("显示/隐藏搜索面板")
    }

    // MARK: - Device

    private var deviceSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 12))
                .foregroundColor(hasDevice ? .dsSuccess : .secondary)

            VStack(alignment: .leading, spacing: 0) {
                Text(deviceName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: 100, alignment: .leading)
                HStack(spacing: 3) {
                    StatusDot(color: hasDevice ? .dsSuccess : .dsError, size: 4)
                    Text(hasDevice ? "已检测" : "未连接")
                        .font(.system(size: 8))
                        .foregroundColor(hasDevice ? .dsSuccess : .secondary)
                }
            }

            Button(action: onRefreshDevice) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9, weight: .medium))
            }
            .buttonStyle(.iconButton(size: 22))
            .help("刷新设备")
            .disabled(service.toolState == .checking)
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
                            .font(.system(size: 12))
                        if mode == service.locationMode {
                            Spacer()
                            Image(systemName: "checkmark")
                                .font(.system(size: 10))
                                .foregroundColor(.dsAccent)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: service.locationMode.icon)
                    .font(.system(size: 10))
                Text(service.locationMode.rawValue)
                    .font(.system(size: 10, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7))
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
                .font(.system(size: 11))
                .foregroundColor(tunnelColor)

            VStack(alignment: .leading, spacing: 0) {
                Text("Tunneld")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                Text(tunnelLabel)
                    .font(.system(size: 8))
                    .foregroundColor(tunnelColor)
            }

            tunnelActionButton
        }
    }

    @ViewBuilder
    private var tunnelActionButton: some View {
        switch service.tunnelState {
        case .disconnected:
            Button(action: onStartTunnel) {
                Text("启动")
                    .font(.system(size: 9, weight: .semibold))
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
                    .font(.system(size: 9, weight: .semibold))
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
                    .font(.system(size: 9, weight: .semibold))
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
                    if newValue { pulseAnim = true }
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
