import SwiftUI

@main
struct VirtualLocationApp: App {
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.automatic)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 VirtualLocation") {
                    openWindow(id: "about")
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",")
            }
        }

        Window("关于 VirtualLocation", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 320, height: 260)
    }
}

extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
}