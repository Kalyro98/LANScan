import SwiftUI

@main
struct LANScanApp: App {
    // Auf App-Ebene, damit Menübefehle (⌘R) denselben Scanner steuern.
    @StateObject private var scanner = NetworkScanner()

    var body: some Scene {
        Window("LANScan", id: "main") {
            ContentView(scanner: scanner)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}   // kein "Neues Fenster"
            CommandGroup(after: .toolbar) {
                Button("Erneut scannen") {
                    Task { await scanner.scan() }
                }
                .keyboardShortcut("r")
                .disabled(scanner.isScanning)
            }
        }
    }
}
