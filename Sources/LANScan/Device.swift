import Foundation

/// Ein im Netzwerk gefundenes Gerät. Identität = IP-Adresse (im LAN eindeutig).
/// Hinweis: Mehrere IPs können sich eine MAC teilen (z. B. Docker-Container im
/// ipvlan-Modus auf einem Unraid-Host) – daher pro IP eine Zeile, nicht pro MAC.
struct Device: Identifiable, Hashable {
    var id: String { ip }           // IP als eindeutige Identität
    var mac: String                 // normalisiert: "aa:bb:cc:dd:ee:ff"
    var ip: String
    var hostname: String?           // via Reverse-DNS / mDNS ermittelt
    var customName: String?         // vom User vergeben (persistent)
    var vendor: String?             // via OUI-Lookup
    var autoCategory: DeviceCategory = .unknown   // automatisch geraten
    var customCategory: DeviceCategory?           // vom User gewählt (überschreibt)
    var isOnline: Bool = true

    /// Tatsächlich angezeigte Kategorie: manuelle Wahl > automatische Erkennung.
    var category: DeviceCategory { customCategory ?? autoCategory }

    /// Anzeigename: eigener Name > Hostname > Hersteller > Platzhalter.
    var displayName: String {
        if let c = customName, !c.isEmpty { return c }
        if let h = hostname, !h.isEmpty { return h }
        if let v = vendor, !v.isEmpty { return v }
        return "Unbekanntes Gerät"
    }

    /// True, wenn das Gerät noch keinen "echten" Namen hat (nur Hersteller/Platzhalter).
    var isUnnamed: Bool {
        (customName?.isEmpty ?? true) && (hostname?.isEmpty ?? true)
    }

    /// Sortierschlüssel: IP numerisch korrekt (192.168.1.9 vor .10).
    var ipSortKey: UInt32 {
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return 0 }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }
}
