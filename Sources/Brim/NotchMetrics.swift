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
        return make(displayID: id, frame: s.frame, visibleFrame: s.visibleFrame, safeTop: s.safeAreaInsets.top,
                    leftArea: s.auxiliaryTopLeftArea?.width, rightArea: s.auxiliaryTopRightArea?.width,
                    isBuiltIn: CGDisplayIsBuiltin(id) != 0)
    }

    /// The same from plain values, so it can be tested without a display.
    static func make(displayID: CGDirectDisplayID, frame: CGRect, visibleFrame: CGRect, safeTop: CGFloat,
                     leftArea: CGFloat?, rightArea: CGFloat?, isBuiltIn: Bool) -> NotchMetrics {
        if safeTop > 0 {
            // Without both areas (or with nonsense) the notch would span the screen: assume a usual,
            // centered one. MacBook notches are 180–200 pt wide.
            var left = leftArea ?? 0, width = frame.width - left - (rightArea ?? 0)
            if leftArea == nil || rightArea == nil || width <= 0 || width > frame.width / 3 {
                width = 185
                left = (frame.width - width) / 2
            }
            return NotchMetrics(displayID: displayID, screenFrame: frame, centerX: frame.minX + left + width / 2, isBuiltIn: isBuiltIn,
                                geometry: IslandGeometry(notch: CGSize(width: width, height: safeTop), hasNotch: true))
        }
        // No notch: the island grows from the top edge, as tall as the menu bar (24 pt when hidden).
        let menuBar = frame.maxY - visibleFrame.maxY
        return NotchMetrics(displayID: displayID, screenFrame: frame, centerX: frame.midX, isBuiltIn: isBuiltIn,
                            geometry: IslandGeometry(notch: CGSize(width: 0, height: menuBar > 0 ? menuBar : 24), hasNotch: false))
    }

    /// Falls back to the main display when none of the chosen ones is connected (lid closed).
    @MainActor
    static func targets(for choice: DisplayChoice) -> [NotchMetrics] {
        pick(NSScreen.screens.map(of), choice: choice)
    }

    static func pick(_ all: [NotchMetrics], choice: DisplayChoice) -> [NotchMetrics] {
        let picked = switch choice {
        case .all: all
        case .builtIn: all.filter(\.isBuiltIn)
        case .external: all.filter { !$0.isBuiltIn }
        }
        if !picked.isEmpty { return picked }
        return all.first.map { [$0] } ?? []
    }
}
