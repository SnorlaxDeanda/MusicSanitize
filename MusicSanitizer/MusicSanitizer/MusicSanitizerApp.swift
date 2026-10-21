import SwiftUI

@main
struct MusicSanitizerApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Library") {
                Button("Open Folder…") {
                    appState.requestFolderSelection()
                }
                .keyboardShortcut("o")
                Divider()
                Button("Start Scan") {
                    Task { await appState.scan() }
                }
                .keyboardShortcut("r")
                .disabled(appState.scanRoot == nil || appState.isScanning)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}

