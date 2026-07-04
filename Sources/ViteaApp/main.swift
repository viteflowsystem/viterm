import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered,
    defer: false
)
window.title = "vitea"
window.center()
window.makeKeyAndOrderFront(nil)

app.activate(ignoringOtherApps: true)
app.run()
