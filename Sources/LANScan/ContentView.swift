import SwiftUI

struct ContentView: View {
    @StateObject private var scanner = NetworkScanner()
    @State private var search = ""
    @State private var renameTarget: Device?
    @State private var renameText = ""
    @State private var showUnnamedOnly = false

    private var filtered: [Device] {
        scanner.devices.filter { d in
            if showUnnamedOnly && !d.isUnnamed { return false }
            guard !search.isEmpty else { return true }
            let q = search.lowercased()
            return d.displayName.lowercased().contains(q)
                || d.ip.contains(q)
                || d.mac.contains(q)
                || (d.vendor?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 420)
        .task {
            await scanner.scan()
            // Hersteller-DB im Hintergrund aktualisieren (offline einfach übersprungen).
            if await OUIUpdater.updateIfNeeded() {
                scanner.refreshVendors()
            }
        }
        .sheet(item: $renameTarget) { device in
            renameSheet(device)
        }
    }

    // MARK: - Kopfbereich

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                Task { await scanner.scan() }
            } label: {
                Label(scanner.isScanning ? "Scanne…" : "Scannen",
                      systemImage: "antenna.radiowaves.left.and.right")
            }
            .disabled(scanner.isScanning)

            if scanner.isScanning {
                ProgressView(value: scanner.progress)
                    .frame(width: 140)
            }

            Toggle(isOn: $showUnnamedOnly) {
                Text("Nur unbenannte")
            }
            .toggleStyle(.checkbox)

            Spacer()

            TextField("Suchen", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Tabelle

    private var table: some View {
        Table(filtered) {
            TableColumn("") { d in
                Circle()
                    .fill(d.isOnline ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 9, height: 9)
                    .help(d.isOnline ? "Online" : "Zuletzt gesehen (offline)")
            }
            .width(20)

            TableColumn("Name") { d in
                HStack(spacing: 7) {
                    Image(systemName: d.category.symbol)
                        .foregroundStyle(d.category.tint)
                        .frame(width: 18)
                        .help(d.category.label)
                    Text(d.displayName)
                        .fontWeight(d.customName != nil ? .semibold : .regular)
                        .foregroundStyle(d.isUnnamed ? Color.secondary : Color.primary)
                }
            }
            .width(min: 160, ideal: 220)

            TableColumn("IP-Adresse") { d in
                Text(d.ip).monospaced()
            }
            .width(min: 110, ideal: 130)

            TableColumn("MAC-Adresse") { d in
                Text(d.mac).monospaced().foregroundStyle(.secondary)
            }
            .width(min: 130, ideal: 150)

            TableColumn("Hersteller") { d in
                Text(d.vendor ?? "—").foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 140)

            TableColumn("") { d in
                Button {
                    beginRename(d)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Umbenennen")
            }
            .width(34)
        }
        .contextMenu(forSelectionType: Device.ID.self) { ids in
            if let id = ids.first, let d = scanner.devices.first(where: { $0.id == id }) {
                Button("Umbenennen…") { beginRename(d) }
                if d.customName != nil {
                    Button("Eigenen Namen entfernen") { scanner.rename(d, to: nil) }
                }
                Menu("Symbol") {
                    Button {
                        scanner.setCategory(nil, for: d)
                    } label: {
                        Label("Automatisch (\(d.autoCategory.label))",
                              systemImage: d.customCategory == nil ? "checkmark" : d.autoCategory.symbol)
                    }
                    Divider()
                    ForEach(DeviceCategory.allCases) { cat in
                        Button {
                            scanner.setCategory(cat, for: d)
                        } label: {
                            Label(cat.label,
                                  systemImage: d.customCategory == cat ? "checkmark" : cat.symbol)
                        }
                    }
                }
                Button("IP kopieren") { copy(d.ip) }
                Button("MAC kopieren") { copy(d.mac) }
                if !d.isOnline {
                    Divider()
                    Button("Aus Liste entfernen", role: .destructive) { scanner.forget(d) }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, let d = scanner.devices.first(where: { $0.id == id }) {
                beginRename(d)
            }
        }
    }

    // MARK: - Fußzeile

    private var footer: some View {
        HStack {
            Text(scanner.statusText)
                .foregroundStyle(.secondary)
            Spacer()
            if !scanner.subnetText.isEmpty {
                Text(scanner.subnetText)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: - Umbenennen-Sheet

    private func renameSheet(_ device: Device) -> some View {
        // Aktuellen Stand aus dem Scanner lesen, damit die Symbolwahl live mitläuft.
        let current = scanner.devices.first(where: { $0.id == device.id }) ?? device
        return VStack(alignment: .leading, spacing: 14) {
            Text("Gerät bearbeiten")
                .font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.ip).monospaced().foregroundStyle(.secondary)
                Text(device.mac).monospaced().font(.caption).foregroundStyle(.secondary)
            }
            TextField("Gerätename", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { commitRename(device) }

            HStack(spacing: 8) {
                Text("Symbol:")
                Menu {
                    Button {
                        scanner.setCategory(nil, for: device)
                    } label: {
                        Label("Automatisch (\(current.autoCategory.label))",
                              systemImage: current.autoCategory.symbol)
                    }
                    Divider()
                    ForEach(DeviceCategory.allCases) { cat in
                        Button {
                            scanner.setCategory(cat, for: device)
                        } label: {
                            Label(cat.label, systemImage: cat.symbol)
                        }
                    }
                } label: {
                    Label(current.customCategory == nil
                          ? "Automatisch (\(current.category.label))"
                          : current.category.label,
                          systemImage: current.category.symbol)
                    .foregroundStyle(current.category.tint)
                }
                .frame(width: 240)
            }

            HStack {
                if device.customName != nil {
                    Button("Zurücksetzen") {
                        scanner.rename(device, to: nil)
                        renameTarget = nil
                    }
                }
                Spacer()
                Button("Abbrechen") { renameTarget = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Speichern") { commitRename(device) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    // MARK: - Aktionen

    private func beginRename(_ d: Device) {
        renameText = d.customName ?? d.hostname ?? ""
        renameTarget = d
    }

    private func commitRename(_ d: Device) {
        scanner.rename(d, to: renameText)
        renameTarget = nil
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
