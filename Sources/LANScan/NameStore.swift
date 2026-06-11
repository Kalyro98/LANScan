import Foundation

/// Persistiert benutzerdefinierte Geräte-Eigenschaften (Name + Symbol), gemappt auf
/// einen Schlüssel. Schlüssel-Logik (Hybrid): bei eindeutiger MAC die MAC (überlebt
/// IP-Wechsel); teilen sich mehrere IPs eine MAC, der spezifische "mac@ip"-Schlüssel.
/// Speicherort: ~/Library/Application Support/LANScan/names.json
final class NameStore {
    static let shared = NameStore()

    struct Record: Codable {
        var name: String?
        var icon: String?   // DeviceCategory.rawValue
        var isEmpty: Bool { (name?.isEmpty ?? true) && (icon?.isEmpty ?? true) }
    }

    private let fileURL: URL
    private var records: [String: Record] = [:]

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LANScan", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("names.json")
        load()
    }

    // MARK: - Name

    func name(forMac mac: String, ip: String) -> String? {
        record(mac, ip)?.name
    }

    func setName(_ name: String?, forMac mac: String, ip: String, macHasMultipleIPs: Bool) {
        let key = keyFor(mac, ip, shared: macHasMultipleIPs)
        update(key) { $0.name = clean(name) }
    }

    // MARK: - Symbol

    func category(forMac mac: String, ip: String) -> DeviceCategory? {
        guard let raw = record(mac, ip)?.icon else { return nil }
        return DeviceCategory(rawValue: raw)
    }

    func setCategory(_ cat: DeviceCategory?, forMac mac: String, ip: String, macHasMultipleIPs: Bool) {
        let key = keyFor(mac, ip, shared: macHasMultipleIPs)
        update(key) { $0.icon = cat?.rawValue }
    }

    /// Entfernt sämtliche gespeicherten Eigenschaften für dieses Gerät.
    func clear(forMac mac: String, ip: String) {
        records.removeValue(forKey: specificKey(mac, ip))
        records.removeValue(forKey: mac.lowercased())
        save()
    }

    // MARK: - Intern

    /// Lookup mit Hybrid-Fallback: spezifischer Schlüssel vor allgemeinem MAC-Schlüssel.
    /// Felder werden einzeln gemischt, damit z. B. ein MAC-weiter Name und ein
    /// IP-spezifisches Symbol koexistieren können.
    private func record(_ mac: String, _ ip: String) -> Record? {
        let specific = records[specificKey(mac, ip)]
        let general = records[mac.lowercased()]
        if specific == nil && general == nil { return nil }
        return Record(name: specific?.name ?? general?.name,
                      icon: specific?.icon ?? general?.icon)
    }

    private func update(_ key: String, _ mutate: (inout Record) -> Void) {
        var rec = records[key] ?? Record()
        mutate(&rec)
        if rec.isEmpty { records.removeValue(forKey: key) } else { records[key] = rec }
        save()
    }

    private func keyFor(_ mac: String, _ ip: String, shared: Bool) -> String {
        shared ? specificKey(mac, ip) : mac.lowercased()
    }

    private func specificKey(_ mac: String, _ ip: String) -> String {
        "\(mac.lowercased())@\(ip)"
    }

    private func clean(_ s: String?) -> String? {
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty ?? true) ? nil : t
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        // Neues Format: [String: Record]
        if let dict = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = dict
            return
        }
        // Migration vom alten Format: [String: String] (nur Namen)
        if let old = try? JSONDecoder().decode([String: String].self, from: data) {
            records = old.mapValues { Record(name: $0, icon: nil) }
            save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
