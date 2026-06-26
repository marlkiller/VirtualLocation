import SwiftUI

private enum TBFont {
    static let icon: CGFloat = 12
    static let label: CGFloat = 12
    static let subtitle: CGFloat = 10
    static let button: CGFloat = 11
    static let micro: CGFloat = 9
}

struct TopToolbarView: View {
    @ObservedObject var service: LocationService
    var onRefreshDevice: () -> Void
    var onToggleSearchPanel: () -> Void
    var onSelectDevice: (String) -> Void
    var onInstallTunnel: () -> Void
    var onUninstallTunnel: () -> Void

    @State private var pulseAnim = false
    @State private var showSettings = false
    @State private var showModeTip = false
    @State private var showDevicePicker = false

    private var isSimulating: Bool { service.isSimulating }
    private var hasDevice: Bool { service.device != nil }
    private var deviceName: String { service.device?.shortName ?? "未选择" }
    private var hasDetectedDevices: Bool { service.detectedDevices.count > 0 }
    private var isRefreshing: Bool { service.isRefreshingDevices }
    private var deviceLabel: String {
        if let udid = service.selectedDeviceUdid,
           let dev = service.detectedDevices.first(where: { $0.udid == udid }) {
            return dev.isOffline ? "\(dev.name) (离线)" : dev.name
        }
        return "选择设备…"
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: 68)

            toggleSearchButton
            separator
            modePicker
            modeTipButton
            separator
            if service.locationMode == .simple {
                deviceSection
                separator
            }
            connectionSection
            separator
            statusSection
            Spacer()
            settingsButton
            actionsSection
        }
        .padding(.horizontal, DS.Spacing.toolbar)
        .frame(height: 48)
        .nativeGlass(material: .headerView, blendingMode: .withinWindow)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1, height: 18)
            .padding(.horizontal, DS.Spacing.sectionGap)
    }

    // MARK: - Toggle Search

    private var toggleSearchButton: some View {
        Button(action: onToggleSearchPanel) {
            Image(systemName: "sidebar.left")
                .font(.system(size: TBFont.icon, weight: .medium))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.iconButton(size: 28))
        .help("显示/隐藏搜索面板")
    }

    // MARK: - Device

    private var deviceSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: TBFont.icon))
                .foregroundColor(hasDevice ? .dsSuccess : .secondary)

            if hasDetectedDevices {
                if hasDevice {
                    Text(deviceLabel)
                        .font(.system(size: TBFont.label, weight: .medium))
                        .lineLimit(1)
                        .frame(maxWidth: 200, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Button {
                        showDevicePicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(deviceLabel)
                                .font(.system(size: TBFont.label, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Image(systemName: "chevron.down")
                                .font(.system(size: TBFont.micro))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showDevicePicker, arrowEdge: .bottom) {
                        VStack(spacing: 0) {
                            Button(action: {
                                onSelectDevice("")
                                showDevicePicker = false
                            }) {
                                HStack(spacing: 6) {
                                    Text("选择设备…")
                                        .lineLimit(1)
                                    Spacer()
                                    if service.selectedDeviceUdid == nil {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: TBFont.button))
                                            .foregroundColor(.dsAccent)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            Divider()
                            ScrollView {
                                VStack(spacing: 0) {
                                    ForEach(service.detectedDevices, id: \.udid) { dev in
                                        Button(action: {
                                            onSelectDevice(dev.udid)
                                            showDevicePicker = false
                                        }) {
                                            HStack(spacing: 6) {
                                                Text(dev.isOffline ? "\(dev.name) (离线)" : "\(dev.name) (iOS \(dev.osVersion))")
                                                    .foregroundColor(dev.isOffline ? .secondary : nil)
                                                    .lineLimit(1)
                                                Spacer()
                                                if dev.udid == service.selectedDeviceUdid {
                                                    Image(systemName: "checkmark")
                                                        .font(.system(size: TBFont.button))
                                                        .foregroundColor(.dsAccent)
                                                }
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .frame(width: 200)
                    }
                }
            } else {
                HStack(spacing: 5) {
                    StatusDot(color: hasDevice ? .dsSuccess : .dsError, size: 5)
                    Text(deviceName)
                        .font(.system(size: TBFont.label, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: 100, alignment: .leading)
                }
            }

            if hasDetectedDevices, service.selectedDeviceUdid != nil {
                if hasDevice {
                    Button(action: { service.disconnectDevice() }) {
                        Text("断开")
                            .font(.system(size: TBFont.button, weight: .semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.dsError.opacity(0.12))
                            .foregroundColor(.dsError)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
                    .fixedSize()
                    .buttonStyle(.plain)
                    .help("断开设备连接")
                } else if service.isConnecting {
                    ProgressView()
                        .scaleEffect(0.45)
                        .frame(width: 32)
                } else {
                    Button(action: { Task { await service.connectToDevice() } }) {
                        Text("连接")
                            .font(.system(size: TBFont.button, weight: .semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.dsAccent)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
                    .fixedSize()
                    .buttonStyle(.plain)
                    .help("连接设备")
                }
            }

            if isRefreshing {
                ProgressView()
                    .scaleEffect(0.45)
                    .frame(width: 22, height: 22)
            } else {
                Button(action: onRefreshDevice) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: TBFont.icon, weight: .medium))
                }
                .buttonStyle(.iconButton(size: 26))
                .help("刷新设备")
            }
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
        .disabled(modeLocked)
        .fixedSize()
    }

    // MARK: - Mode Tip

    private var modeTipButton: some View {
        Button {
            showModeTip = true
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: TBFont.micro))
                .foregroundColor(.secondary.opacity(0.6))
        }
        .buttonStyle(.plain)
        .help("当前模式使用说明")
        .popover(isPresented: $showModeTip, arrowEdge: .bottom) {
            modeTipContent
        }
    }

    @ViewBuilder
    private var modeTipContent: some View {
        if service.locationMode == .simple {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 22))
                        .foregroundColor(.dsAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("普通模式 (DVT)")
                            .font(.system(size: 13, weight: .semibold))
                        Text("通过 USB 利用 DVT 协议直接注入定位")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }

                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 8) {
                    stepRow(index: 1, text: "数据线连接 iPhone，确保已开启开发者模式")
                    stepRow(index: 2, text: "点击工具栏安装 pymobiledevice3（自动创建虚拟环境）")
                    stepRow(index: 3, text: "选择设备，地图选点后按 ⌘↵ 应用")
                }
            }
            .padding(16)
            .frame(width: 300)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.system(size: 22))
                        .foregroundColor(.dsAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("代理模式 (MITM)")
                            .font(.system(size: 13, weight: .semibold))
                        Text("通过 WiFi 代理劫持定位请求，无线操作")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }

                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 8) {
                    stepRow(index: 1, text: "iPhone 连接同个 WiFi，关闭 VPN，设置 WiFi 代理为 Mac IP + 端口")
                    stepRow(index: 2, text: "Safari 访问 http://Mac IP:端口 → 下载安装 CA 证书")
                    stepRow(index: 3, text: "iOS 设置 > 通用 > 关于 > 证书信任设置 → 启用证书")
                    stepRow(index: 4, text: "点启动代理，地图选点后按 ⌘↵ 应用")
                }
            }
            .padding(16)
            .frame(width: 320)
        }
    }

    private func stepRow(index: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index)")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 16, height: 16)
                .background(Color.dsAccent)
                .clipShape(Circle())
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modeLocked: Bool {
        service.toolState == .installing || service.toolState == .uninstalling
        || service.locationMode == .simple && service.device != nil
        || service.proxyState.isActive
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

    // MARK: - Connection

    @ViewBuilder
    private var connectionSection: some View {
        if service.locationMode == .simple {
            simpleModeSection
        } else {
            proxySection
        }
    }

    // MARK: - Simple Mode (pymobiledevice3 control)

    private var simpleModeSection: some View {
        HStack(spacing: 5) {
            StatusDot(color: pmd3StatusColor, size: 5)

            Text("pymobiledevice3")
                .font(.system(size: TBFont.label, weight: .medium))
                .foregroundColor(.primary)

            pmd3ActionButton
        }
    }

    private var pmd3Status: String {
        switch service.toolState {
        case .checking: return "检测中…"
        case .present: return "已就绪"
        case .missing: return "未安装"
        case .installing: return "安装中…"
        case .uninstalling: return "卸载中…"
        }
    }

    private var pmd3StatusColor: Color {
        switch service.toolState {
        case .checking: return .secondary
        case .present: return .dsSuccess
        case .missing: return .dsError
        case .installing: return .dsWarning
        case .uninstalling: return .dsWarning
        }
    }

    @ViewBuilder
    private var pmd3ActionButton: some View {
        switch service.toolState {
        case .missing:
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
        case .installing, .uninstalling:
            ProgressView()
                .scaleEffect(0.4)
                .frame(width: 32)
        case .present:
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
        default:
            EmptyView()
        }
    }

    // MARK: - Proxy

    private var proxySection: some View {
        HStack(spacing: 5) {
            StatusDot(color: proxyColor, size: 5)

            Text("代理")
                .font(.system(size: TBFont.label, weight: .medium))
                .foregroundColor(.primary)

            proxyActionButton
        }
    }

    @ViewBuilder
    private var proxyActionButton: some View {
        switch service.proxyState {
        case .stopped:
            Button(action: { Task { await service.startProxy() } }) {
                Text("启动")
                    .font(.system(size: TBFont.button, weight: .semibold))
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
                    .font(.system(size: TBFont.button, weight: .semibold))
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
                    .font(.system(size: TBFont.button, weight: .semibold))
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
        HStack(spacing: 5) {
            StatusDot(color: statusDotColor, size: 6)

            Text(statusTitle)
                .font(.system(size: TBFont.label, weight: .medium))
                .foregroundColor(.primary)
        }
        .symbolEffect(.pulse, options: .repeating, isActive: isSimulating)
    }

    private var statusTitle: String {
        if isSimulating {
            let s = service
            return "GPS  \(s.activeLat.coordinateString), \(s.activeLng.coordinateString)"
        }
        return "GPS"
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

    private var statusSubtitleColor: Color {
        if isSimulating { return .dsSuccess }
        if service.locationMode == .proxy {
            if case .running = service.proxyState { return .dsWarning }
            if case .failed = service.proxyState { return .dsError }
        }
        return .secondary
    }

    private var statusDotColor: Color {
        if isSimulating { return .dsSuccess }
        if service.locationMode == .proxy {
            if case .running = service.proxyState { return .dsSuccess }
            if case .failed = service.proxyState { return .dsError }
            if case .starting = service.proxyState { return .dsWarning }
        }
        return .secondary
    }

    // MARK: - Settings

    private var settingsButton: some View {
        Button(action: { showSettings = true }) {
            Image(systemName: "gearshape")
                .font(.system(size: TBFont.icon))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.iconButton(size: 28))
        .help("设置")
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        HStack(spacing: 5) {
            switch service.locationState {
            case .active:
                    Button(action: { Task { await service.clearLocation() } }) {
                        Label("恢复", systemImage: "arrow.counterclockwise")
                            .font(.system(size: TBFont.button, weight: .semibold))
                    }
                    .buttonStyle(.glass(tint: .dsError, prominent: true))
                    .controlSize(.regular)
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
