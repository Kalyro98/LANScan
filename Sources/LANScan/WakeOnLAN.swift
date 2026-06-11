import Foundation
import Darwin

/// Sendet ein Wake-on-LAN Magic Packet (6×FF + 16×MAC) als UDP-Broadcast an Port 9.
enum WakeOnLAN {

    /// Schickt das Paket an die angegebene Broadcast-Adresse.
    @discardableResult
    static func wake(mac: String, broadcast: String) -> Bool {
        guard let payload = magicPacket(mac: mac) else { return false }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(9).bigEndian
        addr.sin_addr.s_addr = inet_addr(broadcast)

        let sent = payload.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) { aptr in
                aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, buf.baseAddress, payload.count, 0,
                           sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == payload.count
    }

    private static func magicPacket(mac: String) -> Data? {
        let octets = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard octets.count == 6 else { return nil }
        var data = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { data.append(contentsOf: octets) }
        return data
    }
}
