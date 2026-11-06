// Where the menu bar and windows are, for deciding how the dropdown should react.
import AppKit

/// The band across the top of each screen that the menu bar occupies, whether or not
/// it's showing at the moment.
enum MenuBarStrip {
    /// Three readings, because each falls short alone. `thickness` is an item's height
    /// (22 pt), which macOS 27's 30 pt bar has outgrown. The status item's window spans
    /// the full bar. `safeAreaTop` covers notched displays.
    static func height(statusItemThickness: CGFloat, statusItemWindowHeight: CGFloat?, safeAreaTop: CGFloat) -> CGFloat {
        max(statusItemThickness, statusItemWindowHeight ?? 0, safeAreaTop)
    }

    /// Whether `point`, in global coordinates, is in the strip of the screen it's on.
    /// A pointer pushed against the top of a screen, which is what reveals a hidden menu
    /// bar, reports y == maxY, so the top edge counts as on the screen.
    static func contains(_ point: CGPoint, screens: [(frame: CGRect, menuBarHeight: CGFloat)]) -> Bool {
        let hit = screens.first {
            point.x >= $0.frame.minX && point.x < $0.frame.maxX && point.y > $0.frame.minY && point.y <= $0.frame.maxY
        }
        guard let hit else { return false }
        return point.y >= hit.frame.maxY - hit.menuBarHeight
    }
}

/// Where a window sits among every app's windows, as the window server has them.
enum WindowStack {
    /// The window directly in front of `window` on the same layer, or nil when nothing is.
    static func window(inFrontOf window: Int) -> Int? {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let stack = info.compactMap { entry -> (number: Int, layer: Int)? in
            guard let number = entry[kCGWindowNumber as String] as? Int,
                  let layer = entry[kCGWindowLayer as String] as? Int else { return nil }
            return (number, layer)
        }
        return Self.window(inFrontOf: window, in: stack)
    }

    /// `stack` runs front to back. Other layers don't count: the menu bar and the
    /// dropdown are in that list, and neither covers Settings in a way ordering could change.
    static func window(inFrontOf window: Int, in stack: [(number: Int, layer: Int)]) -> Int? {
        guard let index = stack.firstIndex(where: { $0.number == window }) else { return nil }
        let layer = stack[index].layer
        return stack[..<index].last(where: { $0.layer == layer })?.number
    }
}
