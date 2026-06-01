import AppKit

/// Loads the colored aurora-orb glyph from the bundle for the menu bar.
/// Falls back to an SF Symbol if the resource isn't present.
enum MenuBarIcon {
    static let image: NSImage = {
        if let path = Bundle.main.path(forResource: "MenuBarIcon", ofType: "png"),
           let img = NSImage(contentsOfFile: path) {
            if let p2 = Bundle.main.path(forResource: "MenuBarIcon@2x", ofType: "png"),
               let img2 = NSImage(contentsOfFile: p2),
               let rep2 = img2.representations.first {
                rep2.size = NSSize(width: 18, height: 18)
                img.addRepresentation(rep2)
            }
            img.size = NSSize(width: 18, height: 18)
            // Full-color brand glyph — not template.
            img.isTemplate = false
            return img
        }
        let fallback = NSImage(systemSymbolName: "circle.fill",
                               accessibilityDescription: "Cursor Voice")!
        fallback.isTemplate = true
        return fallback
    }()
}
