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
            ? "在地图上选择位置"
            : service.mapSelection.selectedPlaceName
    }
    private var coordinateText: String {
        let lat = service.mapSelection.selectedCoordinate?.latitude ?? service.activeLat
        let lng = service.mapSelection.selectedCoordinate?.longitude ?? service.activeLng
        return "\(lat.coordinateString), \(lng.coordinateString)"
    }

    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 10) {
                // Header row: icon + place name + proxy badge
                HStack(spacing: 10) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.dsAccent)

                    Text(placeName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .contentTransition(.interpolate)

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

                    if isSimulating {
                        HStack(spacing: 4) {
                            Image(systemName: "location.fill")
                                .font(.system(size: 8))
                                .foregroundColor(.dsSuccess)
                                .symbolEffect(.pulse, options: .repeating)
                            Text("模拟中")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.dsSuccess)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.dsSuccess.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }

                // Coordinate block: prominent, copyable
                HStack {
                    Image(systemName: "scope")
                        .font(.system(size: 11))
                        .foregroundColor(hasSelection ? .dsAccent : .secondary)
                    Text(coordinateText)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(hasSelection ? .primary : .secondary)
                        .lineLimit(1)
                        .contentTransition(.interpolate)
                    Spacer()
                    Button(action: onCopyCoordinates) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("复制坐标")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hasSelection ? Color.dsAccent.opacity(0.08) : Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(hasSelection ? Color.dsAccent.opacity(0.3) : Color.primary.opacity(0.08), lineWidth: 1)
                )

                // Action buttons row
                HStack(spacing: 8) {
                    barButton(icon: "bookmark", label: "收藏", action: onSaveToFavorites,
                              disabled: !hasSelection)
                    barButton(icon: "doc.on.doc", label: "复制", action: onCopyCoordinates,
                              disabled: !hasSelection && !isSimulating)

                    Spacer()

                    applyButton
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.regularMaterial)
                    if hasSelection {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.dsAccent.opacity(0.04))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(hasSelection ? Color.dsAccent.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .panelShadow(radius: DS.Shadow.float)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.95)))
        }
    }

    @State private var hoveredButton: String? = nil

    private func barButton(icon: String, label: String, action: @escaping () -> Void, disabled: Bool = false) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(hoveredButton == icon ? Color.primary.opacity(0.1) : Color.primary.opacity(0.06))
            .foregroundColor(disabled ? .secondary.opacity(0.3) : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .scaleEffect(hoveredButton == icon && !disabled ? 1.04 : 1)
            .animation(.easeInOut(duration: 0.15), value: hoveredButton)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering in
            hoveredButton = hovering ? icon : nil
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    @ViewBuilder
    private var applyButton: some View {
        switch service.locationState {
        case .setting:
            HStack(spacing: 5) {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 10, height: 10)
                Text("定位中…")
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.linearGradient(colors: [.dsAccent, .dsAccent.opacity(0.8)], startPoint: .top, endPoint: .bottom))
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .clearing:
            HStack(spacing: 5) {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 10, height: 10)
                Text("恢复中…")
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.linearGradient(colors: [.dsError, .dsError.opacity(0.8)], startPoint: .top, endPoint: .bottom))
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        default:
            Button(action: onApplyLocation) {
                HStack(spacing: 5) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 11))
                    Text(isSimulating ? "更新位置" : "应用位置")
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
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
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!hasSelection)
        }
    }
}
