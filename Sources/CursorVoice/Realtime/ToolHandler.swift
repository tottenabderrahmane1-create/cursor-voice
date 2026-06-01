import Foundation
import CoreGraphics
import AppKit

/// Output of a tool call. `outputJSON` is the string the model receives as
/// the function call result. `attachedImageBase64`, if set, is a JPEG that
/// the realtime client should inject as a user input_image conversation
/// item BEFORE delivering the function output (so the next response can
/// reference the screenshot).
struct ToolDispatchResult {
    let outputJSON: String
    let attachedImageBase64: String?
}

/// Dispatches Realtime API function calls to the matching Swift capability.
actor ToolHandler {
    static let toolDefinitions: [[String: Any]] = [
        [
            "type": "function",
            "name": "list_ui_elements",
            "description": "Return a list of clickable UI elements in the currently focused window of the frontmost app, using the macOS Accessibility tree. Each entry has role, title, and frame (in screen points). This is FAR more reliable than pixel-clicking — prefer it whenever you can. Call this BEFORE click_element. Requires Accessibility permission.",
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": [] as [String]
            ]
        ],
        [
            "type": "function",
            "name": "click_element",
            "description": "Click a UI element identified by its title text (and optionally its role like AXButton, AXLink, AXTextField). The element's center is clicked via the Accessibility tree — accurate down to the pixel and immune to layout shifts. Use this instead of mouse_click whenever the target has an accessible label. Call list_ui_elements first if you're not sure of the exact title.",
            "parameters": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Title/label of the element. Case-insensitive substring match."],
                    "role": ["type": "string", "description": "Optional AX role filter (AXButton, AXLink, AXTextField, AXMenuItem, AXCheckBox, ...)"],
                    "count": ["type": "integer", "default": 1, "description": "1 for single, 2 for double-click"]
                ],
                "required": ["name"]
            ]
        ],
        [
            "type": "function",
            "name": "remember",
            "description": "Save a fact about the user or this Mac to long-term memory (persists across sessions). Use sparingly — only durable preferences, names, IDs, common tasks, system shortcuts the user uses, etc. Don't store ephemeral state.",
            "parameters": [
                "type": "object",
                "properties": [
                    "content": ["type": "string", "description": "A short fact in the third person, e.g. 'User's preferred browser is Arc' or 'User's GitHub username is foo'"]
                ],
                "required": ["content"]
            ]
        ],
        [
            "type": "function",
            "name": "recall",
            "description": "Look up memories. Returns memories matching the optional query, or all memories if no query. Use this when the user references something you might already know.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Optional substring to filter by."]
                ],
                "required": [] as [String]
            ]
        ],
        [
            "type": "function",
            "name": "web_search",
            "description": "Search the web for live, up-to-date information. Returns the top results (title, URL, snippet). Use this for ANY question about current events, prices, scores, releases, news — anything time-sensitive. After web_search you may fetch_url to read a specific page.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Plain natural-language query."]
                ],
                "required": ["query"]
            ]
        ],
        [
            "type": "function",
            "name": "fetch_url",
            "description": "Fetch a URL and return its stripped text (≤4000 chars). Use after web_search to read a specific article or page. Does NOT open a browser window.",
            "parameters": [
                "type": "object",
                "properties": [
                    "url": ["type": "string"]
                ],
                "required": ["url"]
            ]
        ],
        [
            "type": "function",
            "name": "open_url",
            "description": "Open a URL in the user's default browser (no clicking). Use this for ALL web navigation and searches — much more reliable than trying to click through Safari. For Google: https://google.com/search?q=ENCODED_QUERY. For sites: https://example.com. URL-encode spaces as + or %20.",
            "parameters": [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "A fully-qualified URL beginning with https://"]
                ],
                "required": ["url"]
            ]
        ],
        [
            "type": "function",
            "name": "see_screen",
            "description": "Take a screenshot of the user's screen and attach it as an image. The image is the screen at NATIVE pixel resolution — image_size_px in the metadata is also the click coordinate space. ALWAYS call this before any mouse_* tool unless you've just seen the relevant area, and call it again after if you need to verify.",
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": [] as [String]
            ]
        ],
        [
            "type": "function",
            "name": "mouse_move",
            "description": "Move the mouse cursor. x, y are IMAGE PIXEL coordinates from the most recent screenshot — origin TOP-LEFT, same scale as the image (no math needed). (0,0) is the top-left corner of the screenshot.",
            "parameters": [
                "type": "object",
                "properties": [
                    "x": ["type": "number", "description": "image pixel x, top-left origin"],
                    "y": ["type": "number", "description": "image pixel y, top-left origin"]
                ],
                "required": ["x", "y"]
            ]
        ],
        [
            "type": "function",
            "name": "mouse_click",
            "description": "Click at (x, y). Coordinates are IMAGE PIXELS from the most recent screenshot (top-left origin, exact scale). For best accuracy aim at the CENTER of the target element. count=2 for double-click.",
            "parameters": [
                "type": "object",
                "properties": [
                    "x": ["type": "number"],
                    "y": ["type": "number"],
                    "button": ["type": "string", "enum": ["left", "right"], "default": "left"],
                    "count": ["type": "integer", "default": 1, "minimum": 1, "maximum": 3]
                ],
                "required": ["x", "y"]
            ]
        ],
        [
            "type": "function",
            "name": "mouse_drag",
            "description": "Press at (from_x, from_y), drag to (to_x, to_y), release. All coords are IMAGE PIXELS from the most recent screenshot.",
            "parameters": [
                "type": "object",
                "properties": [
                    "from_x": ["type": "number"], "from_y": ["type": "number"],
                    "to_x": ["type": "number"], "to_y": ["type": "number"],
                    "duration_ms": ["type": "integer", "default": 350]
                ],
                "required": ["from_x", "from_y", "to_x", "to_y"]
            ]
        ],
        [
            "type": "function",
            "name": "scroll",
            "description": "Scroll the mouse wheel by (delta_x, delta_y) pixels. Positive y scrolls up.",
            "parameters": [
                "type": "object",
                "properties": [
                    "delta_x": ["type": "integer", "default": 0],
                    "delta_y": ["type": "integer", "default": 0]
                ],
                "required": [] as [String]
            ]
        ],
        [
            "type": "function",
            "name": "type_text",
            "description": "Type a literal string into whatever's currently focused.",
            "parameters": [
                "type": "object",
                "properties": [
                    "text": ["type": "string"]
                ],
                "required": ["text"]
            ]
        ],
        [
            "type": "function",
            "name": "press_key",
            "description": "Press a named key with optional modifiers. key examples: return, tab, space, escape, up/down/left/right, a–z, 0–9, f1–f12. modifiers is an array containing any of: cmd, shift, option, control.",
            "parameters": [
                "type": "object",
                "properties": [
                    "key": ["type": "string"],
                    "modifiers": ["type": "array", "items": ["type": "string"]]
                ],
                "required": ["key"]
            ]
        ],
        [
            "type": "function",
            "name": "run_applescript",
            "description": "Run an AppleScript. Returns stdout or an error.",
            "parameters": [
                "type": "object",
                "properties": [
                    "script": ["type": "string"]
                ],
                "required": ["script"]
            ]
        ],
        [
            "type": "function",
            "name": "run_shell",
            "description": "Run a zsh shell command. Returns combined stdout/stderr (≤4000 chars).",
            "parameters": [
                "type": "object",
                "properties": [
                    "command": ["type": "string"]
                ],
                "required": ["command"]
            ]
        ]
    ]

    /// Set by the realtime client to surface "AI controlling input" state to the UI.
    var inputActivity: ((Bool) -> Void)?
    /// Fires with a short human-readable label when a tool starts running.
    var onToolStart: ((String) -> Void)?
    /// Fires when a tool finishes (success or failure).
    var onToolEnd: (() -> Void)?

    func setInputActivityCallback(_ cb: @escaping (Bool) -> Void) {
        self.inputActivity = cb
    }
    func setToolCallbacks(start: @escaping (String) -> Void, end: @escaping () -> Void) {
        self.onToolStart = start
        self.onToolEnd = end
    }

    private func friendlyLabel(for tool: String) -> String {
        switch tool {
        case "see_screen":       return "looking at screen"
        case "list_ui_elements": return "reading UI tree"
        case "click_element":    return "clicking"
        case "remember":         return "remembering"
        case "recall":           return "recalling"
        case "web_search":       return "searching the web"
        case "fetch_url":        return "reading a page"
        case "open_url":         return "opening a link"
        case "mouse_move":       return "moving cursor"
        case "mouse_click":      return "clicking"
        case "mouse_drag":       return "dragging"
        case "scroll":           return "scrolling"
        case "type_text":        return "typing"
        case "press_key":        return "pressing key"
        case "run_applescript":  return "running script"
        case "run_shell":        return "running command"
        default:                 return tool
        }
    }

    func dispatch(name: String, argsJSON: String) async -> ToolDispatchResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8)) as? [String: Any]) ?? [:]
        let label = friendlyLabel(for: name)
        onToolStart?(label)
        defer { onToolEnd?() }

        switch name {
        case "list_ui_elements":
            let elements = AXTree.enumerateFrontmost()
            let payload: [[String: Any]] = elements.map { e in
                [
                    "role": e.role,
                    "title": e.title,
                    "frame": [
                        "x": Int(e.frame.origin.x),
                        "y": Int(e.frame.origin.y),
                        "w": Int(e.frame.size.width),
                        "h": Int(e.frame.size.height)
                    ]
                ]
            }
            return ToolDispatchResult(
                outputJSON: encode([
                    "frontmost": NSWorkspace.shared.frontmostApplication?.localizedName ?? "?",
                    "count": elements.count,
                    "elements": payload
                ]),
                attachedImageBase64: nil
            )

        case "click_element":
            let nameArg = (args["name"] as? String) ?? ""
            let roleArg = args["role"] as? String
            let count = (args["count"] as? Int) ?? 1
            NSLog("Tool: click_element name=\"\(nameArg)\" role=\(roleArg ?? "—")")
            let elements = AXTree.enumerateFrontmost()
            guard let match = AXTree.bestMatch(in: elements, name: nameArg, role: roleArg) else {
                return ToolDispatchResult(
                    outputJSON: encode([
                        "error": "no element matching \"\(nameArg)\"",
                        "hint": "call list_ui_elements to see what's available"
                    ]),
                    attachedImageBase64: nil
                )
            }
            self.inputActivity?(true)
            let center = CGPoint(x: match.frame.midX, y: match.frame.midY)
            InputSynth.clickPoint(center, count: count)
            try? await Task.sleep(nanoseconds: 250_000_000)
            self.inputActivity?(false)
            return await confirmWithScreenshot([
                "ok": true,
                "action": "click_element",
                "clicked": ["role": match.role, "title": match.title]
            ])

        case "remember":
            let content = (args["content"] as? String) ?? ""
            MemoryStore.shared.remember(content)
            NSLog("Tool: remember \"\(content.prefix(80))\"")
            return ToolDispatchResult(outputJSON: encode(["ok": true, "stored": content]),
                                      attachedImageBase64: nil)

        case "recall":
            let q = args["query"] as? String
            let items = MemoryStore.shared.recall(matching: q)
            let payload = items.suffix(40).map { ["content": $0.content] }
            return ToolDispatchResult(outputJSON: encode(["count": items.count, "memories": payload]),
                                      attachedImageBase64: nil)

        case "web_search":
            let q = (args["query"] as? String) ?? ""
            NSLog("Tool: web_search \"\(q)\"")
            let result = await WebSearch.search(q)
            return ToolDispatchResult(outputJSON: encode(result), attachedImageBase64: nil)

        case "fetch_url":
            let urlString = (args["url"] as? String) ?? ""
            NSLog("Tool: fetch_url \(urlString)")
            let result = await WebSearch.fetch(urlString)
            return ToolDispatchResult(outputJSON: encode(result), attachedImageBase64: nil)

        case "open_url":
            let urlString = (args["url"] as? String) ?? ""
            NSLog("Tool: open_url \(urlString)")
            guard let url = URL(string: urlString), url.scheme != nil else {
                return ToolDispatchResult(outputJSON: encode(["error": "invalid URL"]),
                                          attachedImageBase64: nil)
            }
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
            // Give the browser a moment to render, then attach the screen.
            try? await Task.sleep(nanoseconds: 800_000_000)
            return await confirmWithScreenshot(["ok": true, "action": "open_url", "url": urlString])

        case "see_screen":
            let result = await ScreenCapture.shared.capture()
            return ToolDispatchResult(
                outputJSON: encode(result.metadata),
                attachedImageBase64: result.imageBase64
            )

        case "mouse_move":
            let x = number(args["x"]) ?? 0
            let y = number(args["y"]) ?? 0
            NSLog("Tool: mouse_move (img px \(x),\(y))")
            self.inputActivity?(true)
            InputSynth.moveCursor(imagePx: CGPoint(x: x, y: y))
            self.inputActivity?(false)
            return await confirmWithScreenshot(["ok": true, "action": "mouse_move"])

        case "mouse_click":
            let x = number(args["x"]) ?? 0
            let y = number(args["y"]) ?? 0
            let buttonStr = (args["button"] as? String) ?? "left"
            let button: CGMouseButton = (buttonStr == "right") ? .right : .left
            let count = (args["count"] as? Int) ?? 1
            NSLog("Tool: mouse_click \(buttonStr) ×\(count) (img px \(x),\(y))")
            self.inputActivity?(true)
            InputSynth.click(imagePx: CGPoint(x: x, y: y), button: button, count: count)
            try? await Task.sleep(nanoseconds: 250_000_000)
            self.inputActivity?(false)
            return await confirmWithScreenshot(["ok": true, "action": "mouse_click"])

        case "mouse_drag":
            let fx = number(args["from_x"]) ?? 0
            let fy = number(args["from_y"]) ?? 0
            let tx = number(args["to_x"])   ?? 0
            let ty = number(args["to_y"])   ?? 0
            let dur = (args["duration_ms"] as? Int) ?? 350
            NSLog("Tool: mouse_drag (img px \(fx),\(fy))→(\(tx),\(ty)) in \(dur)ms")
            self.inputActivity?(true)
            InputSynth.drag(fromPx: CGPoint(x: fx, y: fy),
                            toPx: CGPoint(x: tx, y: ty),
                            durationMs: dur)
            self.inputActivity?(false)
            return await confirmWithScreenshot(["ok": true, "action": "mouse_drag"])

        case "scroll":
            let dx = Int32((args["delta_x"] as? Int) ?? 0)
            let dy = Int32((args["delta_y"] as? Int) ?? 0)
            NSLog("Tool: scroll (\(dx),\(dy))")
            InputSynth.scroll(deltaX: dx, deltaY: dy)
            return await confirmWithScreenshot(["ok": true, "action": "scroll"])

        case "type_text":
            let text = (args["text"] as? String) ?? ""
            NSLog("Tool: type_text \(text.count) chars")
            self.inputActivity?(true)
            InputSynth.type(text)
            self.inputActivity?(false)
            return await confirmWithScreenshot(["ok": true, "action": "type_text"])

        case "press_key":
            let key = (args["key"] as? String) ?? ""
            let mods = (args["modifiers"] as? [String]) ?? []
            NSLog("Tool: press_key \(mods.joined(separator: "+"))+\(key)")
            InputSynth.pressKey(key, modifiers: mods)
            return await confirmWithScreenshot(["ok": true, "action": "press_key"])

        case "run_applescript":
            let script = (args["script"] as? String) ?? ""
            NSLog("Tool: run_applescript: \(script.prefix(120))")
            return ToolDispatchResult(outputJSON: encode(AppleScriptRunner.run(script)),
                                      attachedImageBase64: nil)

        case "run_shell":
            let cmd = (args["command"] as? String) ?? ""
            NSLog("Tool: run_shell: \(cmd.prefix(120))")
            let out = await ShellRunner.run(cmd)
            return ToolDispatchResult(outputJSON: encode(out), attachedImageBase64: nil)

        default:
            return ToolDispatchResult(outputJSON: encode(["error": "unknown tool \(name)"]),
                                      attachedImageBase64: nil)
        }
    }

    /// Wait briefly for the UI to settle, then capture the screen. Returns
    /// the original tool output dict plus an attached screenshot so the model
    /// can visually verify what its action did.
    private func confirmWithScreenshot(_ output: [String: Any]) async -> ToolDispatchResult {
        try? await Task.sleep(nanoseconds: 120_000_000)  // let UI redraw
        let shot = await ScreenCapture.shared.capture()
        var merged = output
        merged["screenshot"] = shot.metadata
        return ToolDispatchResult(outputJSON: encode(merged),
                                  attachedImageBase64: shot.imageBase64)
    }

    /// JSON numbers may arrive as Int or Double; normalize to Double.
    private func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int    { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String, let d = Double(s) { return d }
        return nil
    }


    private func encode(_ obj: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let s = String(data: data, encoding: .utf8) { return s }
        return "{}"
    }
}
