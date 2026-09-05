import SwiftUI

/// 代理模式操作提醒：每次修改位置后，iPhone 需开关定位服务并重新打开目标 App 才会生效。
/// 显隐由 ContentView 控制（代理运行中且未被关闭时显示）。
struct ProxyTipBanner: View {
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(.dsWarning)

            (Text("每次修改位置后，需在 iPhone 上 ")
                + Text("开关定位服务 → 重新打开目标 App").fontWeight(.semibold)
                + Text(" 才会生效"))
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("隐藏此提示")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.dsWarning.opacity(0.1))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.dsWarning.opacity(0.45), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .panelShadow(radius: DS.Shadow.float)
    }
}
