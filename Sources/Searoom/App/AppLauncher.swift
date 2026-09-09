import AppKit

/// The only place AppKit lifecycle objects are constructed. The CLI dispatch
/// in main.swift must fully resolve before this runs; recognized CLI commands
/// never reach it.
@MainActor
enum AppLauncher {
    static func launch() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
