import SwiftUI

@main
struct EaselApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var workspace = Workspace()
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup("Easel") {
            ContentView()
                .environmentObject(workspace)
                .environmentObject(settings)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Photos…") { workspace.showOpenPanel() }
                    .keyboardShortcut("o")
                Button("Import from Memory Card…") { workspace.chooseFromMemoryCard() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save JPGs") { workspace.save() }
                    .keyboardShortcut("s")
                Button("Show Saved Files in Finder") { workspace.revealOutputFolder() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandMenu("Photo") {
                Button("Previous Photo") { workspace.selectPrevious() }
                    .keyboardShortcut("[")
                Button("Next Photo") { workspace.selectNext() }
                    .keyboardShortcut("]")
                Divider()
                Button("Auto-Find Edges") { workspace.findEdges() }
                    .keyboardShortcut("e")
                Button("Reset Corners") { workspace.resetCorners() }
                Divider()
                Button("Switch Before / After") { workspace.toggleBeforeAfter() }
                .keyboardShortcut("b")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed so the app shows in the Dock and gets a menu bar when run straight from Xcode.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Saves your photo list one last time before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            Workspace.current?.saveLibraryNow()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
