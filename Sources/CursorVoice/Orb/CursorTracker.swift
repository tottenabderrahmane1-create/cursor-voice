import AppKit

/// Polls the cursor position on a CADisplayLink-like timer and fires
/// `onMove` when it changes meaningfully. Lighter than a global mouse
/// monitor for our purposes and avoids the accessibility prompt.
@MainActor
final class CursorTracker {
    var onMove: ((NSPoint) -> Void)?

    private var timer: Timer?
    private var lastPoint: NSPoint = .zero
    private let threshold: CGFloat = 4

    func start() {
        stop()
        lastPoint = NSEvent.mouseLocation
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let p = NSEvent.mouseLocation
        if abs(p.x - lastPoint.x) > threshold || abs(p.y - lastPoint.y) > threshold {
            lastPoint = p
            onMove?(p)
        }
    }
}
