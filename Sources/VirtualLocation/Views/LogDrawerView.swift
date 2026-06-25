import SwiftUI

struct LogDrawerView: View {
    @ObservedObject var service: LocationService
    @Binding var isExpanded: Bool
    @Binding var isVisible: Bool

    private var logCount: Int { service.logs.count }

    var body: some View {
        VStack(spacing: 0) {
            header

            if isExpanded {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 1)

                VStack(spacing: 0) {
                    toolbar
                        .padding(.horizontal, 12)
                        .padding(.top, 6)

                    LogTextView(logs: service.logs)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                        )
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                        .padding(.top, 4)
                }
                .frame(height: 150)
            }
        }
        .frame(maxWidth: .infinity)
        .nativeGlass(material: .sidebar, blendingMode: .behindWindow)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.95), value: isExpanded)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.dsAccent)

            Text("日志")
                .font(.system(size: 11, weight: .semibold))

            Text("\(logCount) 条")
                .font(.system(size: 9))
                .foregroundColor(.secondary)

            Spacer()

            logLevelLegend
                .padding(.trailing, 4)

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.95)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "折叠" : "展开")

            Button {
                isVisible = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("隐藏日志")
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.95)) {
                isExpanded.toggle()
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Spacer()

            Button {
                let logText = service.logs.map(\.formatted).joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(logText, forType: .string)
                service.status = AppStatus.info("日志已复制到剪贴板")
            } label: {
                Label("复制", systemImage: "doc.on.doc")
                    .font(.system(size: 9))
            }
            .buttonStyle(.glass(tint: .dsAccent, prominent: false))

            Button {
                service.logs.removeAll()
            } label: {
                Label("清空", systemImage: "trash")
                    .font(.system(size: 9))
            }
            .buttonStyle(.glass(tint: .dsError, prominent: false))
        }
    }

    private var logLevelLegend: some View {
        HStack(spacing: 8) {
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
                .frame(width: 3, height: 3)
            Text(label)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
        }
    }
}
