import Foundation
import Darwin
import Network

@MainActor
final class NetworkScanner: ObservableObject {
    @Published var devices: [Device] = []
    @Published var isScanning = false
    @Published var progress: Double = 0          // 0…1
    @Published var statusText = "Bereit"
    @Published var subnetText = ""

    init() {
        // Bekannte Geräte aus dem letzten Lauf sofort (offline) anzeigen.
        devices = DeviceStore.shared.load().map { rec in
            var d = Device(mac: rec.mac, ip: rec.ip)
            d.hostname = rec.hostname
            d.vendor = OUIDatabase.vendor(for: rec.mac) ?? rec.vendor
            d.customName = NameStore.shared.name(forMac: rec.mac, ip: rec.ip)
            d.customCategory = NameStore.shared.category(forMac: rec.mac, ip: rec.ip)
            d.autoCategory = DeviceCategory.guess(vendor: d.vendor, hostname: d.hostname)
            d.isOnline = false
            d.lastSeen = rec.lastSeen
            return d
        }
        .sorted { $0.ipSortKey < $1.ipSortKey }
    }

    /// Startet einen vollständigen Scan des aktuellen Subnetzes.
    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        progress = 0
        statusText = "Netzwerk wird ermittelt…"

        // Für die „Neues Gerät"-Erkennung: Stand vor diesem Scan.
        let knownIPs = Set(devices.map(\.ip))
        let hadHistory = !devices.isEmpty

        guard let info = Self.currentSubnet() else {
            statusText = "Kein aktives Netzwerk gefunden"
            isScanning = false
            return
        }
        subnetText = "\(info.network)/\(info.prefix) · \(info.interface)"

        // 1) Ping-Sweep über alle Host-IPs (füllt den ARP-Cache);
        //    parallel dazu Bonjour-Dienste browsen.
        async let bonjourDiscovery = BonjourDiscovery.discover(duration: 3.0)
        let hosts = info.hostAddresses
        statusText = "Scanne \(hosts.count) Adressen…"
        await pingSweep(hosts)
        let bonjour = await bonjourDiscovery

        // 2) ARP-Tabelle auslesen → IP/MAC-Paare.
        statusText = "Lese ARP-Tabelle…"
        let arpEntries = Self.readARP(interface: info.interface)

        // 3) Geräte zusammenbauen (Hersteller + gespeicherter Name).
        var found: [Device] = arpEntries.map { entry in
            var d = Device(mac: entry.mac, ip: entry.ip)
            d.vendor = OUIDatabase.vendor(for: entry.mac)
            d.customName = NameStore.shared.name(forMac: entry.mac, ip: entry.ip)
            d.customCategory = NameStore.shared.category(forMac: entry.mac, ip: entry.ip)
            d.isOnline = true
            d.lastSeen = Date()
            return d
        }

        // 4) Reverse-DNS / mDNS für Hostnamen (parallel) + Web-Oberflächen-Probe.
        statusText = "Löse Hostnamen auf…"
        let foundIPs = found.map { $0.ip }
        async let webProbe = Self.probeWebUIs(foundIPs)
        let names = await Self.resolveHostnames(foundIPs)
        let webURLs = await webProbe
        for i in found.indices {
            let ip = found[i].ip
            if let n = names[ip] { found[i].hostname = n }
            let bj = bonjour[ip]
            // Bonjour-Name als Fallback, wenn Reverse-DNS nichts lieferte.
            if found[i].hostname == nil, let bn = bj?.name { found[i].hostname = bn }
            found[i].services = bj?.services ?? []
            // Web-UI: Bonjour-annoncierter Port schlägt den 80/443-Probe.
            if let p = bj?.httpPort {
                found[i].webURL = URL(string: p == 80 ? "http://\(ip)" : "http://\(ip):\(p)")
            } else if let p = bj?.httpsPort {
                found[i].webURL = URL(string: p == 443 ? "https://\(ip)" : "https://\(ip):\(p)")
            } else {
                found[i].webURL = webURLs[ip]
            }
            found[i].autoCategory = DeviceCategory.guess(vendor: found[i].vendor,
                                                         hostname: found[i].hostname)
        }

        // 5) Mit vorherigem Stand mergen: nicht mehr sichtbare Geräte als offline behalten.
        //    Schlüssel = IP (mehrere IPs können sich eine MAC teilen).
        var merged: [String: Device] = [:]
        for old in devices { merged[old.ip] = { var o = old; o.isOnline = false; return o }() }
        for d in found { merged[d.ip] = d }

        devices = merged.values.sorted { $0.ipSortKey < $1.ipSortKey }
        DeviceStore.shared.save(devices)

        // Beim allerersten Scan (keine Historie) nicht für jedes Gerät benachrichtigen.
        if hadHistory {
            NewDeviceNotifier.notify(about: found.filter { !knownIPs.contains($0.ip) })
        }
        progress = 1
        let online = devices.filter { $0.isOnline }.count
        statusText = "\(online) Gerät\(online == 1 ? "" : "e") online"
        isScanning = false
    }

    // MARK: - Auto-Rescan

    private var autoTask: Task<Void, Never>?

    /// (De-)Aktiviert den periodischen Hintergrund-Scan.
    func setAutoRescan(enabled: Bool, intervalMinutes: Int) {
        autoTask?.cancel()
        autoTask = nil
        guard enabled, intervalMinutes > 0 else { return }
        autoTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double(intervalMinutes) * 60))
                guard !Task.isCancelled, let self else { return }
                if !self.isScanning { await self.scan() }
            }
        }
    }

    /// Setzt/ändert den benutzerdefinierten Namen eines Geräts (persistent).
    func rename(_ device: Device, to name: String?) {
        let macShared = devices.filter { $0.mac == device.mac }.count > 1
        NameStore.shared.setName(name, forMac: device.mac, ip: device.ip,
                                 macHasMultipleIPs: macShared)
        if let idx = devices.firstIndex(where: { $0.id == device.id }) {
            // Leer/Whitespace → nil, sonst bleibt ein ""-Name zurück (fett dargestellt).
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            devices[idx].customName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
    }

    /// Ordnet Hersteller und automatische Kategorie neu zu – z. B. nach DB-Update.
    func refreshVendors() {
        for i in devices.indices {
            devices[i].vendor = OUIDatabase.vendor(for: devices[i].mac)
            devices[i].autoCategory = DeviceCategory.guess(vendor: devices[i].vendor,
                                                           hostname: devices[i].hostname)
        }
    }

    /// Setzt/entfernt das manuell gewählte Symbol eines Geräts (nil = automatisch).
    func setCategory(_ category: DeviceCategory?, for device: Device) {
        let macShared = devices.filter { $0.mac == device.mac }.count > 1
        NameStore.shared.setCategory(category, forMac: device.mac, ip: device.ip,
                                     macHasMultipleIPs: macShared)
        if let idx = devices.firstIndex(where: { $0.id == device.id }) {
            devices[idx].customCategory = category
        }
    }

    func forget(_ device: Device) {
        NameStore.shared.clear(forMac: device.mac, ip: device.ip)
        devices.removeAll { $0.id == device.id && !$0.isOnline }
        if let idx = devices.firstIndex(where: { $0.id == device.id }) {
            devices[idx].customName = nil
            devices[idx].customCategory = nil
        }
        DeviceStore.shared.save(devices)
    }

    /// Schickt ein Wake-on-LAN Magic Packet an ein (offline) Gerät.
    func wake(_ device: Device) {
        var targets = ["255.255.255.255"]
        var parts = device.ip.split(separator: ".").map(String.init)
        if parts.count == 4 {
            parts[3] = "255"
            targets.append(parts.joined(separator: "."))   // Subnetz-Broadcast (/24-Annahme)
        }
        var ok = false
        for t in targets where WakeOnLAN.wake(mac: device.mac, broadcast: t) { ok = true }
        statusText = ok
            ? "Wake-on-LAN an \(device.displayName) gesendet"
            : "Wake-on-LAN fehlgeschlagen"
    }

    // MARK: - Web-Oberflächen-Probe

    /// Prüft parallel, welche Geräte auf Port 80/443 antworten → "Im Browser öffnen".
    nonisolated private static func probeWebUIs(_ ips: [String]) async -> [String: URL] {
        await withTaskGroup(of: (String, URL?).self) { group in
            for ip in ips {
                group.addTask {
                    if await tcpOpen(ip, 80) { return (ip, URL(string: "http://\(ip)")) }
                    if await tcpOpen(ip, 443) { return (ip, URL(string: "https://\(ip)")) }
                    return (ip, nil)
                }
            }
            var map: [String: URL] = [:]
            for await (ip, url) in group {
                if let url { map[ip] = url }
            }
            return map
        }
    }

    nonisolated private static func tcpOpen(_ ip: String, _ port: UInt16,
                                            timeout: TimeInterval = 0.7) async -> Bool {
        guard let addr = IPv4Address(ip), let nwPort = NWEndpoint.Port(rawValue: port) else {
            return false
        }
        return await withCheckedContinuation { cont in
            let conn = NWConnection(host: .ipv4(addr), port: nwPort, using: .tcp)
            let once = Once()
            let finish: (Bool) -> Void = { open in
                if once.claim() {
                    conn.cancel()
                    cont.resume(returning: open)
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                finish(false)
            }
        }
    }

    // MARK: - Ping-Sweep

    private func pingSweep(_ hosts: [String]) async {
        let total = max(hosts.count, 1)
        var done = 0
        let maxConcurrent = 48

        await withTaskGroup(of: Void.self) { group in
            var running = 0
            var iterator = hosts.makeIterator()

            func addNext() {
                guard let ip = iterator.next() else { return }
                running += 1
                group.addTask { Self.ping(ip) }
            }

            for _ in 0..<min(maxConcurrent, hosts.count) { addNext() }
            for await _ in group {
                running -= 1
                done += 1
                self.progress = Double(done) / Double(total) * 0.85
                addNext()
            }
        }
    }

    /// Ein einzelner Ping (1 Paket, kurzer Timeout). Ergebnis egal – es geht nur darum,
    /// den ARP-Request auszulösen.
    nonisolated private static func ping(_ ip: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/ping")
        p.arguments = ["-c", "1", "-W", "300", "-t", "1", "-q", ip]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: - ARP

    struct ARPEntry { let ip: String; let mac: String }

    nonisolated private static func readARP(interface: String) -> [ARPEntry] {
        let output = shell("/usr/sbin/arp", ["-a", "-n"])
        var result: [ARPEntry] = []
        var seen = Set<String>()

        // Zeilenformat: "? (192.168.1.1) at f0:87:56:e:67:a8 on en0 ifscope [ethernet]"
        for line in output.split(separator: "\n") {
            let s = String(line)
            guard s.contains("(") , s.contains(") at ") else { continue }
            guard let ipStart = s.firstIndex(of: "("),
                  let ipEnd = s.firstIndex(of: ")") else { continue }
            let ip = String(s[s.index(after: ipStart)..<ipEnd])

            guard let atRange = s.range(of: ") at ") else { continue }
            let after = s[atRange.upperBound...]
            let tokens = after.split(separator: " ")
            // Nur Einträge des aktiven Interfaces ("… at <mac> on <iface> …").
            guard tokens.count >= 3, tokens[1] == "on", tokens[2] == interface else { continue }
            let macRaw = String(tokens[0])
            if macRaw.contains("incomplete") || macRaw.isEmpty { continue }
            guard let mac = normalizeMAC(macRaw) else { continue }
            if isMulticastOrBroadcast(ip: ip, mac: mac) { continue }
            if seen.contains(ip) { continue }     // pro IP genau ein Eintrag (MAC darf mehrfach)
            seen.insert(ip)
            result.append(ARPEntry(ip: ip, mac: mac))
        }
        return result
    }

    /// Filtert Broadcast-/Multicast-Einträge (keine echten Geräte).
    nonisolated private static func isMulticastOrBroadcast(ip: String, mac: String) -> Bool {
        if mac == "ff:ff:ff:ff:ff:ff" { return true }     // Broadcast
        if mac.hasPrefix("01:00:5e") { return true }       // IPv4-Multicast
        if mac.hasPrefix("33:33") { return true }          // IPv6-Multicast
        if ip.hasSuffix(".255") { return true }            // Subnetz-Broadcast
        if let first = ip.split(separator: ".").first, let n = Int(first), n >= 224 {
            return true                                     // 224.0.0.0/4 Multicast
        }
        return false
    }

    /// Normalisiert MAC auf "aa:bb:cc:dd:ee:ff" (Oktette zweistellig, lowercase).
    nonisolated private static func normalizeMAC(_ raw: String) -> String? {
        let parts = raw.split(separator: ":")
        guard parts.count == 6 else { return nil }
        var octets: [String] = []
        for p in parts {
            guard p.count <= 2, UInt8(p, radix: 16) != nil else { return nil }
            octets.append(String(format: "%02x", UInt8(p, radix: 16)!))
        }
        return octets.joined(separator: ":")
    }

    // MARK: - Reverse-DNS / mDNS

    nonisolated private static func resolveHostnames(_ ips: [String]) async -> [String: String] {
        await withTaskGroup(of: (String, String?).self) { group in
            for ip in ips {
                group.addTask { (ip, await reverseLookup(ip, timeout: 2.5)) }
            }
            var map: [String: String] = [:]
            for await (ip, name) in group {
                if let name { map[ip] = name }
            }
            return map
        }
    }

    /// Verlagert das blockierende getnameinfo auf eine GCD-Queue und begrenzt die
    /// Wartezeit – nicht antwortende DNS-Server würden sonst das Scan-Ende einfrieren.
    /// Ein hängender Lookup läuft im Hintergrund aus; resumed wird genau einmal.
    nonisolated private static func reverseLookup(_ ip: String, timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { cont in
            let once = Once()
            DispatchQueue.global(qos: .utility).async {
                let name = blockingReverseLookup(ip)
                if once.claim() { cont.resume(returning: name) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if once.claim() { cont.resume(returning: nil) }
            }
        }
    }

    nonisolated private static func blockingReverseLookup(_ ip: String) -> String? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr(ip)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size),
                            &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard rc == 0 else { return nil }
        var name = String(cString: host)
        if name.hasSuffix(".") { name.removeLast() }
        // Reine IP zurück = kein echter Name.
        if name == ip || name.isEmpty { return nil }
        return name
    }

    // MARK: - Subnetz-Ermittlung

    struct SubnetInfo {
        let interface: String
        let localIP: String
        let network: String
        let prefix: Int
        let hostAddresses: [String]
    }

    nonisolated static func currentSubnet() -> SubnetInfo? {
        // Aktives Interface aus der Default-Route.
        let routeOut = shell("/sbin/route", ["-n", "get", "default"])
        var iface = "en0"
        for line in routeOut.split(separator: "\n") {
            if line.contains("interface:") {
                iface = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "en0"
            }
        }

        guard let (ip, mask) = interfaceIPv4(iface) else { return nil }
        let ipParts = ip.split(separator: ".").compactMap { UInt32($0) }
        let maskParts = mask.split(separator: ".").compactMap { UInt32($0) }
        guard ipParts.count == 4, maskParts.count == 4 else { return nil }

        let ipNum = (ipParts[0] << 24) | (ipParts[1] << 16) | (ipParts[2] << 8) | ipParts[3]
        let maskNum = (maskParts[0] << 24) | (maskParts[1] << 16) | (maskParts[2] << 8) | maskParts[3]
        let netNum = ipNum & maskNum
        let prefix = maskNum.nonzeroBitCount

        // Hostanzahl bestimmen; sehr große Netze auf das eigene /24 begrenzen.
        let hostBits = 32 - prefix
        var effectiveNet = netNum
        var effectivePrefix = prefix
        if hostBits > 10 {                       // > 1022 Hosts → auf /24 kappen
            effectivePrefix = 24
            effectiveNet = ipNum & 0xFFFFFF00
        }
        let count = (UInt32(1) << (32 - effectivePrefix))
        var hosts: [String] = []
        if count >= 2 {
            for offset in 1..<(count - 1) {
                let h = effectiveNet + offset
                if h == ipNum { continue }       // sich selbst nicht pingen
                hosts.append(ipString(h))
            }
        }

        return SubnetInfo(interface: iface, localIP: ip,
                          network: ipString(netNum), prefix: prefix,
                          hostAddresses: hosts)
    }

    /// IPv4-Adresse + Netzmaske eines Interfaces via getifaddrs.
    nonisolated private static func interfaceIPv4(_ iface: String) -> (ip: String, mask: String)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let addr = cur.pointee.ifa_addr
            let name = String(cString: cur.pointee.ifa_name)
            if name == iface, addr?.pointee.sa_family == UInt8(AF_INET) {
                let ip = sockaddrToString(addr)
                let mask = sockaddrToString(cur.pointee.ifa_netmask)
                if let ip, let mask { return (ip, mask) }
            }
            ptr = cur.pointee.ifa_next
        }
        return nil
    }

    nonisolated private static func sockaddrToString(_ sa: UnsafeMutablePointer<sockaddr>?) -> String? {
        guard let sa else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                             &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        guard rc == 0 else { return nil }
        return String(cString: host)
    }

    nonisolated private static func ipString(_ n: UInt32) -> String {
        "\((n >> 24) & 0xFF).\((n >> 16) & 0xFF).\((n >> 8) & 0xFF).\(n & 0xFF)"
    }

    // MARK: - Shell-Helfer

    nonisolated private static func shell(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
