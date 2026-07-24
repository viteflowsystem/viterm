import CoreGraphics

/// Pure geometry/index helpers for tab drag and drop reordering.
public enum TabReorderMath {
    /// Returns the insertion slot for a drag position and tab midpoint list.
    ///
    /// Slot `i` means insert before tab `i`; `tabMidXs.count` means append.
    public static func insertionSlot(forDragX x: CGFloat, tabMidXs: [CGFloat]) -> Int {
        tabMidXs.reduce(into: 0) { count, midX in
            if midX < x {
                count += 1
            }
        }
    }
}
