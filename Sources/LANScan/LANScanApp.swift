import SwiftUI

@main
struct LANScanApp: App {
    var body: some Scene {
        Window("LANScan", id: "main") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}   // kein "Neues Fenster"
        }
    }
}
