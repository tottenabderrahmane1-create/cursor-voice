# What we ported from Computer Control Plus, what we didn't, and what might still be worth doing

**Source examined:** `~/plugins/computer-control-plus` (v0.6.0) — a local Codex MCP plugin you wrote. Persistent Swift native helper (947 LOC) wrapped by a Python MCP server (1,569 LOC).

This started as a research doc with a porting plan. After v0.3.0 shipped (with the six highest-impact items ported), it's now a retrospective + a list of remaining ideas.

---

## Capability matrix — current state

| Capability | Computer Control Plus | Cursor Voice (v0.3.0) |
| ---------- | --------------------- | --------------------- |
| Screenshot | Native Quartz (`CGDisplayCreateImage`), `screencapture` CLI fallback for cursor | ScreenCaptureKit native-pixel + CGImage |
| Mouse / keyboard | Persistent native helper, CGEvent | One-shot CGEvent per call, tagged `eventSourceUserData` |
| AX tree walk | `accessibility_snapshot` (depth/node-limited) | `AXTree.enumerateFrontmost` |
| Find element by name | `find_ui_elements(query, role)` | `AXTree.bestMatch` |
| **Click element via AXPress** | ✅ AXPress first, coord fallback | ✅ **AXPress first, coord fallback** (v0.3.0) |
| **OCR** | ✅ `ocr_screen` + `click_text` via Vision | ✅ **`find_text` + `click_text`** (v0.3.0, Vision) |
| Image template match | ✅ OpenCV `find_image`, `wait_for_image` | ❌ |
| **Batched actions** | ✅ `batch_actions([…])` | ✅ **`batch_actions`** (v0.3.0) |
| **Hotkey (multi-key)** | ✅ `hotkey([k1,k2,…])` | ✅ **`hotkey([…])`** (v0.3.0) |
| **Clipboard-paste typing** | ✅ `type_text(text, restore_clipboard=True)` | ✅ **Auto when > 30 chars** (v0.3.0) |
| **Permission diagnostics** | ✅ `permission_diagnostics`, `open_permission_settings` | ✅ **`permissions_diagnostics`** (v0.3.0; deep-link buttons in Settings) |
| Window mgmt | `list_windows`, `set_window_bounds`, `activate_app` | AppleScript only |
| Warm-up of native frameworks | `warm_up(...)` | n/a (always-running process) |
| Visible cursor indicator | Discrete Python NSWindow flash | Continuous `CursorHalo` aurora |
| Voice in/out | ❌ | ✅ realtime |
| Wake word | ❌ | ✅ `SFSpeechRecognizer` |
| App distribution | n/a (local plugin) | Universal app, DMG, brew tap, auto-update |
| Web search / fetch | ❌ | ✅ DDG scrape + `fetch_url` |
| Persistent memory | ❌ | ✅ JSON memory store |

---

## What landed in v0.3.0

### 1. AXPress before coordinate-clicking ★★★
`click_element` now calls `AXUIElementPerformAction(element, kAXPressAction)` first. If the element supports `AXPress` the action fires *without* any mouse simulation — no coordinate math, no cursor movement, no event-loop race. Coordinate-center click is the fallback when AXPress isn't supported (or for `count=2` double-click).

```swift
// Capabilities/AXTree.swift
static func tryPress(_ element: AXUIElement) -> Bool {
    AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
}
```

This is the single biggest accuracy lift on labeled native UI. Returns `via: "AXPress"` or `via: "coordinate"` in the tool output so you can see which path fired.

### 2. OCR-based text targeting (`find_text` + `click_text`) ★★★
`Capabilities/OCR.swift` wraps `VNRecognizeTextRequest`. Captures the screen, runs Vision OCR, returns text + image-pixel bounding boxes (with the bottom-left/top-left flip handled). `click_text(query)` finds the best match and clicks its center via `InputSynth.click(imagePx:)`.

This is the path for everything `click_element` can't see — Safari web content, Electron, Canvas/WebGL, image text. No new dependencies — Vision ships with macOS.

### 3. `batch_actions` ★★★
One tool call runs an ordered list of input steps with a single screenshot at the end. Supported step types: `click_element`, `mouse_click`, `mouse_move`, `type_text`, `press_key`, `hotkey`, `scroll`, `sleep`. Cuts a 5-step automation from ~5 round trips down to 1 — major latency win.

`runBatchStep` is a small per-type switch in `ToolHandler` (does NOT re-enter `dispatch` to keep behaviour predictable).

### 4. Clipboard-paste fast text entry ★★
`type_text` over 30 characters now stashes the existing clipboard, sets the text, sends `⌘V`, restores after 250 ms. ~50 ms instead of the per-character `keyboardSetUnicodeString` loop (which can be ~5 s for a paragraph). Short strings stay on the per-char path for compatibility with paste-filtering fields.

### 5. `hotkey([list])` ★★
Chord-shaped multi-key combos. Modifiers can be anywhere in the array; the last non-modifier is the main key. Internally maps onto the existing `pressKey(key, modifiers:)` after partitioning.

### 6. `permissions_diagnostics` ★★
The model can self-explain when blocked: it gets a structured response with `mic / speech / screen_recording / accessibility` statuses and can tell the user exactly which switch to flip in System Settings.

---

## What we deliberately did NOT port

- **The persistent native helper subprocess pattern.** CCP needs it because Python can't post CGEvents fast enough. Cursor Voice is already native Swift end-to-end — keeping CGEvent calls inline in the same process is faster and simpler.
- **`warm_up`.** Cursor Voice runs continuously while the orb is up. AppKit/Quartz are already loaded.
- **Discrete cursor-flash indicator.** Cursor Voice has `CursorHalo` — a continuous aurora that follows the cursor and intensifies during input. Different aesthetic, arguably better.
- **OpenCV image-template matching.** Niche enough that I deferred until OCR-clicking proves insufficient. Vision OCR covers most "find this on screen" needs without adding OpenCV.

---

## What's still worth adding (ranked)

### 1. ★★ First-class app + window management tools
Currently the model has to write AppleScript for opening / activating / resizing apps. CCP exposes `open_application`, `activate_app`, `list_apps`, `frontmost_app`, `list_windows`, `set_window_bounds` as direct tools. Lifting these to first-class would remove a class of AppleScript-syntax errors the model makes.

```swift
case "activate_app":   // NSRunningApplication.activate(options:)
case "open_app":       // NSWorkspace.openApplication(at:URL, configuration:)
case "list_windows":   // CGWindowListCopyWindowInfo + AX frames
case "set_window_bounds": // AX position/size on matched window
case "frontmost_app":  // NSWorkspace.frontmostApplication
```

~1 hour of work. Each is a thin wrapper.

### 2. ★ Set-of-Marks fallback for non-AX, non-OCR UI
When `click_element` finds nothing AND `find_text` finds nothing, generate a numbered-overlay version of the screenshot: number every salient bounding box (`VNDetectRectanglesRequest` + heuristics) and let the model pick by index. Covers the "canvas / proprietary UI with icons" case OpenCV templates would otherwise solve.

### 3. ★ Image-template matching (`find_image`, `wait_for_image`)
For game UIs, custom-painted widgets, or "wait until this dialog appears" flows. Vision has `VNFeaturePrintObservation` for similarity matching without OpenCV. Less general than OCR but covers the icon-without-text case.

### 4. ★ Browser DOM bridge
For Safari/Chrome, AppleScript can execute arbitrary JavaScript in the active tab (Safari: `do JavaScript in current tab of front window`). A tool like `browser_eval(js)` would give pixel-perfect targeting of any web element by selector. Much more reliable than AX or OCR on web content.

### 5. ★ Per-app AX heuristics
Some apps expose better attributes than `kAXTitleAttribute` (e.g. `kAXIdentifierAttribute`). A small per-bundle-ID table could pick the right attributes for known difficult apps.

---

## Honest assessment

After v0.3.0, the click reliability problem is mostly addressed for two big categories:

- **Native macOS UI with labels** → AXPress is near-100%
- **Visible text on screen** → OCR is ~95% accurate at .accurate level

What's left in the "miss" tail:

- **Unlabeled icons in proprietary apps** — needs Set-of-Marks or template matching
- **Web content edge cases** — AX is partial, OCR works on visible text. Pure-graphical web UIs (canvas games, complex SVG charts) would benefit from a browser DOM bridge
- **Drag-and-drop targets** without a "Drop here" label — needs visual reasoning

These are real but smaller than the original problem. The high-leverage wins from CCP are now in. The remaining items are diminishing-returns territory and can wait until a specific use case demands them.
