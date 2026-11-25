import AppKit

// Closing the window closes just the window — the app and the server it serves stay alive in
// the background. Only quitting (Cmd+Q) ends them; AppModel's willTerminate observer owns the
// server teardown.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
