import SwiftUI

struct AboutView: View {
    private let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "VirtualLocation"
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    private let copyright = Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String
        ?? "© 2025 VirtualLocation. All rights reserved."

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "location.circle.fill")
                .font(.system(size: 72))
                .foregroundColor(.dsAccent)
                .padding(.bottom, 16)

            Text(appName)
                .font(.system(size: 18, weight: .bold))
                .padding(.bottom, 4)

            Text("版本 \(version) (\(build))")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.bottom, 20)

            Text(copyright)
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .frame(width: 320, height: 260)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
