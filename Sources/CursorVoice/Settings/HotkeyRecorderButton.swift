import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Records a global hotkey. Requires at least one modifier (⌘/⌥/⌃/⇧).
/// Pressing modifiers alone updates a live preview. The combo commits
/// on the first non-modifier keyDown.
struct HotkeyRecorderButton: View {
    @Binding var recording: Bool
    let onCapture: (HotkeySpec) -> Void

    @State private var liveMods: NSEvent.ModifierFlags = []

    var body: some View {
        Button {
            if recording {
                HotkeyCapture.cancel()
                recording = false
            } else {
                recording = true
                liveMods = []
                HotkeyCapture.start(
                    onMods: { mods in liveMods = mods },
                    onCommit: { spec in
                        recording = false
                        liveMods = []
                        onCapture(spec)
                    },
                    onCancel: {
                        recording = false
                        liveMods = []
                    }
                )
            }
        } label: {
            if recording {
                HStack(spacing: 4) {
                    Text(liveMods.isEmpty ? "Press keys…" : "\(modDisplay(liveMods))…")
                        .font(.system(size: 11, design: .monospaced))
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(.red)
                }
            } else {
                Text("Record")
            }
        }
        .buttonStyle(.bordered)
    }

    private func modDisplay(_ mods: NSEvent.ModifierFlags) -> String {
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option)  { s += "⌥" }
        if mods.contains(.shift)   { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        return s
    }
}

private enum HotkeyCapture {
    private static var keyMonitor: Any?
    private static var flagMonitor: Any?
    private static var onMods: ((NSEvent.ModifierFlags) -> Void)?
    private static var onCommit: ((HotkeySpec) -> Void)?
    private static var onCancel: (() -> Void)?

    static func start(onMods: @escaping (NSEvent.ModifierFlags) -> Void,
                      onCommit: @escaping (HotkeySpec) -> Void,
                      onCancel: @escaping () -> Void) {
        cancel()
        self.onMods = onMods
        self.onCommit = onCommit
        self.onCancel = onCancel

        flagMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            onMods(event.modifierFlags.intersection([.command, .option, .control, .shift]))
            return nil
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Esc cancels.
            if event.keyCode == UInt16(kVK_Escape) {
                cancel()
                onCancel()
                return nil
            }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            // Require at least one modifier — a bare letter is a terrible global hotkey.
            if mods.isEmpty {
                NSSound.beep()
                return nil
            }
            let spec = HotkeySpec(keyCode: UInt32(event.keyCode),
                                  carbonModifiers: Self.carbonFlags(from: mods))
            cancel()
            onCommit(spec)
            return nil
        }
    }

    static func cancel() {
        if let m = keyMonitor  { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = flagMonitor { NSEvent.removeMonitor(m); flagMonitor = nil }
        onMods = nil; onCommit = nil; onCancel = nil
    }

    private static func carbonFlags(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var v: UInt32 = 0
        if flags.contains(.command) { v |= UInt32(cmdKey) }
        if flags.contains(.option)  { v |= UInt32(optionKey) }
        if flags.contains(.control) { v |= UInt32(controlKey) }
        if flags.contains(.shift)   { v |= UInt32(shiftKey) }
        return v
    }
}
