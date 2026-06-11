import Foundation
import Darwin

@MainActor
final class NetworkScanner: ObservableObject {
    @Published var devices: [Device] = []
    @Published var isScanning = false
    @Published var progress: Double = 0          // 0…1
    @Published var statusText = "Bereit"
    @Published var subnetText = ""

    /// Startet einen vollständigen Scan des aktuellen Subnetzes.
    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        progress = 0
        statusText = "Netzwerk wird ermittelt…"

        guard let info = Self.currentSubnet() else {
            statusText = "Kein aktives Netzwerk gefunden"
            isScanning = false
            return
        }
        subnetText = "\(info.network)/\(info.prefix) · \(info.interface)"

        // 1) Ping-Sweep über alle Host-IPs (füllt den ARP-Cache).
        let hosts = info.hostAddresses
        statusText = "Scanne \(hosts.count) Adressen…"
        await pingSweep(hosts)

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
            return d
        }

        // 4) Reverse-DNS / mDNS für Hostnamen (parallel).
        statusText = "Löse Hostnamen auf…"
        let names = await Self.resolveHostnames(found.map { $0.ip })
        for i in found.indices {
            if let n = names[found[i].ip] { found[i].hostname = n }
            found[i].autoCategory = DeviceCategory.guess(vendor: found[i].vendor,
                                                         hostname: found[i].hostname)
        }

        // 5) Mit vorherigem Stand mergen: nicht mehr sichtbare Geräte als offline behalten.
        //    Schlüssel = IP (mehrere IPs können sich eine MAC teilen).
        var merged: [String: Device] = [:]
        for old in devices { merged[old.ip] = { var o = old; o.isOnline = false; return o }() }
        for d in found { merged[d.ip] = d }

        devices = merged.values.sorted { $0.ipSortKey < $1.ipSortKey }
        progress = 1
        let online = devices.filter { $0.isOnline }.count
        statusText = "\(online) Gerät\(online == 1 ? "" : "e") online"
        isScanning = false
    }

    /// Setzt/ändert den benutzerdefinierten Namen eines Geräts (persistent).
    func rename(_ device: Device, to name: String?) {
        let macShared = devices.filter { $0.mac == device.mac }.count > 1
        NameStore.shared.setName(name, forMac: device.mac, ip: device.ip,
                                 macHasMultipleIPs: macShared)
        if let idx = devices.firstIndex(where: { $0.id == device.id }) {
            devices[idx].customName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
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
            let macRaw = after.split(separator: " ").first.map(String.init) ?? ""
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
                group.addTask { (ip, reverseLookup(ip)) }
            }
            var map: [String: String] = [:]
            for await (ip, name) in group {
                if let name { map[ip] = name }
            }
            return map
        }
    }

    nonisolated private static func reverseLookup(_ ip: String) -> String? {
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
