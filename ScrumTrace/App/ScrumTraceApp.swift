import SwiftUI

@main
struct ScrumTraceApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    var body: some Scene {
        Settings {
            #if os(macOS)
            SettingsView(settings: appDelegate.controller.settings, controller: appDelegate.controller)
            #else
            Text("ScrumTrace is a macOS menu-bar app.")
            #endif
        }
    }
}
