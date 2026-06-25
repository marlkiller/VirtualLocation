import SwiftUI
import MapKit

struct ControlPanelView: View {
    @ObservedObject var service: LocationService
    var onApplyLocation: () -> Void
    var onSaveToFavorites: () -> Void
    var onCopyCoordinates: () -> Void

    private var isSimulating: Bool { service.isSimulating }
    private var hasSelection: Bool { service.mapSelection.selectedCoordinate != nil }
    private var placeName: String {
        if isSimulating {
            return service.mapSelection.selectedPlaceName.isEmpty
                ? "模拟位置"
                : service.mapSelection.selectedPlaceName
        }
        return service.mapSelection.selectedPlaceName.isEmpty
            ? "选定位置"
            : service.mapSelection.selectedPlaceName
    }
    private var coordinateText: String {
        let lat = service.mapSelection.selectedCoordinate?.latitude ?? service.activeLat
        let lng = service.mapSelection.selectedCoordinate?.longitude ?? service.activeLng
        return "\(lat.coordinateString), \(lng.coordinateString)"
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "location.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.dsAccent)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(placeName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text(coordinateText)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if service.locationMode == .proxy,
                   case .running = service.proxyState,
                   service.wlocPatchedCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.dsSuccess)
                        Text("已修补 \(service.wlocPatchedCount) 个")
                            .font(.system(size: 9))
                            .foregroundColor(.dsSuccess)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.dsSuccess.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                HStack(spacing: 4) {
                    barButton(icon: "bookmark", label: "收藏", action: onSaveToFavorites,
                              disabled: !hasSelection)
                    barButton(icon: "doc.on.doc", label: "复制", action: onCopyCoordinates,
                              disabled: !hasSelection && !isSimulating)
                    applyButton
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.dsAccent)
                    .frame(width: 3)
                    .padding(.leading, 12)
                    .padding(.vertical, 12)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.95)))
        }
    }

    private func barButton(icon: String, label: String, action: @escaping () -> Void, disabled: Bool = false) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06))
            .foregroundColor(disabled ? .secondary.opacity(0.3) : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    @ViewBuilder
    private var applyButton: some View {
        switch service.locationState {
        case .setting:
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.35)
                    .frame(width: 8, height: 8)
                Text("定位中…")
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.linearGradient(colors: [.dsAccent, .dsAccent.opacity(0.8)], startPoint: .top, endPoint: .bottom))
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .clearing:
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.35)
                    .frame(width: 8, height: 8)
                Text("恢复中…")
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.linearGradient(colors: [.dsError, .dsError.opacity(0.8)], startPoint: .top, endPoint: .bottom))
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        default:
            Button(action: onApplyLocation) {
                HStack(spacing: 4) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(isSimulating ? "更新" : "应用")
                        .font(.system(size: 10, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Group {
                        if !hasSelection {
                            Color.secondary.opacity(0.15)
                        } else {
                            LinearGradient(colors: [.dsAccent, .dsAccent.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                        }
                    }
                )
                .foregroundColor(!hasSelection ? .secondary.opacity(0.5) : .white)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!hasSelection)
        }
    }
}
