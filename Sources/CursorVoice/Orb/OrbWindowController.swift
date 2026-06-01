import AppKit
import SwiftUI

@MainActor
final class OrbWindowController {
    private let state: OrbState
    private let panel: OrbPanel
    private let tracker = CursorTracker()
    private var hosting: NSHostingView<OrbView>?
    /// Single source of truth for "user wants to close": always go through coordinator.deactivate()
    /// so realtime + halo + wake-word teardown runs.
    private let requestDismiss: () -> Void

    private let panelSize = NSSize(width: 300, height: 280)

    init(state: OrbState, requestDismiss: @escaping () -> Void) {
        self.state = state
        self.requestDismiss = requestDismiss
        self.panel = OrbPanel(contentRect: NSRect(origin: .zero, size: panelSize))

        let view = OrbView(state: state, onDismiss: requestDismiss)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: panelSize)
        host.autoresizingMask = [.width, .height]
        // Prevent CALayer from clipping the orb's outer glow at the layer bounds.
        host.wantsLayer = true
        host.layer?.masksToBounds = false
        panel.contentView = host
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.masksToBounds = false
        hosting = host

        tracker.onMove = { [weak self] point in
            self?.reposition(for: point, animated: true)
        }
    }

    func present() {
        let cursor = NSEvent.mouseLocation
        reposition(for: cursor, animated: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        state.isVisible = true
        tracker.start()
        installDismissMonitors()
    }

    private var dismissGeneration: Int = 0
    private var clickAwayMonitor: Any?
    private var escMonitor: Any?

    func dismiss() {
        guard state.isVisible else { return }
        state.isVisible = false
        tracker.stop()
        removeDismissMonitors()
        dismissGeneration += 1
        let token = dismissGeneration
        // Let the SwiftUI dismiss animation play before hiding the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            guard let self = self else { return }
            // Skip the hide if the user re-summoned in the meantime.
            if token == self.dismissGeneration && !self.state.isVisible {
                self.panel.orderOut(nil)
            }
        }
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        // Click anywhere outside our panel → dismiss. AI synthetic events
        // are tagged with InputSynth.eventUserDataMarker; we filter those
        // out at the source so there's no race with the aiControlling flag.
        clickAwayMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let cg = event.cgEvent,
               cg.getIntegerValueField(.eventSourceUserData) == InputSynth.eventUserDataMarker {
                return  // synthetic from us — ignore
            }
            DispatchQueue.main.async { self?.requestDismiss() }
        }
        // Global Esc → dismiss.
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {
                if let cg = event.cgEvent,
                   cg.getIntegerValueField(.eventSourceUserData) == InputSynth.eventUserDataMarker {
                    return
                }
                DispatchQueue.main.async { self?.requestDismiss() }
            }
        }
    }

    private func removeDismissMonitors() {
        if let m = clickAwayMonitor { NSEvent.removeMonitor(m); clickAwayMonitor = nil }
        if let m = escMonitor       { NSEvent.removeMonitor(m); escMonitor = nil }
    }

    /// Place the panel so the orb sits ~24pt down-right of the cursor,
    /// flipping sides if it would clip a screen edge.
    private func reposition(for cursor: NSPoint, animated: Bool) {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) })
                   ?? NSScreen.main
                   ?? NSScreen.screens.first!
        // Use the FULL screen rect (frame), not visibleFrame, so the orb can
        // follow the cursor into the menu-bar / dock area.
        let bounds = screen.frame

        // Place the orb just below-right of the cursor. The orb visual sits
        // at the panel center; we shift the panel so the orb visually lands
        // about 18pt diagonally from the cursor.
        let offset: CGFloat = 18
        var origin = NSPoint(
            x: cursor.x + offset - panelSize.width / 2 + 28,
            y: cursor.y - offset - panelSize.height / 2 - 28
        )

        // Flip left if it would overflow right
        if origin.x + panelSize.width > bounds.maxX - 8 {
            origin.x = cursor.x - offset - panelSize.width / 2 - 28
        }
        // Flip up if it would overflow bottom
        if origin.y < bounds.minY + 8 {
            origin.y = cursor.y + offset - panelSize.height / 2 + 28
        }
        // Clamp
        origin.x = max(bounds.minX + 8, min(bounds.maxX - panelSize.width - 8, origin.x))
        origin.y = max(bounds.minY + 8, min(bounds.maxY - panelSize.height - 8, origin.y))

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrameOrigin(origin)
            }
        } else {
            panel.setFrameOrigin(origin)
        }
    }
}
