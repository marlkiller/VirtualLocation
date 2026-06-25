import SwiftUI
import MapKit

struct ContentView: View {
    @StateObject private var service = LocationService()
    @State private var isLogExpanded = true
    @State private var isLogVisible = true
    @State private var searchText = ""
    @State private var mapType: MKMapType = .standard
    @State private var showSearchPanel = true
    @State private var zoomInCounter = 0
    @State private var zoomOutCounter = 0

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
                onToggleSearchPanel: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.95)) {
                        showSearchPanel.toggle()
                    }
                }
            )

            HStack(spacing: 0) {
                if showSearchPanel {
                    sidebar
                        .transition(.move(edge: .leading))
                }

                ZStack {
                    mapLayer

                    // Control panel — top
                    if hasSelection {
                        VStack {
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
                                }
                            )
                            Spacer()
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .id(service.mapSelection.selectedCoordinate.map { "\($0.latitude)-\($0.longitude)" } ?? "none")
                    }

                    // Log — bottom
                    if isLogVisible {
                        GeometryReader { geo in
                            VStack {
                                Spacer()
                                HStack {
                                    Spacer()
                                    LogDrawerView(
                                        service: service,
                                        isExpanded: $isLogExpanded,
                                        isVisible: $isLogVisible
                                    )
                                    .frame(maxWidth: .infinity)
                                    Spacer()
                                }
                                .frame(width: max(geo.size.width * 0.7, 400))
                                .padding(.bottom, 8)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // Show log button
                    if !isLogVisible {
                        VStack {
                            Spacer()
                            HStack {
                                Button(action: { withAnimation { isLogVisible = true } }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "doc.text")
                                            .font(.system(size: 9))
                                        Text("显示日志")
                                            .font(.system(size: 10, weight: .medium))
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.ultraThinMaterial)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                                .padding(.leading, DS.Spacing.panelMargin)
                                .padding(.bottom, 8)
                                Spacer()
                            }
                        }
                    }

                    // Map controls — bottom-right (on top of log)
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
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
                            .padding(.bottom, 12)
                        }
                    }
                }
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
        .onReceive(service.$locationState) { state in
            if case .active(let lat, let lng) = state {
                service.mapSelection.activeCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            }
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
            onCoordinateTapped: { _, _ in },
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

}
