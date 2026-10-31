import AppKit

enum DisplayChoice: String, CaseIterable {
    case all, builtIn, external
}

struct NotchMetrics: Equatable {
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    let centerX: CGFloat
    let isBuiltIn: Bool
    let geometry: IslandGeometry

    @MainActor
    static func of(_ s: NSScreen) -> NotchMetrics {
        let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let builtIn = CGDisplayIsBuiltin(id) != 0
        if s.safeAreaInsets.top > 0 {
            let left = s.auxiliaryTopLeftArea?.width ?? 0
            let right = s.auxiliaryTopRightArea?.width ?? 0
            let width = s.frame.width - left - right
            return NotchMetrics(displayID: id, screenFrame: s.frame, centerX: s.frame.minX + left + width / 2, isBuiltIn: builtIn,
                                geometry: IslandGeometry(notch: CGSize(width: width, height: s.safeAreaInsets.top), hasNotch: true))
        }
        // No notch: the island grows from the top edge, as tall as the menu bar (24 pt when hidden).
        let menuBar = s.frame.maxY - s.visibleFrame.maxY
        return NotchMetrics(displayID: id, screenFrame: s.frame, centerX: s.frame.midX, isBuiltIn: builtIn,
                            geometry: IslandGeometry(notch: CGSize(width: 0, height: menuBar > 0 ? menuBar : 24), hasNotch: false))
    }

    /// Falls back to the main display when none of the chosen ones is connected (lid closed).
    @MainActor
    static func targets(for choice: DisplayChoice) -> [NotchMetrics] {
        let all = NSScreen.screens.map(of)
        let picked = switch choice {
        case .all: all
        case .builtIn: all.filter(\.isBuiltIn)
        case .external: all.filter { !$0.isBuiltIn }
        }
        if !picked.isEmpty { return picked }
        return NSScreen.screens.first.map { [of($0)] } ?? []
    }
}
