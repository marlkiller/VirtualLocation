import SwiftUI
import MapKit

struct ContentView: View {
    @StateObject private var service = LocationService()
    @State private var isLogExpanded = true
    @State private var searchText = ""
    @State private var mapType: MKMapType = .standard
    @State private var showSettings = false
    @State private var showSearchPanel = true
    @State private var selectionScreenPoint: CGPoint?
    @State private var zoomInCounter = 0
    @State private var zoomOutCounter = 0
    @State private var mapSize: CGSize = .zero

    private var hasSelection: Bool {
        service.mapSelection.selectedCoordinate != nil || service.isSimulating
    }

    var body: some View {
        VStack(spacing: 0) {
            TopToolbarView(
                service: service,
                onStartSimulation: { Task { await service.setSelectedLocation() } },
                onStopSimulation: { Task { await service.clearLocation() } },
                onRefreshDevice: { Task { await service.refreshDevices() } },
                onStartTunnel: { Task { await service.startTunneld() } },
                onStopTunnel: { Task { await service.stopTunneld() } },
                onOpenSettings: { showSettings = true },
                onToggleSearchPanel: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.95)) {
                        showSearchPanel.toggle()
                    }
                }
            )

            ZStack(alignment: .bottom) {
                mapLayer
                    .background(
                        GeometryReader { geo in
                            Color.clear.onAppear { mapSize = geo.size }
                        }
                    )

                // Control panel — follows tapped coordinate, or top-center for search/favorites
                if hasSelection {
                    ControlPanelView(
                        service: service,
                        onApplyLocation: { Task { await service.setSelectedLocation() } },
                        onSaveToFavorites: {
                            guard let coord = service.mapSelection.selectedCoordinate else { return }
                            let name = service.mapSelection.selectedPlaceName.isEmpty
                                ? String(format: "%.4f, %.4f", coord.latitude, coord.longitude)
                                : service.mapSelection.selectedPlaceName
                            service.addCustomPreset(name: name, lat: coord.latitude, lng: coord.longitude)
                        },
                        onCopyCoordinates: {
                            let lat = service.mapSelection.selectedCoordinate?.latitude ?? service.activeLat
                            let lng = service.mapSelection.selectedCoordinate?.longitude ?? service.activeLng
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(lat.coordinateString), \(lng.coordinateString)", forType: .string)
                            service.status = AppStatus.info("坐标已复制: \(lat.coordinateString), \(lng.coordinateString)")
                        },
                        onCenterMap: {
                            if let coord = service.mapSelection.selectedCoordinate {
                                service.mapSelection.centerCoordinate = coord
                            }
                        }
                    )
                    .position(
                        x: (selectionScreenPoint?.x ?? mapSize.width * 2 / 3) + 140,
                        y: selectionScreenPoint?.y ?? 120
                    )
                    .transition(.opacity)
                    .id(service.mapSelection.selectedCoordinate.map { "\($0.latitude)-\($0.longitude)" } ?? "none")
                }

                HStack(spacing: 0) {
                    if showSearchPanel {
                        sidebar
                            .transition(.move(edge: .leading))
                    }

                    ZStack(alignment: .bottomTrailing) {
                        Color.clear

                        MapControlsView(
                            mapType: $mapType,
                            isSimulating: service.isSimulating,
                            onZoomIn: { zoomInCounter += 1 },
                            onZoomOut: { zoomOutCounter += 1 },
                            onCenterOnLocation: {
                                if let coord = service.mapSelection.activeCoordinate ?? service.mapSelection.selectedCoordinate {
                                    service.mapSelection.centerCoordinate = coord
                                }
                            },
                            onClearLocation: { Task { await service.clearLocation() } }
                        )
                        .padding(.trailing, DS.Spacing.panelMargin)
                        .padding(.bottom, DS.Panel.logBarCollapsed + DS.Panel.logBarExpanded + 30)
                    }
                }

                HStack {
                    Spacer()
                    LogDrawerView(
                        service: service,
                        isExpanded: $isLogExpanded
                    )
                    .frame(maxWidth: 520)
                    Spacer()
                }
                .padding(.bottom, 8)
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier("public.file-url") }) {
                    provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                        if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil), url.pathExtension.lowercased() == "gpx" {
                            Task { @MainActor in await service.loadGPX(from: url) }
                        }
                    }
                    return true
                }
                return false
            }
        }
        .ignoresSafeArea()
        .task { await initializeApp() }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            showSettings = true
        }
        .onReceive(service.$locationState) { state in
            if case .active(let lat, let lng) = state {
                service.mapSelection.activeCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            }
        }
        .sheet(isPresented: $showSettings) {
            settingsSheet
        }
        .background(
            Group {
                Button("") { Task { await service.setSelectedLocation() } }
                    .keyboardShortcut(.return, modifiers: .command)
                Button("") { 
                    if let coord = service.mapSelection.selectedCoordinate ?? service.mapSelection.activeCoordinate {
                        service.mapSelection.centerCoordinate = coord
                    }
                }
                .keyboardShortcut(.space, modifiers: [])
                
                Button("") { fineTuneLocation(latOffset: 0.0001, lngOffset: 0) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button("") { fineTuneLocation(latOffset: -0.0001, lngOffset: 0) }
                    .keyboardShortcut(.downArrow, modifiers: [])
                Button("") { fineTuneLocation(latOffset: 0, lngOffset: -0.0001) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { fineTuneLocation(latOffset: 0, lngOffset: 0.0001) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .opacity(0)
        )
    }

    private func fineTuneLocation(latOffset: Double, lngOffset: Double) {
        let baseCoord = service.mapSelection.selectedCoordinate ?? service.mapSelection.activeCoordinate
        guard let current = baseCoord else { return }
        let newCoord = CLLocationCoordinate2D(latitude: current.latitude + latOffset, longitude: current.longitude + lngOffset)
        service.selectCoordinate(newCoord)
        service.mapSelection.centerCoordinate = newCoord
        
        // If simulating and no selection, immediately apply to simulate continuous movement
        if service.isSimulating && service.mapSelection.selectedCoordinate == nil {
            if service.locationMode == .proxy {
                Task { await service.applyProxyLocation(lat: newCoord.latitude, lng: newCoord.longitude) }
            } else {
                Task { await service.setLocation(lat: newCoord.latitude, lng: newCoord.longitude) }
            }
        }
    }

    private func initializeApp() async {
        service.addLog(.info, "Virtual Location 启动")
        await service.checkTool()
        await service.refreshDevices()
        if service.locationMode == .proxy && service.proxySettings.autoStart {
            await service.startProxy()
        }
    }

    // MARK: - Map

    private var mapLayer: some View {
        MapView(
            selectedCoordinate: Binding(
                get: { service.mapSelection.selectedCoordinate },
                set: { newValue in
                    service.mapSelection.selectedCoordinate = newValue
                    if let coord = newValue {
                        service.selectCoordinate(coord)
                    }
                }
            ),
            presets: service.allPresets,
            activeCoordinate: service.mapSelection.activeCoordinate,
            centerCoordinate: service.mapSelection.centerCoordinate,
            mapType: mapType,
            showPresets: true,
            onDeletePreset: { preset in
                if let idx = service.customPresets.firstIndex(where: { $0.id == preset.id }) {
                    service.removeCustomPreset(at: idx)
                }
            },
            onCoordinateChanged: { coord in
                service.selectCoordinate(coord)
            },
            onCoordinateTapped: { _, point in
                selectionScreenPoint = point
            },
            zoomInCounter: $zoomInCounter,
            zoomOutCounter: $zoomOutCounter
        )
        .edgesIgnoringSafeArea([.leading, .trailing, .bottom])
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        HStack(spacing: 0) {
            SearchPanelView(
                service: service,
                searchText: $searchText,
                onSearch: { query in
                    Task { await service.searchLocation(query: query) }
                },
                onSelectCoordinate: { coord, name in
                    service.mapSelection.selectedCoordinate = coord
                    service.mapSelection.selectedPlaceName = name
                    service.mapSelection.centerCoordinate = coord
                },
                onSelectPreset: { preset in
                    service.mapSelection.selectedCoordinate = preset.coordinate
                    service.mapSelection.selectedPlaceName = preset.name
                    service.mapSelection.centerCoordinate = preset.coordinate
                }
            )

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
        }
    }

    // MARK: - Settings Sheet

    private var settingsSheet: some View {
        Form {
            Section {
                switch service.toolState {
                case .checking:
                    HStack {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 16)
                        Text("检测 pymobiledevice3…")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                case .missing:
                    LabeledContent {
                        Button("安装") { Task { await service.installDependencies() } }
                            .buttonStyle(.glass(tint: .dsAccent, prominent: true))
                            .disabled(service.toolState == .installing)
                    } label: {
                        Label("pymobiledevice3", systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.dsWarning)
                    }
                case .present:
                    LabeledContent {
                        Text("已就绪")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.dsSuccess)
                    } label: {
                        Label("pymobiledevice3", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.dsSuccess)
                    }
                case .installing:
                    HStack {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 16)
                        Text("安装中… (约 1-2 分钟)")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Label("依赖", systemImage: "cube.transparent")
            }

            Section {
                if let dev = service.device {
                    LabeledContent {
                        Text(dev.id)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    } label: {
                        Label(dev.name, systemImage: "iphone")
                    }

                    if !dev.osVersion.isEmpty {
                        LabeledContent {
                            Text(dev.osVersion)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        } label: {
                            Label("系统版本", systemImage: "gear")
                        }
                    }
                } else {
                    LabeledContent {
                        Text("未检测到")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    } label: {
                        Label("当前设备", systemImage: "iphone.slash")
                            .foregroundColor(.secondary)
                    }
                }

            } header: {
                Label("设备", systemImage: "iphone.gen3")
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 260)
    }
}
