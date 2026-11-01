import AppKit
import SwiftUI

/// The island on one display: its panel, hover area and open state.
@MainActor
final class IslandWindow {
    /// Transparent canvas: tall enough for the tallest drop under the tallest notch, plus room for the shadow.
    /// Clicks on its empty parts go through to the windows below.
    static let canvas = CGSize(width: 640, height: max(240, (ClaudeLayout.tallest + 40 + 32).rounded(.up)))
    private static let hoverDelay: TimeInterval = 0.1
    private static let leaveDelay: TimeInterval = 0.12

    let metrics: NotchMetrics
    let screen: IslandScreen
    private let model: IslandModel
    private let panel: NotchPanel
    private let host: IslandHostView

    var onBoop: (() -> Void)?
    var onClaudeClick: (() -> Void)?
    var onStopRecording: (() -> Void)?
    private var pendingOpen: DispatchWorkItem?
    private var pendingClose: DispatchWorkItem?
    private var mouseMonitors: [Any] = []

    init(metrics: NotchMetrics, model: IslandModel) {
        self.metrics = metrics
        self.model = model
        screen = IslandScreen(geometry: metrics.geometry)
        panel = NotchPanel(frame: NSRect(x: metrics.centerX - Self.canvas.width / 2,
                                         y: metrics.screenFrame.maxY - Self.canvas.height,
                                         width: Self.canvas.width, height: Self.canvas.height))
        host = IslandHostView(rootView: IslandView(model: model, screen: screen))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: Self.canvas)
        panel.contentView = host

        host.onEnter = { [weak self] in self?.cursorEntered() }
        host.onExit = { [weak self] in self?.pendingOpen?.cancel() }
        host.onClick = { [weak self] in self?.clicked(at: $0) }
        refreshHotRect()
        panel.orderFrontRegardless()
    }

    var cursorInHotZone: Bool {
        let p = host.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return host.hotRect.contains(p)
    }

    func snapshot(to path: String) {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// For filming demos: let screen recordings see the island.
    func setCapturable(_ on: Bool) { panel.sharingType = on ? .readOnly : .none }

    func close() {
        pendingOpen?.cancel()
        pendingClose?.cancel()
        stopMouseMonitors()
        panel.orderOut(nil)
        panel.close()
    }

    /// The hover area is whatever is visible at rest: the notch, plus its ears when music plays.
    /// On displays without a notch and nothing playing there is nothing to hover.
    func refreshHotRect() {
        if model.recording != nil {
            setHotRect(screen.geometry.size(.recording, claude: model.claude))
            return
        }
        if model.claude != nil {
            setHotRect(screen.geometry.size(.claudeEar, claude: model.claude))
            return
        }
        guard !screen.fullscreen else { host.hotRect = .zero; return }
        var s = screen.geometry.size(model.mediaVisible && model.nowPlaying != nil ? .compact : .idle)
        if s.height == 0, model.nowPlaying != nil { s = IslandGeometry.hoverStrip }
        setHotRect(s)
    }

    private func setHotRect(_ s: CGSize) {
        let x = (Self.canvas.width - s.width) / 2
        let y = host.isFlipped ? 0 : Self.canvas.height - s.height
        host.hotRect = NSRect(x: x, y: y, width: s.width, height: s.height)
    }

    private func expandedScreenRect() -> NSRect {
        let s = screen.expandedClaude ? screen.geometry.size(.claude, claude: model.claude) : screen.geometry.size(.media)
        let w = s.width + IslandLayout.ear * 2
        return NSRect(x: metrics.centerX - w / 2, y: metrics.screenFrame.maxY - s.height, width: w, height: s.height)
    }

    // MARK: - Cursor

    private func cursorEntered() {
        pendingClose?.cancel()
        guard Preferences.shared.openOnHover, !screen.expanded else { return }
        // While recording, hover opens nothing: it would cover the stop button.
        guard model.recording == nil else { return }
        let claude = model.claude?.expandable == true
        guard claude || (!screen.fullscreen && model.nowPlaying != nil && model.claude == nil) else { return }
        let work = DispatchWorkItem { [weak self] in self?.setExpanded(true, claude: claude) }
        pendingOpen = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDelay, execute: work)
    }

    private func clicked(at point: NSPoint) {
        ClaudeCenter.trace("notch click: mode=\(screen.mode(of: model)) open=\(screen.expanded) claude=\(screen.expandedClaude) alert=\(model.claude != nil)")
        if let recording = model.recording, !screen.expanded, screen.mode(of: model) == .recording {
            let ear = IslandLayout.recordingEarWidth(claude: model.claude != nil) + IslandLayout.ear
            if recording.stoppable, point.x < host.hotRect.minX + ear { onStopRecording?(); return }
            if model.claude?.expandable == true { setExpanded(true, claude: true) }
            else if model.nowPlaying != nil, !screen.fullscreen { setExpanded(true) }
            return
        }
        if let notice = model.claude {
            // Clicking goes to Claude's window, except when the notch opens on click: then the first click opens it.
            if screen.expanded {
                if screen.expandedClaude { onClaudeClick?() }
            } else if notice.expandable, !Preferences.shared.openOnHover {
                setExpanded(true, claude: true)
            } else {
                onClaudeClick?()
            }
            return
        }
        if model.nowPlaying == nil, !screen.fullscreen { onBoop?(); return }
        guard !Preferences.shared.openOnHover, !screen.fullscreen, !screen.expanded, model.nowPlaying != nil else { return }
        setExpanded(true)
    }

    /// Debug (brimctl hover): stays open wherever the real cursor is, until `leave`.
    var debugPinned = false

    private func cursorMoved() {
        guard !debugPinned else { return }
        let inside = expandedScreenRect().insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        if inside {
            pendingClose?.cancel(); pendingClose = nil
        } else if pendingClose == nil {
            let work = DispatchWorkItem { [weak self] in self?.setExpanded(false) }
            pendingClose = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.leaveDelay, execute: work)
        }
    }

    /// Debug: a click in the middle of the hover area, as if the user clicked the notch.
    func debugClick() { clicked(at: NSPoint(x: host.hotRect.midX, y: host.hotRect.midY)) }

    func setFullscreen(_ on: Bool) {
        guard screen.fullscreen != on else { return }
        if on { setExpanded(false) }
        withAnimation(on ? .smooth : .snappy) { screen.fullscreen = on }
        refreshHotRect()
    }

    func setExpanded(_ open: Bool, claude: Bool = false) {
        pendingOpen = nil; pendingClose = nil
        guard screen.expanded != open else { return }
        withAnimation(open ? .snappy : .smooth) {
            screen.expanded = open
            if open { screen.expandedClaude = claude }
        }
        // Mouse monitors only run while the island is open.
        if open { startMouseMonitors() } else { stopMouseMonitors() }
    }

    private func startMouseMonitors() {
        guard mouseMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.cursorMoved() }
        }) { mouseMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            self?.cursorMoved(); return e
        }) { mouseMonitors.append(l) }
    }

    private func stopMouseMonitors() {
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors.removeAll()
    }
}

final class IslandHostView: NSHostingView<IslandView> {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onClick: ((NSPoint) -> Void)?
    var hotRect: NSRect = .zero { didSet { updateTrackingAreas() } }
    private var hotArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hotArea { removeTrackingArea(hotArea) }
        let area = NSTrackingArea(rect: hotRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        hotArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea === hotArea { onEnter?() } else { super.mouseEntered(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea === hotArea { onExit?() } else { super.mouseExited(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if hotRect.contains(point) { onClick?(point) }
        super.mouseDown(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(IslandMenu.shared.make(), with: event, for: self)
    }
}
