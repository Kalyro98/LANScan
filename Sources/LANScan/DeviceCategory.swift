import SwiftUI

/// Gerätekategorie → bestimmt das angezeigte Symbol. Wird automatisch aus Hersteller
/// und Hostname geraten, kann vom User aber manuell überschrieben werden.
enum DeviceCategory: String, CaseIterable, Identifiable {
    case router, nas, server, computer, laptop, phone, tablet, watch
    case tv, speaker, printer, gameConsole, smartHome, light, camera
    case microcontroller, unknown

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .router:          return "wifi.router"
        case .nas:             return "externaldrive.connected.to.line.below"
        case .server:          return "server.rack"
        case .computer:        return "desktopcomputer"
        case .laptop:          return "laptopcomputer"
        case .phone:           return "iphone"
        case .tablet:          return "ipad"
        case .watch:           return "applewatch"
        case .tv:              return "tv"
        case .speaker:         return "hifispeaker"
        case .printer:         return "printer"
        case .gameConsole:     return "gamecontroller"
        case .smartHome:       return "homekit"
        case .light:           return "lightbulb"
        case .camera:          return "video"
        case .microcontroller: return "cpu"
        case .unknown:         return "questionmark.circle"
        }
    }

    var label: String {
        switch self {
        case .router:          return "Router"
        case .nas:             return "NAS"
        case .server:          return "Server"
        case .computer:        return "Computer"
        case .laptop:          return "Laptop"
        case .phone:           return "Smartphone"
        case .tablet:          return "Tablet"
        case .watch:           return "Smartwatch"
        case .tv:              return "Fernseher"
        case .speaker:         return "Lautsprecher"
        case .printer:         return "Drucker"
        case .gameConsole:     return "Spielekonsole"
        case .smartHome:       return "Smart-Home"
        case .light:           return "Licht"
        case .camera:          return "Kamera"
        case .microcontroller: return "Mikrocontroller"
        case .unknown:         return "Unbekannt"
        }
    }

    var tint: Color {
        switch self {
        case .router:          return .blue
        case .nas, .server:    return .indigo
        case .computer, .laptop: return .gray
        case .phone, .tablet, .watch: return .teal
        case .tv:              return .purple
        case .speaker:         return .pink
        case .printer:         return .brown
        case .gameConsole:     return .green
        case .smartHome:       return .orange
        case .light:           return .yellow
        case .camera:          return .red
        case .microcontroller: return .mint
        case .unknown:         return .secondary
        }
    }

    /// Errät die Kategorie aus Hostname (stärkstes Signal) und Hersteller.
    static func guess(vendor: String?, hostname: String?) -> DeviceCategory {
        let host = (hostname ?? "").lowercased()
        let v = (vendor ?? "").lowercased()

        // 1) Hostname-Schlüsselwörter – am aussagekräftigsten.
        let hostRules: [(String, DeviceCategory)] = [
            ("iphone", .phone), ("ipad", .tablet), ("macbook", .laptop),
            ("imac", .computer), ("macmini", .computer), ("macstudio", .computer),
            ("macpro", .computer), ("applewatch", .watch), ("appletv", .tv),
            ("xbox", .gameConsole), ("playstation", .gameConsole), ("ps5", .gameConsole),
            ("ps4", .gameConsole), ("nintendo", .gameConsole),
            ("diskstation", .nas), ("synology", .nas), ("unraid", .nas), ("tower", .nas),
            ("truenas", .nas), ("freenas", .nas),
            ("proxmox", .server), ("esxi", .server),
            ("fritz", .router), ("router", .router), ("gateway", .router),
            ("raspberry", .microcontroller), ("raspberrypi", .microcontroller),
            ("esp", .microcontroller),
            ("printer", .printer), ("brother", .printer), ("epson", .printer),
            ("bravia", .tv), ("samsungtv", .tv), ("lgtv", .tv), ("roku", .tv), ("shield", .tv),
            ("sonos", .speaker), ("homepod", .speaker), ("echo", .speaker), ("alexa", .speaker),
            ("hue", .light), ("lamp", .light), ("light", .light), ("bulb", .light),
            ("nanoleaf", .light),
            ("cam", .camera), ("camera", .camera)
        ]
        for (kw, cat) in hostRules where host.contains(kw) { return cat }

        // 2) Hersteller-Schlüsselwörter.
        let vendorRules: [(String, DeviceCategory)] = [
            ("zyxel", .router), ("avm", .router), ("fritz", .router), ("cisco", .router),
            ("netgear", .router), ("tp-link", .router), ("eero", .router), ("ubiquiti", .router),
            ("mikrotik", .router), ("d-link", .router), ("aruba", .router), ("ruckus", .router),
            ("synology", .nas), ("qnap", .nas), ("western digital", .nas), ("drobo", .nas),
            ("supermicro", .server),
            ("sonos", .speaker), ("bose", .speaker), ("harman", .speaker), ("denon", .speaker),
            ("sony interactive", .gameConsole), ("nintendo", .gameConsole),
            ("brother", .printer), ("hewlett", .printer), ("canon", .printer),
            ("epson", .printer), ("lexmark", .printer), ("kyocera", .printer),
            ("signify", .light), ("philips lighting", .light), ("lifx", .light),
            ("intellirocks", .light), ("nanoleaf", .light),
            ("hikvision", .camera), ("dahua", .camera), ("axis", .camera),
            ("reolink", .camera), ("wyze", .camera),
            ("tuya", .smartHome), ("shelly", .smartHome), ("sonoff", .smartHome),
            ("broadlink", .smartHome), ("roborock", .smartHome), ("ecovacs", .smartHome),
            ("irobot", .smartHome), ("shenzhen", .smartHome),
            ("espressif", .microcontroller), ("raspberry", .microcontroller),
            ("lg electron", .tv), ("vizio", .tv), ("tcl", .tv),
            ("dell", .computer), ("lenovo", .computer), ("gigabyte", .computer),
            ("asrock", .computer), ("msi", .computer), ("intel", .computer),
            ("xiaomi", .phone), ("oneplus", .phone), ("oppo", .phone), ("vivo", .phone),
            ("huawei", .phone)
        ]
        for (kw, cat) in vendorRules where v.contains(kw) { return cat }

        // 3) Mehrdeutige Hersteller anhand des Hostnamens verfeinern.
        if v.contains("apple") {
            return .computer   // Mac als neutrale Annahme; Hostname-Regeln gingen vor
        }
        if v.contains("samsung") { return .phone }
        if v.contains("google") { return .smartHome }
        if v.contains("amazon") { return .speaker }

        return .unknown
    }
}
