import Foundation

/// Hersteller-Lookup über die IEEE/Wireshark-OUI-Datenbank.
/// Datenquelle (Priorität): aktualisierter Cache > eingebettetes Bundle.
/// Unterstützt MA-L (/24), MA-M (/28) und MA-S (/36) – längste Übereinstimmung gewinnt.
enum OUIDatabase {

    static func vendor(for mac: String) -> String? { Store.shared.vendor(for: mac) }

    /// Lädt die Tabelle neu (z. B. nachdem der Updater einen frischeren Cache geschrieben hat).
    static func reload() { Store.shared.reload() }

    static var entryCount: Int { Store.shared.count }

    /// Pfad der gecachten (aktualisierten) DB.
    static var cacheURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LANScan", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("oui.tsv")
    }

    // MARK: - Thread-sicherer Speicher

    final class Store {
        static let shared = Store()
        private var table: [String: String] = [:]
        private let lock = NSLock()

        init() { reload() }

        var count: Int { lock.lock(); defer { lock.unlock() }; return table.count }

        func vendor(for mac: String) -> String? {
            let hex = mac.replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: "-", with: "")
                .uppercased()
            guard hex.count >= 6 else { return nil }

            // Locally administered (Zufalls-MAC): 2. Nibble in {2,6,A,E}.
            let secondNibble = hex[hex.index(hex.startIndex, offsetBy: 1)]
            if "26AE".contains(secondNibble) { return "Private Adresse" }

            lock.lock(); defer { lock.unlock() }
            for len in [9, 7, 6] where hex.count >= len {
                if let name = table[String(hex.prefix(len))] { return name }
            }
            return nil
        }

        func reload() {
            let t = Self.loadTable()
            lock.lock(); table = t; lock.unlock()
        }

        /// Liest die beste verfügbare Quelle (Cache bevorzugt, sonst Bundle).
        private static func loadTable() -> [String: String] {
            let sources = [OUIDatabase.cacheURL, bundleURL()].compactMap { $0 }
            for url in sources {
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    let dict = parse(text)
                    if dict.count > 1000 { return dict }   // plausible DB
                }
            }
            return [:]
        }

        private static func parse(_ text: String) -> [String: String] {
            var dict = [String: String](minimumCapacity: 60000)
            for line in text.split(separator: "\n") {
                guard let tab = line.firstIndex(of: "\t") else { continue }
                dict[String(line[..<tab])] = String(line[line.index(after: tab)...])
            }
            return dict
        }

        private static func bundleURL() -> URL? {
            if let u = Bundle.main.url(forResource: "oui", withExtension: "tsv") { return u }
            // Dev-Fallback für `swift run`.
            let dev = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/oui.tsv")
            return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
        }
    }
}
