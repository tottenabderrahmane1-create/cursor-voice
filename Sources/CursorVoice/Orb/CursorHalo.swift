import AppKit
import SwiftUI
import Combine

/// Small floating panel that hovers around the real cursor and lights up
/// while the AI is performing input synthesis (move/click/drag/type).
@MainActor
final class CursorHalo: ObservableObject {
    @Published var active: Bool = false
    @Published private(set) var cursorPoint: NSPoint = .zero

    private let panel: NSPanel
    private let size: NSSize = NSSize(width: 120, height: 120)
    private var tracker: Timer?

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver  // above the orb's status bar level so it can sit anywhere
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: CursorHaloView(halo: self))
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.masksToBounds = false
    }

    func start() {
        // Reposition every frame; cursor effect should glide with the cursor.
        tracker?.invalidate()
        tracker = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
        if let t = tracker { RunLoop.main.add(t, forMode: .common) }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func stop() {
        tracker?.invalidate()
        tracker = nil
        panel.orderOut(nil)
    }

    private func reposition() {
        let p = NSEvent.mouseLocation
        cursorPoint = p
        panel.setFrameOrigin(NSPoint(x: p.x - size.width / 2, y: p.y - size.height / 2))
    }
}

private struct CursorHaloView: View {
    @ObservedObject var halo: CursorHalo

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let breathe = sin(t * 1.7) * 0.5 + 0.5     // 0…1, slow
            let intensity: Double = halo.active ? 1.0 : 0.45

            // Two layered radial blooms — no ring, no dot. Just a soft aura
            // emanating from the cursor that breathes and brightens during AI input.
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.97, green: 0.45, blue: 0.78).opacity(0.55 * intensity),
                                Color(red: 0.55, green: 0.30, blue: 0.95).opacity(0.30 * intensity),
                                .clear
                            ],
                            center: .center,
                            startRadius: 2,
                            endRadius: halo.active ? 46 : 34
                        )
                    )
                    .blur(radius: halo.active ? 10 : 14)
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.40, green: 0.78, blue: 1.00).opacity(0.40 * intensity),
                                .clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: halo.active ? 30 : 22
                        )
                    )
                    .blur(radius: 8)
            }
            .scaleEffect(0.92 + 0.08 * breathe)
            .animation(.easeOut(duration: 0.45), value: halo.active)
        }
        .allowsHitTesting(false)
        .frame(width: 120, height: 120)
    }
}
