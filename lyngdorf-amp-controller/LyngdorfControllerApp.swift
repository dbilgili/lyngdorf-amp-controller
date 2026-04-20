import SwiftUI

@main
struct LyngdorfControllerApp: App {
    @StateObject private var ampManager = LyngdorfManager()

    var body: some Scene {
        MenuBarExtra {
            MainView(ampManager: ampManager)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "hifispeaker.fill")
                if ampManager.statusMessage == "Awake" {
                    Text(ampManager.currentVolume)
                        .font(.system(.caption, design: .monospaced))
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
