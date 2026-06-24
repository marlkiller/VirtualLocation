import SwiftUI

struct LogDrawerView: View {
    @ObservedObject var service: LocationService
    @Binding var isExpanded: Bool

    private var logCount: Int { service.logs.count }
    private var lastLog: String {
        service.logs.last?.message ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            dragHandle

            if isExpanded {
                expandedContent
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .nativeGlass(material: .popover, blendingMode: .withinWindow)
        .clipShape(
            RoundedRectangle(
                cornerRadius: DS.Corner.panel,
                style: .continuous
            )
        )
        .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: -4)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Corner.panel, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)
                .offset(y: 0)
        }
        .animation(DS.Animation.logDrawer, value: isExpanded)
    }

    private var dragHandle: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color.primary.opacity(0.25))
                .frame(width: 36, height: 4)

            Spacer()

            if !isExpanded {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)

                    Text("\(logCount) 条日志")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)

                    if logCount > 0 {
                        Text(lastLog)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                .transition(.opacity)
            }

            Spacer()

            Button {
                withAnimation(DS.Animation.logDrawer) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "折叠日志" : "展开日志")
        }
        .padding(.horizontal, DS.Spacing.panelPadding)
        .frame(height: DS.Panel.logBarCollapsed)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(DS.Animation.logDrawer) {
                isExpanded.toggle()
            }
        }
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, DS.Spacing.panelPadding)
                .padding(.bottom, 6)

            logContent
        }
        .frame(height: DS.Panel.logBarExpanded)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("实时日志")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            Spacer()

            logLevelLegend

            Spacer()

            Button {
                let logText = service.logs.map(\.formatted).joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(logText, forType: .string)
                service.status = AppStatus.info("日志已复制到剪贴板")
            } label: {
                Label("复制", systemImage: "doc.on.doc")
                    .font(.system(size: 10))
            }
            .buttonStyle(.glass(tint: .dsAccent, prominent: false))
            .help("复制所有日志")

            Button {
                service.logs.removeAll()
            } label: {
                Label("清空", systemImage: "trash")
                    .font(.system(size: 10))
            }
            .buttonStyle(.glass(tint: .dsError, prominent: false))
            .help("清空日志")
        }
    }

    private var logLevelLegend: some View {
        HStack(spacing: 10) {
            legendDot(color: .blue, label: "命令")
            legendDot(color: .primary, label: "输出")
            legendDot(color: .red, label: "错误")
            legendDot(color: .secondary, label: "信息")
        }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 4, height: 4)
            Text(label)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
        }
    }

    private var logContent: some View {
        LogTextView(logs: service.logs)
            .clipShape(RoundedRectangle(cornerRadius: DS.Corner.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Corner.small, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
            .padding(.horizontal, DS.Spacing.panelPadding)
            .padding(.bottom, DS.Spacing.panelPadding)
    }
}
