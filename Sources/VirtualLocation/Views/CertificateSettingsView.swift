import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - View Model

@MainActor
final class CertificateViewModel: ObservableObject {

    struct Banner: Equatable {
        enum Kind: Equatable {
            case success, failure, info

            var icon: String {
                switch self {
                case .success: return "checkmark.circle.fill"
                case .failure: return "exclamationmark.triangle.fill"
                case .info:    return "info.circle.fill"
                }
            }

            var color: Color {
                switch self {
                case .success: return .dsSuccess
                case .failure: return .dsError
                case .info:    return .dsAccent
                }
            }
        }

        var kind: Kind
        var text: String
    }

    @Published private(set) var info: CACertificateInfo?
    @Published private(set) var isBusy = false
    @Published var banner: Banner?
    @Published var isConfirmingRegenerate = false

    private let manager = CertificateManager.shared

    // MARK: - Loading

    func reload() {
        do {
            let cert = try manager.currentCACertificate()
            info = manager.info(for: cert)
        } catch {
            info = nil
        }
    }

    /// 首次出现时加载（可能触发 CA 生成，放到后台线程）
    func loadInitial() {
        guard !isBusy else { return }
        isBusy = true
        Task {
            _ = await runOffMain { _ = try self.manager.currentCACertificate() }
            reload()
            isBusy = false
        }
    }

    func refreshStatus() {
        isBusy = true
        Task {
            _ = await runOffMain { _ = try self.manager.currentCACertificate() }
            reload()
            isBusy = false
        }
    }

    // MARK: - Export

    /// 导出 CA 证书包（.p12，**含私钥**）—— 目的地在另一台 Mac 上导入，两台共用同一套 CA
    func exportCA() {
        guard let url = savePanel(
            title: "导出 CA 证书包",
            name: "VirtualLocation-CA.p12",
            extension: "p12"
        ) else { return }
        perform(success: "已导出 CA 证书包，可在另一台 Mac 上导入") {
            try self.manager.exportCAIdentity(to: url)
        }
    }

    // MARK: - Import

    /// 导入 CA 证书包，**替换本机 CA**。换掉之后本机就用对方的 CA 签发证书，
    /// 所以已经信任过那张 CA 的 iPhone 不需要重装证书。
    func importCA() {
        guard let url = openPanel(
            title: "选择 CA 证书包",
            extensions: ["p12", "pfx"]
        ) else { return }

        perform(success: "已导入 CA，本机改用该证书签发 —— 两台 Mac 共用同一套 CA") {
            try self.manager.importCAIdentity(from: url, password: self.manager.exportPassword)
        }
    }

    // MARK: - Regenerate

    func confirmRegenerate() {
        isConfirmingRegenerate = true
    }

    func regenerate() {
        perform(success: "已重新生成 CA，请在 iPhone 上重新安装并信任") {
            try self.manager.regenerateCA()
        }
    }

    // MARK: - Async plumbing

    private func perform(success: String, _ work: @escaping () throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        banner = nil
        Task {
            let result = await runOffMain(work)
            switch result {
            case .success:
                banner = Banner(kind: .success, text: success)
            case .failure(let error):
                banner = Banner(kind: .failure, text: error.localizedDescription)
            }
            reload()
            isBusy = false
        }
    }

    private func runOffMain(_ work: @escaping () throws -> Void) async -> Result<Void, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                try work()
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
    }

    // MARK: - Panels

    private func savePanel(title: String, name: String, extension ext: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [type]
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func openPanel(title: String, extensions: [String]) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        let types = extensions.compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty {
            panel.allowedContentTypes = types
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

// MARK: - Pane

struct CertificateSettingsPane: View {
    @ObservedObject var service: LocationService
    @StateObject private var model = CertificateViewModel()

    var body: some View {
        Form {
            if let banner = model.banner {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: banner.kind.icon)
                            .foregroundStyle(banner.kind.color)
                        Text(banner.text)
                            .font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button {
                            model.banner = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            certificateSection
            trustSection
            transferSection
            dangerSection
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 560)
        .task { model.loadInitial() }
    }

    // MARK: Certificate info

    private var certificateSection: some View {
        Section {
            if let info = model.info {
                LabeledContent("名称") {
                    Text(info.commonName)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                }

                LabeledContent("有效期") {
                    HStack(spacing: 6) {
                        Text(info.validityText)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                        expiryBadge(for: info)
                    }
                }

                LabeledContent("序列号") {
                    Text(info.serialNumber)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("SHA-256 指纹")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(info.sha256Fingerprint)
                        .font(.system(size: 9, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("尚未生成 CA 证书")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("CA 证书")
                Spacer()
                if model.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        model.refreshStatus()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("重新检测证书状态")
                }
            }
        }
    }

    @ViewBuilder
    private func expiryBadge(for info: CACertificateInfo) -> some View {
        if info.isExpired {
            statusPill(text: "已过期", color: .dsError)
        } else if let days = info.daysRemaining, days <= 30 {
            statusPill(text: "\(days) 天后过期", color: .dsWarning)
        }
    }

    // MARK: Trust status

    private var trustSection: some View {
        Section {
            deviceTrustHintRow

            Divider()

            iPhoneInstallGuide
        } header: {
            HStack {
                Text("信任状态")
                Spacer()
                Button {
                    copyToPasteboard(proxyURL)
                } label: {
                    Label("复制地址", systemImage: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .disabled(!service.proxyState.isActive)
                .help(proxyURL)
            }
        }
    }

    /// iPhone 安装并信任该 CA 的步骤（并入「信任状态」，不再单独占一节）
    private var iPhoneInstallGuide: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("在 iPhone 上安装并信任")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            ForEach(Array(guideSteps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.dsAccent)
                        .frame(width: 16, height: 16)
                        .background(Color.dsAccent.opacity(0.14), in: Circle())

                    Text(step)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.dsWarning)
                Text("第 3、4 步都要做。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 2)
    }

    /// iPhone 侧不做「状态」展示 —— Mac 读不到设备的信任设置。
    /// 这里只把实际观测到的现象（有没有设备流量、握手是否成功）当作提示呈现。
    private var deviceTrustHintRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)

            Text("iOS 设备")
                .font(.system(size: 12, weight: .medium))

            Spacer(minLength: 8)

            if let hint = deviceHint {
                Text(hint.text)
                    .font(.system(size: 10))
                    .foregroundStyle(hint.color)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("需在设备上安装并信任")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 只能观察到设备流量与握手结果，不能等同于「设备已信任」，所以只作提示。
    private var deviceHint: (text: String, color: Color)? {
        guard service.proxyState.isActive else { return nil }

        if service.proxyCertUntrusted {
            return ("握手被拒绝，需在设备上重装证书", .dsError)
        }
        if service.proxyCertVerified {
            return ("已完成 TLS 握手", .dsSuccess)
        }
        if service.proxyHasTraffic {
            return ("已收到设备请求", .secondary)
        }
        return ("等待设备请求", .secondary)
    }

    private func statusPill(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: Actions

    private var transferSection: some View {
        Section {
            HStack(spacing: 8) {
                Button("导入…") {
                    model.importCA()
                }
                .disabled(model.isBusy || isProxyActive)
                .help(isProxyActive
                      ? "代理运行中不能更换 CA，请先停止代理"
                      : "选择另一台 Mac 导出的 .p12 证书包；导入后两台共用同一套 CA，iPhone 只需装一次证书")

                Button("导出…") {
                    model.exportCA()
                }
                .disabled(model.isBusy)
                .help("导出含私钥的 .p12 证书包；在另一台 Mac 上导入即可共用同一套 CA")

                Spacer(minLength: 0)
            }
        } header: {
            Text("CA 证书包")
        } footer: {
            Text("导出的 .p12 含 CA 私钥，只在本机与可信设备之间传递。")
        }
    }

    private var dangerSection: some View {
        Section {
            HStack(spacing: 8) {
                Button("重新生成 CA", role: .destructive) {
                    model.confirmRegenerate()
                }
                .disabled(model.isBusy || isProxyActive)
                .help(isProxyActive
                      ? "代理运行中不能重新生成 —— 会让设备上已安装的证书立即失效，请先停止代理"
                      : "重新生成一套全新的 CA 证书")

                Button("打开证书目录") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [CertificateManager.shared.storageDirectory]
                    )
                }
                .disabled(model.isBusy)

                Spacer(minLength: 0)
            }
        } header: {
            Text("维护")
        }
        .confirmationDialog(
            "确定要重新生成 CA 证书吗？",
            isPresented: $model.isConfirmingRegenerate
        ) {
            Button("重新生成", role: .destructive) {
                // 双重保险：按钮已禁用，这里再挡一次（破坏性操作值得硬挡）
                guard !isProxyActive else { return }
                model.regenerate()
            }
            .disabled(isProxyActive)
            Button("取消", role: .cancel) {}
        } message: {
            Text(isProxyActive
                 ? "代理正在运行，请先停止代理再重新生成。"
                 : "旧证书将立即失效，所有已安装该证书的设备都需要重新安装并信任新的 CA。")
        }
    }

    /// 代理运行中禁止重新生成 CA：会让设备上已安装的证书立即失效，正在进行的 TLS 连接也会断。
    private var isProxyActive: Bool { service.proxyState.isActive }

    // MARK: Install guide

    private var proxyURL: String {
        if let address = service.proxyAddress { return "http://\(address)" }
        if let ip = service.localIPAddress { return "http://\(ip):\(service.proxySettings.port)" }
        return "http://<Mac IP>:\(service.proxySettings.port)"
    }

    private var guideSteps: [String] {
        [
            "iPhone 与本机连同一 WiFi，WiFi 设置里把「配置代理」设为手动：\(service.localIPAddress ?? "<Mac IP>")，端口 \(service.proxySettings.port)",
            "用 Safari 打开 \(proxyURL)，点「下载 CA 证书」",
            "设置 › 通用 › VPN 与设备管理 → 安装描述文件",
            "设置 › 通用 › 关于本机 › 证书信任设置 → 打开该 CA 的开关",
            "回到本应用选点并「应用」，再在 iPhone 上开关一次定位服务",
        ]
    }
}
