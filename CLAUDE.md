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

## Bauen / Ausführen
- `swift build` — schneller Debug-Build
- `./build.sh` — Release-Build → `dist/LANScan.app` + `dist/LANScan-1.0.dmg`
  (erzeugt Icon, schreibt Info.plist, signiert ad-hoc, baut DMG)
- Installation: DMG öffnen → App nach „Programme" ziehen

## Aktueller Stand
v1.0 fertig & getestet: findet im Heimnetz (192.168.1.0/24) 26 Geräte.
GUI mit Tabelle, Live-Fortschritt, Suche, „nur unbenannte"-Filter, Umbenennen
per Stift/Doppelklick/Kontextmenü, IP/MAC kopieren, Offline-Geräte als grau markiert.

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
  ARP-Ergebnissen gefiltert.
