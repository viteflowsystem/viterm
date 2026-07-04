import AppKit

// T3 スパイク: libghostty サーフェス1枚で zsh を動かす。
// UI シェル(サイドバー等)は T7b 以降で組み込む。

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

let surfaceView = GhosttySurfaceView(command: nil, workingDirectory: nil)
window.contentView = surfaceView
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(surfaceView)

app.activate(ignoringOtherApps: true)
app.run()
