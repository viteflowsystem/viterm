import AppKit
import VitermCore

enum SessionDragPasteboard {
    static let type = NSPasteboard.PasteboardType("com.viteflow.viterm.session")

    static func write(_ sessionID: AgentSession.ID, to item: NSPasteboardItem) {
        item.setString(sessionID.uuidString, forType: type)
    }

    static func sessionID(from pasteboard: NSPasteboard) -> AgentSession.ID? {
        pasteboard.string(forType: type).flatMap(UUID.init(uuidString:))
    }
}
