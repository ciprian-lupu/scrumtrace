import SwiftUI

@main
struct ScrumTraceApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    var body: some Scene {
        Settings {
            #if os(macOS)
            SettingsView(settings: appDelegate.controller.settings, controller: appDelegate.controller, navigation: appDelegate.mainPresenter.navigation.settings)
            #else
            Text("ScrumTrace is a macOS menu-bar app.")
            #endif
        }
        #if os(macOS)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Recording…") { appDelegate.startRecording(nil) }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.showSettingsWindow(nil) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                ForEach(MainSection.allCases) { section in
                    Button(section.title) { appDelegate.showMainWindow(section: section, source: .command) }
                        .keyboardShortcut(section.keyEquivalent, modifiers: .command)
                }
            }
        }
        #endif
    }
}
