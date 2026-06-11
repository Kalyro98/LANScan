import Foundation

/// Lädt die Wireshark-Hersteller-DB im Hintergrund und schreibt sie in den Cache.
/// Robust gegen fehlendes Internet, Captive-Portals und Timeouts: schlägt der
/// Versuch fehl, bleibt einfach die vorhandene (gecachte/eingebettete) DB aktiv.
enum OUIUpdater {

    private static let sourceURL = URL(string: "https://www.wireshark.org/download/automated/data/manuf")!
    private static let lastUpdateKey = "OUILastUpdate"
    private static let throttle: TimeInterval = 24 * 60 * 60   // höchstens 1×/Tag laden

    /// Aktualisiert die DB, falls seit dem letzten Erfolg genug Zeit vergangen ist.
    /// Liefert `true`, wenn ein frischerer Cache geschrieben wurde.
    @discardableResult
    static func updateIfNeeded() async -> Bool {
        let cacheExists = FileManager.default.fileExists(atPath: OUIDatabase.cacheURL.path)
        if cacheExists, let last = UserDefaults.standard.object(forKey: lastUpdateKey) as? Date,
           Date().timeIntervalSince(last) < throttle {
            return false   // noch frisch genug
        }

        do {
            var req = URLRequest(url: sourceURL)
            req.timeoutInterval = 12                    // kein Internet → schneller Abbruch
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: req)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let text = String(data: data, encoding: .utf8) else { return false }

            let converted = convert(text)
            // Plausibilitätsprüfung – schützt vor Captive-Portal-HTML o. Ä.
            guard converted.count > 10_000 else { return false }

            let tsv = converted.joined(separator: "\n")
            try tsv.write(to: OUIDatabase.cacheURL, atomically: true, encoding: .utf8)
            UserDefaults.standard.set(Date(), forKey: lastUpdateKey)
            OUIDatabase.reload()
            return true
        } catch {
            return false   // offline / Timeout / Fehler → still ignorieren
        }
    }

    /// Konvertiert das Wireshark-`manuf`-Format in kompakte `HEXKEY⇥Name`-Zeilen.
    /// (Entspricht dem ursprünglichen Python-Konverter.)
    private static func convert(_ text: String) -> [String] {
        var out: [String] = []
        out.reserveCapacity(60_000)

        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if raw.first == "#" { continue }
            let parts = raw.split(separator: "\t")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }

            let prefix = parts[0]
            let name = String((parts.count >= 3 ? parts[2] : parts[1]).prefix(40))

            var bits = 24
            var mac = prefix
            if let slash = prefix.firstIndex(of: "/") {
                bits = Int(prefix[prefix.index(after: slash)...]) ?? 24
                mac = String(prefix[..<slash])
            }
            let hex = mac.replacingOccurrences(of: ":", with: "").uppercased()
            let nibbles = bits / 4
            guard hex.count >= nibbles, nibbles >= 6 else { continue }
            out.append("\(String(hex.prefix(nibbles)))\t\(name)")
        }
        return out
    }
}
