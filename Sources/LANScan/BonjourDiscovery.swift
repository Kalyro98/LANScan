import Foundation
import Network

/// Stellt sicher, dass eine Continuation genau einmal resumed wird, auch wenn
/// mehrere Pfade (Ergebnis, Timeout, Fehler) konkurrieren.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Entdeckt Geräte per Bonjour/mDNS: liefert pro IPv4-Adresse den annoncierten
/// Anzeigenamen, die Dienste und ggf. den Port der Web-Oberfläche.
/// WICHTIG: `serviceTypes` muss mit dem NSBonjourServices-Array in build.sh
/// synchron bleiben (macOS Local Network Privacy).
enum BonjourDiscovery {

    static let serviceTypes = [
        "_http._tcp", "_https._tcp", "_ssh._tcp", "_smb._tcp", "_ipp._tcp",
        "_airplay._tcp", "_raop._tcp", "_hap._tcp", "_googlecast._tcp",
        "_spotify-connect._tcp"
    ]

    struct Info {
        var name: String?
        var services: Set<String> = []
        var httpPort: UInt16?
        var httpsPort: UInt16?
    }

    /// Browst alle Diensttypen für `duration` Sekunden und löst die gefundenen
    /// Endpoints per kurzem TCP-Connect zu IPv4-Adresse + Port auf.
    static func discover(duration: TimeInterval = 3.0) async -> [String: Info] {
        let queue = DispatchQueue(label: "lanscan.bonjour")
        let browsers: [(NWBrowser, String)] = serviceTypes.map { type in
            let b = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
            b.start(queue: queue)
            return (b, type)
        }
        try? await Task.sleep(for: .seconds(duration))

        var found: [(name: String, type: String, endpoint: NWEndpoint)] = []
        for (b, type) in browsers {
            for r in b.browseResults {
                if case let .service(name, _, _, _) = r.endpoint {
                    found.append((name, type, r.endpoint))
                }
            }
            b.cancel()
        }

        return await withTaskGroup(of: (String, UInt16, String, String)?.self) { group in
            for f in found {
                group.addTask {
                    guard let (ip, port) = await resolveIPv4(f.endpoint) else { return nil }
                    return (ip, port, f.name, f.type)
                }
            }
            var map: [String: Info] = [:]
            for await item in group {
                guard let (ip, port, name, type) = item else { continue }
                var info = map[ip] ?? Info()
                if info.name == nil { info.name = name }
                info.services.insert(shortType(type))
                if type == "_http._tcp" { info.httpPort = port }
                if type == "_https._tcp" { info.httpsPort = port }
                map[ip] = info
            }
            return map
        }
    }

    /// "_http._tcp" → "http"
    private static func shortType(_ type: String) -> String {
        String(type.dropFirst().prefix(while: { $0 != "." }))
    }

    /// Löst einen Bonjour-Service-Endpoint zu IPv4 + Port auf, indem kurz eine
    /// TCP-Verbindung geöffnet wird (der Dienst lauscht ohnehin auf dem Port).
    private static func resolveIPv4(_ endpoint: NWEndpoint,
                                    timeout: TimeInterval = 2.0) async -> (String, UInt16)? {
        await withCheckedContinuation { cont in
            let conn = NWConnection(to: endpoint, using: .tcp)
            let once = Once()
            let finish: ((String, UInt16)?) -> Void = { result in
                if once.claim() {
                    conn.cancel()
                    cont.resume(returning: result)
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = conn.currentPath?.remoteEndpoint,
                       case let .ipv4(addr) = host {
                        // Mögliches "%interface"-Suffix (Link-local) abschneiden.
                        let ip = "\(addr)".split(separator: "%").first.map(String.init) ?? "\(addr)"
                        finish((ip, port.rawValue))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                finish(nil)
            }
        }
    }
}
