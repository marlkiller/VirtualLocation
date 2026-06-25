import SwiftUI

private var crashLogURL: URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let dir = appSupport.appendingPathComponent("VirtualLocation")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("crash.log")
}

private func setupSignalHandlers() {
    // Ignore SIGPIPE (broken pipe) - prevents crash when writing to closed socket
    signal(SIGPIPE, SIG_IGN)

    // Handle crash signals
    let crashSignals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL]
    for sig in crashSignals {
        signal(sig) { signal in
            let msg = "[CRASH] Signal \(signal) received\n"
            try? msg.appendLine(to: crashLogURL)

            // Get call stack
            let symbols = Thread.callStackSymbols
            let stack = symbols.joined(separator: "\n")
            try? stack.appendLine(to: crashLogURL)

            // Write to stderr for Console.app
            fwrite(msg, 1, msg.count, stderr)
            fwrite(stack, 1, stack.count, stderr)
            fflush(stderr)

            _exit(128 + signal)
        }
    }
}

extension String {
    func appendLine(to url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            if let data = (self + "\n").data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
        } else {
            try (self + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

@main
struct VirtualLocationApp: App {
    @Environment(\.openWindow) private var openWindow

    init() {
        setupSignalHandlers()
    }

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
        }

        Window("关于 VirtualLocation", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 320, height: 260)
    }
}