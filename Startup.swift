import SwiftUI
import AppKit

struct LaunchItem: Identifiable {
    var id: String { plist.path }
    let label: String
    let plist: URL
    let args: [String]
    let workdir: String?
    let logs: [String]
    let modified: Date?
    let readable: Bool
    let system: Bool
    let mine: Bool
    var running: Bool
    var disabled: Bool
    var domain: String { system ? "system" : "gui/\(getuid())" }
    var inHome: Bool { plist.path.hasPrefix(NSHomeDirectory()) }
    var place: String { system ? "Servicio del sistema" : inHome ? "Tu usuario" : "Todos los usuarios" }
    var purpose: String {
        if let known = LaunchItem.known[label] { return known }
        return LaunchItem.byVendor.first { label.hasPrefix($0.0) }?.1 ?? "Sin descripción: revisa el comando de abajo"
    }
    static let known: [String: String] = [
        "com.cloudflare.cloudflared": "Túnel de Cloudflare hacia esta Mac",
        "com.canonical.multipassd": "Multipass: máquinas virtuales Ubuntu",
    ]
    static let byVendor: [(String, String)] = [
        ("com.epson.", "Impresora o escáner Epson"),
        ("com.microsoft.", "Actualizador o licencia de Microsoft Office"), ("com.docker.", "Docker"),
        ("com.google.", "Actualizador de Google Chrome"), ("com.now.gg.", "Limpieza de BlueStacks o BlueAI"),
        ("com.nordvpn.", "Ayudante de NordVPN"),
    ]
}

@MainActor
final class StartupModel: ObservableObject {
    @Published var items: [LaunchItem] = []
    @Published var status = ""
    @Published var loading = false
    @Published var exts: [SystemExtension] = []
    @Published var saved: [URL] = []
    nonisolated static let minePrefixes = ["app.tpoptimizer."]

    func refresh() {
        loading = true
        Task.detached {
            let found = StartupModel.find(), exts = systemExtensions(), saved = StartupModel.backups()
            await MainActor.run { self.items = found; self.exts = exts; self.saved = saved; self.loading = false }
        }
    }

    nonisolated static func find() -> [LaunchItem] {
        let uid = getuid()
        let disabledUser = shell("launchctl print-disabled gui/\(uid)")
        let disabledSystem = shell("launchctl print-disabled system")
        var live = Set<String>()
        for line in shell("launchctl list").split(separator: "\n").dropFirst() {
            let c = line.split(separator: "\t")
            if c.count == 3, c[0] != "-" { live.insert(String(c[2])) }
        }
        for line in shell("launchctl print system").split(separator: "\n") {
            let c = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if c.count == 3, let pid = Int(c[0]), pid > 0 { live.insert(c[2]) }
        }
        let dirs: [(String, Bool)] = [(NSHomeDirectory() + "/Library/LaunchAgents", false), ("/Library/LaunchAgents", false), ("/Library/LaunchDaemons", true)]
        var out: [LaunchItem] = []
        for (dir, system) in dirs {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".plist") {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(f)
                let d = NSDictionary(contentsOf: url)
                let label = (d?["Label"] as? String) ?? String(f.dropLast(6))
                guard !label.hasPrefix("com.apple.") else { continue }
                let args = (d?["ProgramArguments"] as? [String]) ?? [(d?["Program"] as? String)].compactMap { $0 }
                let disabledText = system ? disabledSystem : disabledUser
                let running = live.contains(label)
                out.append(LaunchItem(
                    label: label, plist: url, args: args, workdir: d?["WorkingDirectory"] as? String,
                    logs: [d?["StandardOutPath"] as? String, d?["StandardErrorPath"] as? String].compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } },
                    modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                    readable: d != nil, system: system, mine: minePrefixes.contains { label.hasPrefix($0) }, running: running,
                    disabled: disabledText.contains("\"\(label)\" => disabled") || disabledText.contains("\"\(label)\" => true")))
            }
        }
        return out.sorted { ($0.mine ? 0 : 1, $0.label) < ($1.mine ? 0 : 1, $1.label) }
    }

    nonisolated static func wake(domain: String, label: String, plist: String, system: Bool) -> Bool {
        system ? Root.run(["launch", "wake", label, plist]) : shellStatus("launchctl enable \(q(domain + "/" + label)); launchctl bootstrap \(domain) \(q(plist)) 2>/dev/null; launchctl print \(q(domain + "/" + label)) >/dev/null 2>&1") == 0
    }

    func setAsleep(_ item: LaunchItem, _ sleep: Bool) {
        Task {
            let ok = await Task.detached { () -> Bool in
                let target = "\(item.domain)/\(item.label)"
                if !sleep { return StartupModel.wake(domain: item.domain, label: item.label, plist: item.plist.path, system: item.system) }
                return item.system ? Root.run(["launch", "sleep", item.label]) : shellStatus("launchctl bootout \(q(target)) 2>/dev/null; launchctl disable \(q(target))") == 0
            }.value
            status = ok ? "\(item.purpose) \(sleep ? "dormido: no arranca hasta que lo despiertes" : "despierto")." : "No se pudo cambiar \(item.label)."
            if ok { record("\(sleep ? "Dormí" : "Desperté") el arranque de \(item.purpose) (\(item.label))", undo: sleep ? .wakeStartup(domain: item.domain, label: item.label, plist: item.plist.path, system: item.system) : nil) }
            refresh()
        }
    }

    nonisolated static let backupDir = NSHomeDirectory() + "/Library/Application Support/TP Optimizer/respaldo-arranque"

    nonisolated static func backups() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: backupDir), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "plist" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func restore(_ backup: URL) {
        let dest = URL(fileURLWithPath: NSHomeDirectory() + "/Library/LaunchAgents/" + backup.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: dest.path) else { status = "\(backup.lastPathComponent) ya está instalado."; return }
        let label = backup.deletingPathExtension().lastPathComponent
        let ok = (try? FileManager.default.copyItem(at: backup, to: dest)) != nil
            && shellStatus("launchctl enable gui/\(getuid())/\(label); launchctl bootstrap gui/\(getuid()) \(q(dest.path))") == 0
        if ok { try? FileManager.default.removeItem(at: backup); record("Restauré el arranque \(label)") }
        status = ok ? "\(label) restaurado y encendido." : "No se pudo restaurar \(label)."
        refresh()
    }

    func remove(_ item: LaunchItem) {
        try? FileManager.default.createDirectory(atPath: StartupModel.backupDir, withIntermediateDirectories: true)
        if item.readable, item.inHome { try? FileManager.default.copyItem(at: item.plist, to: URL(fileURLWithPath: StartupModel.backupDir + "/" + item.plist.lastPathComponent)) }
        Task {
            let ok = await Task.detached { () -> Bool in
                if item.inHome { return shellStatus("launchctl bootout \(q(item.domain + "/" + item.label)) 2>/dev/null; mv \(q(item.plist.path)) \(q(NSHomeDirectory() + "/.Trash/"))") == 0 }
                return Root.run(["launch", "remove", item.label, item.plist.path])
            }.value
            status = ok ? "\(item.label) eliminado: su archivo está en la Papelera." : "No se pudo eliminar \(item.label)."
            if ok { record("Eliminé el arranque \(item.label). " + (item.inHome && item.readable ? "Su respaldo está en Arranque automático → Eliminados" : "Sin respaldo: era un archivo del sistema.")) }
            refresh()
        }
    }
}

struct StartupView: View {
    @ObservedObject var s: StartupModel
    @ObservedObject var watch: StartupWatch
    @State private var sleepTarget: (LaunchItem, Bool)?
    @State private var removeTarget: LaunchItem?
    @State private var open: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header(title: "Arranque automático", subtitle: "Lo que arranca solo cuando enciendes la Mac. Dórmelo para que espere, o elimínalo para que no vuelva.")
            HStack {
                Button { s.refresh() } label: { Label("Actualizar", systemImage: "arrow.clockwise") }.disabled(s.loading).help("Vuelve a leer el estado de cada servicio")
                if s.loading { ProgressView().controlSize(.small) }
                Text(s.status).foregroundStyle(.secondary)
                Spacer()
                if !watch.fresh.isEmpty {
                    Label("\(watch.fresh.count) nuevo", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("Marcar como revisado") { watch.accept() }.help("Deja de avisar por estos. Si aparece otro nuevo, te vuelvo a avisar")
                }
            }
            List {
                section("Tuyos (bots y herramientas)", s.items.filter(\.mine))
                section("De otras apps", s.items.filter { !$0.mine })
                let exts = s.exts
                if !exts.isEmpty {
                    Section("Extensiones del sistema") {
                        ForEach(exts) { e in
                            HStack {
                                Image(systemName: "puzzlepiece.extension").foregroundStyle(Color.brandTeal)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.name).fontWeight(.medium)
                                    Text("\(e.bundleID) · \(e.state)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Quitar en Ajustes") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!) }
                                    .help("macOS solo deja quitar extensiones del sistema desde Ajustes: te abro la pantalla")
                            }
                            .help("Las extensiones del sistema corren muy hondo en macOS. Si no reconoces una o ya no usas su app, quítala")
                        }
                    }
                }
                let saved = s.saved
                if !saved.isEmpty {
                    Section("Eliminados (con respaldo)") {
                        ForEach(saved, id: \.self) { b in
                            HStack {
                                Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(Color.brandTeal)
                                Text(b.deletingPathExtension().lastPathComponent).fontWeight(.medium)
                                Spacer()
                                Button("Restaurar") { s.restore(b) }.help("Lo vuelve a instalar en tu usuario y lo enciende")
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding()
        .onAppear { s.refresh() }
        .confirmationDialog(sleepTarget.map { $0.1 ? "¿Dormir \($0.0.label)? Se detiene ahora y no volverá a arrancar solo." : "¿Despertar \($0.0.label)?" } ?? "",
                            isPresented: Binding(get: { sleepTarget != nil }, set: { if !$0 { sleepTarget = nil } })) {
            Button(sleepTarget?.1 == true ? "Dormir" : "Despertar", role: sleepTarget?.1 == true ? .destructive : nil) {
                if let t = sleepTarget { s.setAsleep(t.0, t.1) }
            }
        }
        .confirmationDialog(removeTarget.map { "¿Eliminar \($0.label)? Se apaga y su archivo va a la Papelera. La app que lo instaló puede volver a crearlo; para eso, desinstala la app." } ?? "",
                            isPresented: Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } })) {
            Button("Eliminar", role: .destructive) { if let t = removeTarget { s.remove(t) } }
        }
    }

    @ViewBuilder
    func section(_ title: String, _ items: [LaunchItem]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Circle().fill(item.disabled ? Color.indigo : item.running ? .green : .secondary.opacity(0.4)).frame(width: 9, height: 9).help(item.disabled ? "Dormido: no arranca" : item.running ? "Corriendo ahora" : "No está corriendo, pero puede arrancar solo")
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(item.purpose).fontWeight(.medium)
                                    if watch.fresh.contains(item.plist.path) {
                                        Text("Nuevo").font(.caption2.bold()).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(Capsule().fill(Color.orange)).help("Apareció después de la última revisión")
                                    }
                                }
                                Text("\(item.label) · \(item.place)" + (item.modified.map { " · instalado \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(item.disabled ? "Dormido" : item.running ? "Corriendo" : "Listo para arrancar")
                                .font(.caption).foregroundStyle(item.disabled ? Color.indigo : .secondary)
                            Button { toggle(item.id) } label: { Image(systemName: open.contains(item.id) ? "chevron.up" : "info.circle") }.buttonStyle(.plain).help("Ver qué ejecuta, dónde trabaja y sus logs")
                            Button(item.disabled ? "Despertar" : "Dormir") { sleepTarget = (item, !item.disabled) }.help(item.disabled ? "Lo vuelve a encender y a dejar que arranque solo" : "Lo apaga y no deja que arranque solo, ni al reiniciar. Su archivo se queda")
                            Button("Eliminar", role: .destructive) { removeTarget = item }.help("Lo apaga y manda su archivo a la Papelera")
                        }
                        if open.contains(item.id) { details(item) }
                    }
                }
            }
        }
    }

    func toggle(_ id: String) { if open.contains(id) { open.remove(id) } else { open.insert(id) } }

    @ViewBuilder
    func details(_ item: LaunchItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !item.readable { Text("macOS no deja leer este archivo sin contraseña.").foregroundStyle(.orange) }
            if !item.args.isEmpty { Text("Ejecuta: " + item.args.joined(separator: " ")).textSelection(.enabled) }
            if let w = item.workdir { Text("Trabaja en: " + w).textSelection(.enabled) }
            Text("Archivo: " + item.plist.path).textSelection(.enabled)
            HStack {
                Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.plist]) }
                ForEach(item.logs, id: \.self) { log in
                    Button("Ver log \((log as NSString).lastPathComponent)") { NSWorkspace.shared.open(URL(fileURLWithPath: log)) }
                        .disabled(!FileManager.default.fileExists(atPath: log))
                }
            }
            .controlSize(.small)
        }
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .padding(.leading, 19)
    }
}
