import AppKit
import AVFoundation
import Combine

/// Owns the long-lived pieces (hotkey, orb window, realtime client, wake word)
/// and routes user intent (hotkey press, wake word, dismissal) between them.
@MainActor
final class AppCoordinator: ObservableObject {
    let settings: SettingsStore
    let orbState = OrbState()
    // Lazy — creating its NSHostingView during SwiftUI scene-graph construction
    // crashes AttributeGraph with WindowToolbarStyleEnvironment.
    lazy var cursorHalo: CursorHalo = CursorHalo()

    private let hotkey = GlobalHotkey()
    private let wakeWord = WakeWordDetector()
    private var orbController: OrbWindowController?
    private var realtime: RealtimeClient?
    private var cancellables = Set<AnyCancellable>()

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func start() {
        orbController = OrbWindowController(state: orbState, requestDismiss: { [weak self] in
            self?.deactivate()
        })

        hotkey.onPress = { [weak self] in self?.toggle() }
        applyHotkey()

        settings.$hotkey
            .dropFirst()
            .sink { [weak self] _ in self?.applyHotkey() }
            .store(in: &cancellables)

        settings.$wakeWordEnabled
            .sink { [weak self] enabled in self?.applyWakeWord(enabled: enabled) }
            .store(in: &cancellables)

        // Reconnect the realtime session whenever model or voice changes,
        // so picker selections take effect immediately on the open orb.
        settings.$model
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.reconnectIfActive() }
            .store(in: &cancellables)

        settings.$voice
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.reconnectIfActive() }
            .store(in: &cancellables)

        wakeWord.onDetect = { [weak self] in
            Task { @MainActor in self?.activate() }
        }
    }

    func stop() {
        deactivate()
        hotkey.unregister()
        wakeWord.stop()
    }

    // MARK: - Activation

    func toggle() {
        if orbState.isVisible { deactivate() } else { activate() }
    }

    func activate() {
        NSLog("Coordinator: activate()")
        guard !orbState.isVisible else { return }
        guard let key = settings.apiKey, !key.isEmpty else {
            NSLog("Coordinator: no API key set; beeping and opening settings")
            NSSound.beep()
            settings.openSettings()
            return
        }
        // Wake-word and the realtime audio engine both want the input node,
        // so park the detector while the orb is up.
        wakeWord.stop()

        // Mic was requested at startup via PermissionsOnboarding.
        // If the user denied, the audio engine will report the failure;
        // we don't gate activation on a redundant request here.
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .denied || status == .restricted {
            orbState.connection = .error("microphone denied — enable in System Settings → Privacy")
        }
        orbController?.present()
        cursorHalo.start()                 // halo follows cursor the whole session
        cursorHalo.active = false          // dimmed at rest, intense during input synth
        startRealtime(apiKey: key)
    }

    func deactivate() {
        guard orbState.isVisible || realtime != nil else { return }  // already torn down
        orbController?.dismiss()
        cursorHalo.stop()
        realtime?.disconnect()
        realtime = nil
        if settings.wakeWordEnabled {
            wakeWord.start(phrase: settings.wakeWordPhrase)
        }
    }

    /// Tear down and rebuild the realtime client with current settings,
    /// only if a session is currently active. Called when the user changes
    /// model or voice in the picker so the new selection takes effect now.
    private func reconnectIfActive() {
        guard orbState.isVisible, let key = settings.apiKey else { return }
        NSLog("Coordinator: reconnecting realtime (model=\(settings.model) voice=\(settings.voice))")
        realtime?.disconnect()
        realtime = nil
        orbState.connection = .connecting
        startRealtime(apiKey: key)
    }

    // MARK: - Realtime wiring

    private func startRealtime(apiKey: String) {
        let client = RealtimeClient(apiKey: apiKey,
                                    model: settings.model,
                                    voice: settings.voice,
                                    instructions: Self.buildInstructions())
        client.onStateChange = { [weak self] state in
            Task { @MainActor in self?.orbState.connection = state }
        }
        client.onAudioLevel = { [weak self] level in
            Task { @MainActor in self?.orbState.audioLevel = level }
        }
        client.onTranscript = { [weak self] text in
            Task { @MainActor in self?.orbState.lastTranscript = text }
        }
        client.onInputActivity = { [weak self] active in
            Task { @MainActor in
                self?.orbState.aiControlling = active
                // Halo stays visible the whole session; intensity flips with activity.
                self?.cursorHalo.active = active
            }
        }
        client.onToolStart = { [weak self] label in
            Task { @MainActor in self?.orbState.activeTool = label }
        }
        client.onToolEnd = { [weak self] in
            Task { @MainActor in self?.orbState.activeTool = nil }
        }
        client.connect()
        realtime = client
    }

    // MARK: - Hotkey / wake word config

    private func applyHotkey() {
        hotkey.register(keyCode: settings.hotkey.keyCode,
                        modifiers: settings.hotkey.carbonModifiers)
    }

    private func applyWakeWord(enabled: Bool) {
        if enabled { wakeWord.start(phrase: settings.wakeWordPhrase) }
        else { wakeWord.stop() }
    }

    /// Build the system instructions for this session, appending any
    /// long-term memories so the model starts with that context.
    private static func buildInstructions() -> String {
        var s = baseSystemInstructions
        let memories = MemoryStore.shared.all()
        if !memories.isEmpty {
            s += "\n\nWHAT YOU REMEMBER ABOUT THIS USER (from past sessions):\n"
            for m in memories.suffix(50) {
                s += "• \(m.content)\n"
            }
            s += "\nDon't recite this list. Apply it silently when relevant."
        }
        return s
    }

    private static let baseSystemInstructions = """
    You are Cursor Voice — a desktop voice assistant living next to the user's cursor.

    SPEAKING (be terse):
    • Execute silently. Never say "let me", "I'll", "first I'll", "now I'm going to".
    • Only speak when (a) the task is finished — one short sentence, (b) you need clarification,
      or (c) something failed.
    • For COMPLEX or LONG tasks (more than ~3 tool calls), say a short status hint BEFORE you start
      ("checking that for you", "searching now") — then go silent until done.
    • For simple/atomic tasks, no preamble at all. Just do it.

    CANCEL / NEVERMIND:
    • If the user says "nevermind", "stop", "cancel", "wait", "actually", "forget it", or otherwise
      retracts the request — halt immediately. Do NOT run any pending tool. Just say "ok" or
      stay silent. The user's word overrides any plan you had.

    GROUND TRUTH = THE SCREEN:
    • Before any action that depends on what's currently on screen — clicking, typing into a field,
      reading state, replying about a UI — call see_screen FIRST. Don't guess from memory.
    • Your own windows (orb + halo) are excluded from screenshots, so you see the real UI.
    • Re-call see_screen between steps if the UI may have changed.

    LATEST INFORMATION:
    • Your training data is stale. For ANY question about current events, prices, scores, releases,
      versions, or anything time-sensitive, use web_search(query) to get live results, then optionally
      fetch_url(url) to read a specific page. Don't pretend to know — look it up.

    TOOL CHOICE — pick the most direct path (in this priority order):
    1. Live info / news / current facts → web_search, then fetch_url for full page.
    2. Web navigation → open_url (NEVER click through Safari to navigate).
    3. macOS app control (Music, Mail, Calendar, Finder, Messages, Notes, etc.) → run_applescript.
    4. Clicking a labeled UI element (button, link, menu item, text field): use
       list_ui_elements (AX tree) and then click_element by name. THIS IS PIXEL-PERFECT
       AND ALMOST ALWAYS WORKS — prefer it over mouse_click whenever the target has a
       visible label / accessibility title. Most native macOS UI is fully covered.
    5. Address bar in any browser → press_key "l" with ["cmd"].
    6. Switch apps → press_key "tab" with ["cmd"], or AppleScript activate.
    7. Shell / system → run_shell.
    8. mouse_click / mouse_drag are the ABSOLUTE LAST RESORT — only when AX is empty
       (canvas, game, web image, custom-painted UI). When forced into this path:
         a. see_screen first (own windows excluded).
         b. Coordinates are image pixels, top-left origin, exact scale of the screenshot.
         c. Aim CENTER of the target.

    VERIFICATION (this is how you stop missing things):
    • After EVERY action, a fresh screenshot is auto-attached. COMPARE it to the previous one.
    • Did the expected change happen? If yes → continue. If no → look again, identify why,
      adjust. Don't blindly keep clicking the same coords.
    • For text fields: after typing, verify your text appears in the field on the screenshot.

    MEMORY:
    • You have persistent long-term memory across sessions via `remember` and `recall`.
    • Use remember for stable, useful facts: preferred apps, names, project paths, common
      shortcuts the user uses, recurring tasks. Not for ephemeral state.
    • If the user mentions something they've told you before, recall(query) first.

    SAFETY: never rm -rf, never sudo.
    """
}
