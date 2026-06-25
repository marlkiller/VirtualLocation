import SwiftUI
import MapKit

struct MapControlsView: View {
    @Binding var mapType: MKMapType
    var onZoomIn: () -> Void
    var onZoomOut: () -> Void
    var onCenterOnLocation: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            mapControlButton(icon: "plus", action: onZoomIn)
            panelDividerShort
            mapControlButton(icon: "minus", action: onZoomOut)
            panelDividerShort
            mapControlButton(icon: "location", action: onCenterOnLocation)
            panelDividerShort
            mapControlButton(icon: mapTypeIcon, action: toggleMapType)
        }
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.Corner.pill, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
    }

    private var mapTypeIcon: String {
        switch mapType {
        case .satellite, .satelliteFlyover: return "globe"
        case .hybrid, .hybridFlyover: return "map"
        default: return "map"
        }
    }

    private var panelDividerShort: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 20, height: 0.5)
            .padding(.vertical, 2)
    }

    private func mapControlButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary)
                .frame(width: DS.Panel.mapControlSize, height: DS.Panel.mapControlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(controlHelp(icon))
    }

    private func toggleMapType() {
        switch mapType {
        case .standard: mapType = .satellite
        case .satellite: mapType = .hybrid
        case .hybrid: mapType = .standard
        default: mapType = .standard
        }
    }

    private func controlHelp(_ icon: String) -> String {
        switch icon {
        case "plus": return "放大地图"
        case "minus": return "缩小地图"
        case "location": return "回到当前位置"
        case "map", "globe": return "切换地图类型"
        default: return ""
        }
    }
}
