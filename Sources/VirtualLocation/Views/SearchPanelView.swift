import SwiftUI
import MapKit

struct SearchPanelView: View {
    @ObservedObject var service: LocationService
    @Binding var searchText: String
    var onSearch: (String) -> Void
    var onSelectCoordinate: (CLLocationCoordinate2D, String) -> Void
    var onSelectPreset: (LocationPreset) -> Void

    @State private var selectedTab: SearchTab = .search
    @FocusState private var isSearchFocused: Bool

    enum SearchTab: String, CaseIterable {
        case search = "magnifyingglass"
        case favorites = "star"
        case history = "clock.arrow.circlepath"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchHeader
                .padding(.horizontal, DS.Spacing.panelPadding)
                .padding(.top, 12)

            tabBar
                .padding(.top, 10)
                .padding(.horizontal, DS.Spacing.panelPadding)

            sidebarDivider
                .padding(.top, 8)

            contentArea
        }
        .frame(width: DS.Panel.width)
        .nativeGlass(material: .sidebar, blendingMode: .behindWindow)
        .background(
            Button("") { isSearchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
        )
    }

    private var sidebarDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "location.magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.dsAccent)

                Text("地点")
                    .font(.system(size: 12, weight: .semibold))
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.secondary)

                TextField("搜索地址、地点、经纬度", text: $searchText)
                    .focused($isSearchFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit {
                        guard !searchText.isEmpty else { return }
                        onSearch(searchText)
                    }

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        service.mapSelection.searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: DS.Corner.button, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Corner.button, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )

            if service.mapSelection.isSearching {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(SearchTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedTab = tab
                    }
                } label: {
                    Image(systemName: tab.rawValue)
                        .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .regular))
                        .foregroundColor(selectedTab == tab ? .dsAccent : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            selectedTab == tab
                                ? Color.dsAccent.opacity(0.1)
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    @ViewBuilder
    private var contentArea: some View {
        switch selectedTab {
        case .search:
            searchResultsList
        case .favorites:
            favoritesList
        case .history:
            searchHistoryList
        }
    }

    @ViewBuilder
    private var searchResultsList: some View {
        if service.mapSelection.searchResults.isEmpty && !service.mapSelection.isSearching {
            resultsPlaceholder
        } else {
            List(service.mapSelection.searchResults, id: \.self) { item in
                searchResultRow(item)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollIndicators(.automatic)
            .padding(.top, 4)
        }
    }

    private var resultsPlaceholder: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "map")
                .font(.system(size: 22))
                .foregroundColor(.secondary.opacity(0.4))
            Text("搜索地点或在地图上点击选择")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func searchResultRow(_ item: MKMapItem) -> some View {
        Button {
            if let coord = item.placemark.location?.coordinate {
                onSelectCoordinate(coord, item.name ?? "未知地点")
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name ?? "未知地点")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(item.placemark.title ?? "")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                if let coord = item.placemark.location?.coordinate {
                    Text(String(format: "%.6f, %.6f", coord.latitude, coord.longitude))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }
            .padding(.horizontal, DS.Spacing.panelPadding)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: DS.Corner.small, style: .continuous))
        }
        .buttonStyle(SidebarRowButtonStyle())
        .padding(.horizontal, DS.Spacing.panelPadding)
        .padding(.vertical, 2)
    }

    private var favoritesList: some View {
        Group {
            if service.allPresets.isEmpty {
                emptyState("暂无收藏地点")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(service.allPresets) { preset in
                            presetRow(preset)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.automatic)
            }
        }
    }

    private func presetRow(_ preset: LocationPreset) -> some View {
        Button {
            onSelectPreset(preset)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.dsAccent)

                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    Text("\(preset.landmark) · \(preset.region)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(preset.coordinateString)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.7))
                }

                Spacer()

                if isCustomPreset(preset) {
                    Button {
                        deletePreset(preset)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help("删除收藏")
                    .opacity(0.6)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.3))
                }
            }
            .padding(.horizontal, DS.Spacing.panelPadding)
            .padding(.vertical, 8)
        }
        .buttonStyle(SidebarRowButtonStyle())
        .contextMenu {
            if isCustomPreset(preset) {
                Button {
                    deletePreset(preset)
                } label: {
                    Label("删除收藏", systemImage: "trash")
                }
            }
        }
    }

    private func isCustomPreset(_ preset: LocationPreset) -> Bool {
        !LocationPreset.builtin.contains(where: { $0.id == preset.id })
    }

    private func deletePreset(_ preset: LocationPreset) {
        if let idx = service.customPresets.firstIndex(where: { $0.id == preset.id }) {
            service.removeCustomPreset(at: idx)
        }
    }

    private var searchHistoryList: some View {
        Group {
            if service.searchHistory.isEmpty {
                emptyState("暂无搜索历史")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(service.searchHistory) { item in
                            historyRow(item)
                        }
                    }
                    .padding(.vertical, 4)

                    Button {
                        service.clearSearchHistory()
                    } label: {
                        Text("清除历史")
                            .font(.system(size: 11))
                            .foregroundColor(.dsError)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.automatic)
            }
        }
    }

    private func historyRow(_ item: SearchHistoryItem) -> some View {
        Button {
            let coord = CLLocationCoordinate2D(latitude: item.latitude, longitude: item.longitude)
            onSelectCoordinate(coord, item.query)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "clock")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.query)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    Text(item.coordinateString)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.7))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(.horizontal, DS.Spacing.panelPadding)
            .padding(.vertical, 8)
        }
        .buttonStyle(SidebarRowButtonStyle())
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "star.slash")
                .font(.system(size: 18))
                .foregroundColor(.secondary.opacity(0.4))
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct SidebarRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SidebarRowButton(configuration: configuration)
    }
}

private struct SidebarRowButton: View {
    let configuration: ButtonStyle.Configuration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: DS.Corner.small, style: .continuous)
                    .fill(configuration.isPressed
                          ? Color.dsAccent.opacity(0.18)
                          : isHovered
                          ? Color.primary.opacity(0.06)
                          : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Corner.small, style: .continuous)
                    .stroke(Color.primary.opacity(configuration.isPressed ? 0.08 : 0), lineWidth: 0.5)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}
