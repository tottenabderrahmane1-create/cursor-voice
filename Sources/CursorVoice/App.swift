import SwiftUI
import AppKit

@main
struct CursorVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            Button("Summon Orb") { appDelegate.coordinator.toggle() }
            Divider()
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",")
            Divider()
            Button("Quit Cursor Voice") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }

        Settings {
            SettingsView()
                .environmentObject(appDelegate.settings)
                .environmentObject(appDelegate.coordinator)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let settings = SettingsStore()
    lazy var coordinator: AppCoordinator = AppCoordinator(settings: settings)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        coordinator.start()
        // Trigger system permission prompts up front so they never appear
        // mid-conversation. Non-blocking — features degrade if declined.
        Task { @MainActor in await PermissionsOnboarding.requestAll() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }
}
