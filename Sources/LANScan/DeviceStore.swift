import Foundation

/// Persistiert die zuletzt bekannte Geräteliste, damit bekannte Geräte direkt nach
/// dem App-Start (grau, mit „zuletzt gesehen") erscheinen statt erst nach dem Scan.
/// Custom-Namen/Symbole liegen weiterhin im NameStore – keine Doppelhaltung.
/// Speicherort: ~/Library/Application Support/LANScan/devices.json
final class DeviceStore {
    static let shared = DeviceStore()

    struct Record: Codable {
        var ip: String
        var mac: String
        var hostname: String?
        var vendor: String?
        var lastSeen: Date?
    }

    private let fileURL: URL

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LANScan", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("devices.json")
    }

    func load() -> [Record] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    func save(_ devices: [Device]) {
        let records = devices.map {
            Record(ip: $0.ip, mac: $0.mac, hostname: $0.hostname,
                   vendor: $0.vendor, lastSeen: $0.lastSeen)
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
