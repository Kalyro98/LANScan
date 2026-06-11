# LANScan

## Ziel
Kleines macOS-Tool, das Geräte im aktuell verbundenen WLAN/LAN scannt und auflistet:
**Gerätename, MAC-Adresse, IP-Adresse** (+ Hersteller). Geräte ohne Namen können
vom User umbenannt werden; die Namen bleiben persistent (gemappt auf die MAC).

## Tech-Stack
- Swift 6.3 / SwiftUI (macOS 14+), gebaut mit SPM (kein Xcode-Projekt nötig)
- Scan-Pipeline: Ping-Sweep (`/sbin/ping`) → ARP-Tabelle (`/usr/sbin/arp -a -n`)
  → Reverse-DNS/mDNS (`getnameinfo`)
- Subnetz-Ermittlung via `getifaddrs` + Default-Route (`/sbin/route`)
- Persistenz: `~/Library/Application Support/LANScan/names.json` (MAC → Name)

## Pfad
`/Users/dino/Desktop/Claude/Homelab/LANScan`

## Veröffentlichung
- **Öffentliches Repo:** https://github.com/Kalyro98/LANScan (eigenes Standalone-Repo,
  per subtree split aus dem privaten homelab-Repo ausgelagert; dort jetzt ignoriert)
- **Release-Prozess:** `./build.sh` → DMG aus `dist/` als **`LANScan.dmg`** (exakt dieser
  Name!) ans Release anhängen — der README-Link zeigt auf `releases/latest/download/LANScan.dmg`.
  Mit gh CLI: `~/.local/bin/gh release create v<X.Y> <dmg> --title "LANScan <X.Y>" --notes "…"`
- Bei neuer Version: `VERSION` in `build.sh` bumpen + Git-Tag im Release.

## Bauen / Ausführen
- `swift build` — schneller Debug-Build
- `./build.sh` — Release-Build → `dist/LANScan.app` + `dist/LANScan-1.0.dmg`
  (erzeugt Icon, schreibt Info.plist, signiert ad-hoc, baut DMG)
- Installation: DMG öffnen → App nach „Programme" ziehen

## Aktueller Stand
v1.1: alle v1.0-Features plus sortierbare Spalten, ⌘R-Rescan, persistente
Geräteliste mit „zuletzt gesehen", Auto-Rescan mit Benachrichtigung bei neuen
Geräten, Bonjour-Discovery (Namen + Dienste), „Im Browser öffnen" und Wake-on-LAN.
v1.0 fand im Heimnetz (192.168.1.0/24) 26 Geräte; v1.1 manuell zu verifizieren.

## Konventionen & Invarianten
- **Geräte-Identität = IP-Adresse** (`Device.id = ip`). Grund: mehrere IPs können
  sich **eine MAC** teilen (Docker-Container im ipvlan-Modus auf Unraid → Host `.41`
  + Container teilen die NIC-MAC). MAC-basierte Dedup verschluckte sonst alle bis auf
  die erste IP. `readARP` dedupliziert pro IP, Merge/Offline-Tracking läuft über die IP.
- **Custom-Namen & Symbole — Hybrid-Schlüssel** (`NameStore`, speichert `Record{name,icon}`):
  bei eindeutiger MAC unter `mac` (überlebt DHCP-IP-Wechsel); teilt sich die MAC mehrere
  IPs, unter `mac@ip` (jeder Container/jede IP einzeln). Lookup mischt Felder: `mac@ip` vor
  `mac` pro Feld. Altes Format (`[String:String]` nur Namen) wird beim Laden migriert.
- **Gerätesymbole** (`DeviceCategory`): SF-Symbol + Farbe + Label pro Kategorie.
  `guess(vendor:hostname:)` rät automatisch (Hostname-Schlüsselwörter vor Hersteller-
  Schlüsselwörtern). Manuell überschreibbar via Kontextmenü „Symbol" oder im Bearbeiten-Sheet;
  „Automatisch" setzt `customCategory = nil` zurück. Angezeigt wird `customCategory ?? autoCategory`.
  `autoCategory` wird nach der Hostname-Auflösung und bei `refreshVendors()` (DB-Update) neu berechnet.
- MAC wird auf `aa:bb:cc:dd:ee:ff` normalisiert (Oktette zweistellig, lowercase) —
  `arp` liefert teils einstellige Oktette (`e` statt `0e`).
- App ist **nicht sandboxed** (sonst kein Process-Aufruf von ping/arp). Ad-hoc-Signatur.
- macOS Local Network Privacy: beim ersten Scan kann ein Berechtigungs-Dialog kommen.
  `NSLocalNetworkUsageDescription` ist in der Info.plist gesetzt.
- Sehr große Subnetze (Prefix < /22) werden für den Sweep auf das eigene /24 gekappt,
  um nicht zehntausende Pings zu starten.
- **Hersteller-DB**: echte Wireshark/IEEE-OUI-Liste, Format `HEXKEY⇥Name` (~57k Einträge).
  Lookup nimmt die längste Übereinstimmung: /36 (9 Nibbles) → /28 (7) → /24 (6).
  Quellen-Priorität (`OUIDatabase.Store.loadTable`): **Cache** (`~/Library/Application
  Support/LANScan/oui.tsv`) > **Bundle** (`Resources/oui.tsv`, via `build.sh` eingebettet,
  Dev-Fallback `#filePath`). Thread-sicher über `NSLock`; externe API bleibt `OUIDatabase.vendor(for:)`.
- **Auto-Update** (`OUIUpdater.updateIfNeeded`, beim Start aus `ContentView.task`, nach dem Scan):
  lädt `manuf` von Wireshark, konvertiert in Swift (= Ersatz des Python-Snippets), schreibt
  Cache **atomar** und ruft `OUIDatabase.reload()` + `scanner.refreshVendors()`.
  - **Throttle**: max. 1×/24 h (`OUILastUpdate` in UserDefaults); Zeitstempel wird nur bei Erfolg gesetzt.
  - **Offline-sicher**: 12 s Timeout; jeder Fehler/Timeout → `catch` → `false`, Cache bleibt unberührt.
  - **Captive-Portal-Schutz**: Ergebnis muss > 10 000 Einträge haben, sonst verworfen.
  - Manuell erzwingen: `defaults delete ch.kalyro.lanscan OUILastUpdate` + Neustart.
- Zufalls-MACs (locally administered, 2. Nibble ∈ {2,6,A,E}) → „Private Adresse".
- Broadcast/Multicast (ff:ff…, 01:00:5e, 33:33, .255, 224.0.0.0/4) werden aus den
  ARP-Ergebnissen gefiltert; `readARP` nimmt nur Zeilen des aktiven Interfaces.
- **Geräte-Persistenz** (`DeviceStore`, `devices.json`): speichert ip/mac/hostname/
  vendor/lastSeen nach jedem Scan; beim Start wird die Liste als offline geladen
  (Vendor wird gegen die aktuelle OUI-DB neu aufgelöst). Custom-Namen/Symbole bleiben
  ausschließlich im `NameStore` — keine Doppelhaltung.
- **Auto-Rescan**: `@AppStorage` `AutoRescanEnabled`/`AutoRescanInterval` (Minuten),
  Task-Schleife in `NetworkScanner.setAutoRescan`. Benachrichtigungen
  (`NewDeviceNotifier`) nur bei Scans **mit** Historie (sonst würde der allererste
  Scan 26× feuern); Guard `Bundle.main.bundleIdentifier != nil`, weil
  `UNUserNotificationCenter` bei `swift run` (kein Bundle) crasht.
- **Bonjour** (`BonjourDiscovery`): browst eine feste Typenliste ~3 s parallel zum
  Ping-Sweep; Endpoint→IP-Auflösung per kurzem TCP-Connect. Die Typenliste
  (`BonjourDiscovery.serviceTypes`) muss mit `NSBonjourServices` in `build.sh`
  **synchron** bleiben (macOS Local Network Privacy). Bonjour-Name ist nur Fallback,
  Reverse-DNS gewinnt.
- **„Im Browser öffnen"**: `Device.webURL` — Bonjour-annoncierter `_http`/`_https`-Port
  schlägt den parallelen TCP-Probe auf 80/443 (0,7 s Timeout).
- **Wake-on-LAN** (`WakeOnLAN`): Magic Packet an Subnetz-Broadcast (/24-Annahme aus
  der Geräte-IP) und 255.255.255.255, UDP Port 9. Kontextmenü-Eintrag für **alle**
  Geräte (nicht nur offline) — der Online-Status kann bis zum nächsten Scan veraltet
  sein, und ein Magic Packet an ein laufendes Gerät ist harmlos.
- `Once` (in `BonjourDiscovery.swift`): geteilter Guard, damit Continuations bei
  Ergebnis/Timeout-Rennen genau einmal resumen (genutzt von Reverse-DNS, TCP-Probe,
  Bonjour-Auflösung).
