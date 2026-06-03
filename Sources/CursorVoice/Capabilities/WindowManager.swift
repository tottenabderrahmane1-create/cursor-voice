import Foundation
import AppKit
import ApplicationServices

/// Native window & application management — replaces fragile AppleScript for
/// opening, activating, listing, and positioning apps/windows. Uses NSWorkspace,
/// CGWindowList, and the Accessibility API directly.
enum WindowManager {

    /// The frontmost (active) application.
    @MainActor
    static func frontmostApp() -> [String: Any] {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return ["error": "no frontmost application"]
        }
        return [
            "name": app.localizedName ?? "",
            "bundle_id": app.bundleIdentifier ?? "",
            "pid": Int(app.processIdentifier)
        ]
    }

    /// Visible, regular (dock-shown) running applications.
    @MainActor
    static func listApps() -> [[String: Any]] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { a in
                guard let name = a.localizedName else { return nil }
                return [
                    "name": name,
                    "bundle_id": a.bundleIdentifier ?? "",
                    "active": a.isActive
                ] as [String: Any]
            }
    }

    /// Bring an app to the front. Matches by exact name/bundle id, then by
    /// case-insensitive name contains.
    @MainActor
    static func activateApp(query: String) -> [String: Any] {
        guard let app = matchRunning(query) else {
            return ["error": "no running app matching \"\(query)\""]
        }
        app.activate(options: [.activateAllWindows])
        return ["ok": true, "activated": app.localizedName ?? query]
    }

    /// Launch an app by display name or bundle id (opens if not running).
    @MainActor
    static func openApp(name: String) -> [String: Any] {
        let ws = NSWorkspace.shared
        var url: URL?
        if name.contains("."), let u = ws.urlForApplication(withBundleIdentifier: name) {
            url = u
        }
        if url == nil {
            let dirs = ["/Applications", "/System/Applications",
                        "/System/Applications/Utilities",
                        "\(NSHomeDirectory())/Applications"]
            let trimmed = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
            for d in dirs {
                let p = "\(d)/\(trimmed).app"
                if FileManager.default.fileExists(atPath: p) { url = URL(fileURLWithPath: p); break }
            }
        }
        guard let appURL = url else {
            return ["error": "couldn't find app \"\(name)\" — try the exact name or its bundle id"]
        }
        ws.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        return ["ok": true, "opening": appURL.deletingPathExtension().lastPathComponent]
    }

    /// On-screen normal windows (layer 0), with owner app, title, and bounds.
    static func listWindows() -> [[String: Any]] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var out: [[String: Any]] = []
        for info in infoList {
            let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
            guard layer == 0 else { continue }
            let owner = (info[kCGWindowOwnerName as String] as? String) ?? ""
            let title = (info[kCGWindowName as String] as? String) ?? ""
            if owner.isEmpty && title.isEmpty { continue }
            var bounds: [String: Any] = [:]
            if let b = info[kCGWindowBounds as String] as? [String: Any] {
                bounds = ["x": b["X"] ?? 0, "y": b["Y"] ?? 0, "width": b["Width"] ?? 0, "height": b["Height"] ?? 0]
            }
            out.append([
                "app": owner,
                "title": title,
                "bounds": bounds,
                "window_id": (info[kCGWindowNumber as String] as? Int) ?? 0
            ])
            if out.count >= 40 { break }
        }
        return out
    }

    /// Move/resize an app's frontmost window. Coordinates are global screen
    /// points (top-left origin). Requires Accessibility permission.
    @MainActor
    static func setWindowBounds(appQuery: String, x: Double, y: Double, width: Double, height: Double) -> [String: Any] {
        guard AXIsProcessTrusted() else { return ["error": "accessibility permission required"] }
        guard let app = matchRunning(appQuery) else {
            return ["error": "no running app matching \"\(appQuery)\""]
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var winRef: AnyObject?
        let focusedErr = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef)
        if focusedErr != .success || winRef == nil {
            var winsRef: AnyObject?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
                  let wins = winsRef as? [AXUIElement], let first = wins.first else {
                return ["error": "no window found for \(app.localizedName ?? appQuery)"]
            }
            winRef = first
        }
        let window = winRef as! AXUIElement

        var pos = CGPoint(x: x, y: y)
        var size = CGSize(width: width, height: height)
        var okPos = false, okSize = false
        if let posVal = AXValueCreate(.cgPoint, &pos) {
            okPos = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal) == .success
        }
        if let sizeVal = AXValueCreate(.cgSize, &size) {
            okSize = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal) == .success
        }
        return [
            "ok": okPos && okSize,
            "app": app.localizedName ?? appQuery,
            "x": x, "y": y, "width": width, "height": height
        ]
    }

    // MARK: - Private

    @MainActor
    private static func matchRunning(_ query: String) -> NSRunningApplication? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        return apps.first(where: { ($0.localizedName?.lowercased() == q) || ($0.bundleIdentifier?.lowercased() == q) })
            ?? apps.first(where: { $0.localizedName?.lowercased().contains(q) ?? false })
    }
}
