import SwiftUI

struct ContentView: View {
    @StateObject private var locSvc = LocationService()
    @State private var customLat = "39.9042"
    @State private var customLng = "116.3974"
    @State private var showManualUdid = false

    private var busy: Bool { locSvc.status.message.contains("正在") }
    private var toolReady: Bool { if case .present = locSvc.toolState { true } else { false } }
    private var tunnelReady: Bool { if case .connected = locSvc.tunnelState { true } else { false } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        toolSection
                        deviceSection
                        tunnelSection
                        presetsSection
                        customSection
                    clearSection
                    statusSection
                    manualUdidSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }

                Divider()
                logSection
            }
        }
        .frame(width: 580, height: 820)
        .task { await onAppear() }
    }

    private func onAppear() async {
        locSvc.addLog(.info, "App 启动")
        await locSvc.checkTool()
        await locSvc.refreshDevices()
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "location.circle.fill").foregroundColor(.accentColor).imageScale(.large)
            Text("虚拟定位").font(.title2.weight(.semibold))
            Spacer()
            if case .installing = locSvc.toolState {
                ProgressView().scaleEffect(0.8).padding(.trailing, 4)
            }
            Button("刷新") { Task { await refreshAll() } }
                .buttonStyle(.borderless).controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func refreshAll() async {
        await locSvc.checkTool()
        await locSvc.refreshDevices()
    }

    // MARK: - Tool

    private var toolSection: some View {
        GroupBox("① 安装依赖") {
            HStack {
                switch locSvc.toolState {
                case .checking:
                    ProgressView().scaleEffect(0.7).padding(.trailing, 4)
                    Text("检测中 …").foregroundColor(.secondary)
                case .missing:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text("pymobiledevice3 未安装").foregroundColor(.secondary)
                    Spacer()
                    Button("一键安装") { Task { await locSvc.installDependencies() } }
                        .buttonStyle(.borderedProminent).controlSize(.small).disabled(busy)
                case .present:
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("pymobiledevice3 已就绪").font(.body).foregroundColor(.secondary)
                case .installing:
                    ProgressView().scaleEffect(0.7).padding(.trailing, 4)
                    Text("安装中 …").foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Device

    private var deviceSection: some View {
        GroupBox("② 连接设备") {
            HStack {
                if let d = locSvc.device {
                    Image(systemName: "iphone.gen3").foregroundColor(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(d.shortName).fontWeight(.medium)
                        Text("UDID: \(d.id)").font(.caption2.monospaced()).foregroundColor(.secondary)
                        Text("iOS \(d.osVersion)").font(.caption2).foregroundColor(.secondary)
                    }
                } else {
                    Image(systemName: "iphone.slash").foregroundColor(.red)
                    Text("未检测到设备（USB 连接并信任后点刷新）").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("刷新") { Task { await locSvc.refreshDevices() } }
                    .buttonStyle(.borderless).controlSize(.small).disabled(busy)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Tunnel

    private var tunnelSection: some View {
        GroupBox("③ 启动隧道") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    switch locSvc.tunnelState {
                    case .disconnected:
                        Image(systemName: "cable.connector.slash").foregroundColor(.red)
                        Text("未连接").foregroundColor(.secondary)
                    case .starting:
                        ProgressView().scaleEffect(0.7).padding(.trailing, 4)
                        Text("正在启动 …").foregroundColor(.secondary)
                    case .connected:
                        Image(systemName: "cable.connector").foregroundColor(.green)
                        Text("Tunneld 已连接").font(.body)
                    case .failed(let msg):
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        Text(msg).font(.caption).foregroundColor(.orange).lineLimit(2)
                    }
                    Spacer()

                    switch locSvc.tunnelState {
                    case .disconnected, .failed:
                        Button("🔌 启动 Tunneld") { Task { await locSvc.startTunneld() } }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .disabled(!toolReady || locSvc.device == nil || busy)
                    case .starting:
                        EmptyView()
                    case .connected:
                        Button("断开") { Task { await locSvc.stopTunneld() } }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }

                if case .disconnected = locSvc.tunnelState, toolReady, locSvc.device != nil {
                    Text("点击启动 → 弹窗输入 Mac 密码 → 后台持久运行")
                        .font(.caption).foregroundColor(Color(nsColor: .tertiaryLabelColor))
                }
                if case .failed = locSvc.tunnelState {
                    Text("提示：可在终端先杀掉旧进程再试").font(.caption).foregroundColor(.secondary)
                    HStack {
                        Image(systemName: "terminal").foregroundColor(.secondary)
                        Text("sudo pkill -f tunneld")
                            .font(.caption2.monospaced()).textSelection(.enabled)
                    }
                    .padding(6).background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Presets

    private var presetsSection: some View {
        GroupBox("④ 选择景点定位") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(LocationPreset.presets) { preset in
                    presetCard(preset)
                }
            }
        }
        .opacity(locSvc.device == nil ? 0.5 : 1)
    }

    private func presetCard(_ preset: LocationPreset) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name).fontWeight(.medium)
                Text(preset.landmark).font(.caption).foregroundColor(.secondary)
                Text(preset.coordinateString).font(.caption2.monospaced()).foregroundColor(.secondary)
            }
            Spacer()
            Button("定位") { Task { await locSvc.setLocation(lat: preset.latitude, lng: preset.longitude) } }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(!toolReady || !tunnelReady || locSvc.device == nil || busy)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    // MARK: - Custom

    private var customSection: some View {
        GroupBox("自定义坐标") {
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("纬度").font(.caption).foregroundColor(.secondary)
                    TextField("纬度", text: $customLat).textFieldStyle(.roundedBorder).frame(width: 130).font(.body.monospaced())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("经度").font(.caption).foregroundColor(.secondary)
                    TextField("经度", text: $customLng).textFieldStyle(.roundedBorder).frame(width: 130).font(.body.monospaced())
                }
                Spacer()
                Button("设置") {
                    guard let lat = Double(customLat), let lng = Double(customLng) else {
                        locSvc.status = AppStatus.error("请输入有效坐标"); return
                    }
                    Task { await locSvc.setLocation(lat: lat, lng: lng) }
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(!toolReady || !tunnelReady || locSvc.device == nil || busy)
            }
            .padding(.vertical, 4)
        }
        .opacity(locSvc.device == nil ? 0.5 : 1)
    }

    // MARK: - Clear

    private var clearSection: some View {
        HStack {
            Button("🔄 恢复真实位置", role: .destructive) {
                Task { await locSvc.clearLocation() }
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(!tunnelReady || busy)

            if !toolReady && locSvc.device != nil {
                Text("请先完成第①步安装依赖").font(.caption).foregroundColor(.orange)
            } else if toolReady && !tunnelReady && locSvc.device != nil {
                Text("请先完成第③步启动隧道").font(.caption).foregroundColor(.orange)
            }
            Spacer()
        }
    }

    // MARK: - Manual UDID

    private var manualUdidSection: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $showManualUdid, content: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("在终端执行以下命令获取 UDID：").font(.caption).foregroundColor(.secondary)
                    HStack {
                        Image(systemName: "terminal").foregroundColor(.secondary)
                        Text("xcrun xctrace list devices").font(.body.monospaced()).textSelection(.enabled)
                    }
                    .padding(8).background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    HStack(spacing: 8) {
                        TextField("粘贴 UDID", text: $locSvc.manualUDID).textFieldStyle(.roundedBorder)
                            .font(.body.monospaced()).frame(maxWidth: .infinity)
                        Button("应用") {
                            locSvc.manualUDID = locSvc.manualUDID.trimmingCharacters(in: .whitespaces)
                            Task { await locSvc.refreshDevices() }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(locSvc.manualUDID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.top, 6)
            }, label: {
                Label("手动输入 UDID", systemImage: "rectangle.and.pencil.and.ellipsis")
                    .font(.caption).foregroundColor(.secondary)
            })
        }
    }

    // MARK: - Log

    private var logSection: some View {
        VStack(spacing: 0) {
            HStack {
                Label("运行日志", systemImage: "doc.text.magnifyingglass")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Text("\(locSvc.logs.count) 条")
                    .font(.caption2).foregroundColor(Color(nsColor: .tertiaryLabelColor))
                Button("清空") { locSvc.logs.removeAll() }
                    .buttonStyle(.borderless).controlSize(.mini)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)

            LogTextView(logs: locSvc.logs)
                .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 250)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Status

    private var statusSection: some View {
        HStack {
            Circle().fill(locSvc.status.isError ? Color.red : Color.green).frame(width: 8, height: 8)
            Text(locSvc.status.message).font(.callout)
                .foregroundColor(locSvc.status.isError ? .red : .secondary).textSelection(.enabled)
            Spacer()
        }
        .padding(10).background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
