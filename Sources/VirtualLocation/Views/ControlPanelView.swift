import SwiftUI
import MapKit

struct ControlPanelView: View {
    @ObservedObject var service: LocationService
    var onApplyLocation: () -> Void
    var onSaveToFavorites: () -> Void
    var onCopyCoordinates: () -> Void
    var onCenterMap: () -> Void

    private var isSimulating: Bool { service.isSimulating }
    private var hasSelection: Bool { service.mapSelection.selectedCoordinate != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            if hasSelection || isSimulating {
                PanelDivider()
                    .padding(.horizontal, 12)

                placeInfo
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                if service.locationMode == .proxy,
                   case .running(let port) = service.proxyState,
                   service.wlocPatchedCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 8))
                            .foregroundColor(.dsSuccess)
                        Text("代理已修补 \(service.wlocPatchedCount) 个位置")
                            .font(.system(size: 8))
                            .foregroundColor(.dsSuccess)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                }

                PanelDivider()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                actionButtonsSection
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .frame(width: 240)
        .nativeGlass(material: .popover, blendingMode: .withinWindow)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 4)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "location.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.dsAccent)

            Text("定位控制")
                .font(.system(size: 12, weight: .semibold))

            Spacer(minLength: 4)

            if hasSelection {
                Button(action: onCenterMap) {
                    Image(systemName: "arrow.up.forward.and.arrow.down.backward")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("居中到选定位置")
            }

            // Show current mode badge
            Text(service.locationMode.rawValue)
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(service.locationMode == .proxy ? .dsWarning : .dsAccent)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background((service.locationMode == .proxy ? Color.dsWarning : Color.dsAccent).opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }

    // MARK: - Place Info

    private var placeInfo: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isSimulating ? Color.dsSuccess : Color.dsWarning)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(placeName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(isSimulating
                     ? "\(service.activeLat.coordinateString), \(service.activeLng.coordinateString)"
                     : coordinateString)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }

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

    private var coordinateString: String {
        guard let coord = service.mapSelection.selectedCoordinate else { return "--, --" }
        return "\(coord.latitude.coordinateString), \(coord.longitude.coordinateString)"
    }

    // MARK: - Actions

    private var actionButtonsSection: some View {
        VStack(spacing: 6) {
            if service.locationMode == .proxy {
                if case .running = service.proxyState {
                    locationActionButton
                } else {
                    proxyNotReadyNotice
                }
            } else if case .connected = service.tunnelState {
                locationActionButton
            } else {
                tunnelRequiredNotice
            }

            HStack(spacing: 6) {
                tinyButton(icon: "bookmark", label: "收藏", action: onSaveToFavorites,
                           disabled: !hasSelection)
                tinyButton(icon: "doc.on.doc", label: "复制", action: onCopyCoordinates,
                           disabled: !hasSelection && !isSimulating)

                if service.locationMode == .simple {
                    Button(action: { service.enableJittering.toggle() }) {
                        HStack(spacing: 3) {
                            Image(systemName: "cellularbars")
                                .font(.system(size: 9))
                            Text("防检测")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(service.enableJittering ? Color.dsSuccess.opacity(0.15) : Color.primary.opacity(0.06))
                        .foregroundColor(service.enableJittering ? .dsSuccess : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("开启随机抖动以防止应用检测")
                }
            }
        }
    }

    private var locationActionButton: some View {
        Group {
            switch service.locationState {
            case .setting:
                loadingBadge(text: "定位中…", color: .dsAccent)
            case .clearing:
                loadingBadge(text: "恢复中…", color: .dsError)
            default:
                Button(action: onApplyLocation) {
                    HStack(spacing: 5) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 10))
                        Text(isSimulating ? "更新定位" : "应用定位")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(!hasSelection ? Color.secondary.opacity(0.2) : Color.dsAccent)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!hasSelection)
            }
        }
    }

    private var tunnelRequiredNotice: some View {
        HStack(spacing: 5) {
            Image(systemName: "lightbulb")
                .font(.system(size: 9))
            Text("需要 Tunneld")
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(.dsWarning)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.dsWarning.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var proxyNotReadyNotice: some View {
        HStack(spacing: 5) {
            Image(systemName: "network.slash")
                .font(.system(size: 9))
            Text("代理未就绪")
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func loadingBadge(text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 10, height: 10)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(color)
        .foregroundColor(.white)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func tinyButton(icon: String, label: String, action: @escaping () -> Void, disabled: Bool) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                Text(label)
                    .font(.system(size: 9, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }
}
