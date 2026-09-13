import SwiftUI
import AppKit

/// 偏好设置窗口（由 `Settings` scene 承载，⌘, 打开）
///
/// 遵循 macOS HIG：顶部为系统提供的分页工具栏，每个分页固定尺寸、不可缩放。
struct SettingsView: View {
    @ObservedObject var service: LocationService

    var body: some View {
        TabView {
            GeneralSettingsPane(service: service)
                .tabItem { Label("通用", systemImage: "gearshape") }

            CertificateSettingsPane(service: service)
                .tabItem { Label("证书", systemImage: "checkmark.seal") }

            ProjectSettingsPane()
                .tabItem { Label("项目", systemImage: "info.circle") }
        }
    }
}

// MARK: - 通用

private struct GeneralSettingsPane: View {
    @ObservedObject var service: LocationService

    private var portBinding: Binding<Int> {
        Binding(
            get: { Int(service.proxySettings.port) },
            set: { service.proxySettings.port = UInt16(clamping: $0) }
        )
    }

    private var isProxyRunning: Bool { service.proxyState.isActive }

    var body: some View {
        Form {
            Section {
                LabeledContent("监听端口") {
                    HStack(spacing: 6) {
                        TextField("", value: portBinding, format: .number.grouping(.never))
                            .frame(width: 72)
                            .multilineTextAlignment(.trailing)
                        Stepper("", value: portBinding, in: 1024...65535)
                            .labelsHidden()
                    }
                    .disabled(isProxyRunning)
                }

                LabeledContent("本机地址") {
                    HStack(spacing: 6) {
                        Text(proxyAddressText)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                        Button {
                            copyToPasteboard(proxyAddressText)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("复制代理地址")
                    }
                }
            } header: {
                Text("代理")
            } footer: {
                Text(isProxyRunning
                     ? "代理正在运行，端口需停止后才能修改。"
                     : "端口范围 1024–65535，需与 iPhone WiFi 代理设置保持一致。")
            }

            Section {
                LabeledContent("配置目录") {
                    HStack(spacing: 6) {
                        Text(abbreviatedHome(CertificateManager.shared.storageDirectory.path))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("显示") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [CertificateManager.shared.storageDirectory]
                            )
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("存储")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 560)
    }

    private var proxyAddressText: String {
        guard let ip = service.localIPAddress else { return "未检测到网络接口" }
        return "\(ip):\(service.proxySettings.port)"
    }
}

// MARK: - 项目地址

private struct ProjectSettingsPane: View {
    private let projectURL = "https://github.com/marlkiller/VirtualLocation"

    var body: some View {
        Form {
            Section {
                LabeledContent("项目地址") {
                    HStack(spacing: 8) {
                        Text(projectURL)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dsAccent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)

                        Button {
                            if let url = URL(string: projectURL) {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .buttonStyle(.borderless)
                        .help("在浏览器中打开")

                        Button {
                            copyToPasteboard(projectURL)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("复制链接")
                    }
                }
            } header: {
                Text("开源")
            } footer: {
                Text("代理模式的实现参考了 proxypin-wloc-spoofer。")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 560)
    }
}

// MARK: - Shared Helpers

func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}

func abbreviatedHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    guard path.hasPrefix(home) else { return path }
    return "~" + path.dropFirst(home.count)
}
