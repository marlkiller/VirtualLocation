import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    private let projectURL = "https://github.com/marlkiller/VirtualLocation"

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("设置")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("项目地址")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)

                HStack {
                    Image(systemName: "link")
                        .font(.system(size: 12))
                        .foregroundColor(.dsAccent)

                    Text(projectURL)
                        .font(.system(size: 12))
                        .foregroundColor(.dsAccent)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer()

                    Button(action: {
                        if let url = URL(string: projectURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .help("在浏览器中打开")

                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(projectURL, forType: .string)
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .help("复制链接")
                }
                .padding(10)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 520, height: 180)
    }
}
