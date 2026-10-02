import SwiftUI
import AppKit
import UserNotifications

struct MenuBarContent: View {
    @ObservedObject var m: Monitor
    @ObservedObject var watch: StartupWatch
    @ObservedObject var ssd: SSDWatch
    @ObservedObject var night: NightMode
    @ObservedObject var game: GameLink
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Brand().padding(-10); Spacer() }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow { Text("RAM disponible").foregroundStyle(.secondary); Text(m.ramFree).bold() }
                GridRow { Text("Swap usado").foregroundStyle(.secondary); Text(m.swap).bold() }
                GridRow { Text("Uso de CPU").foregroundStyle(.secondary); Text(m.cpuLoad).bold() }
                GridRow { Text("Temperatura").foregroundStyle(.secondary); Text(m.thermal).bold().foregroundStyle(m.hot ? Color.red : .primary) }
                GridRow { Text("Salud").foregroundStyle(.secondary); Text("\(healthReport(m, watch, ssd).score) / 100").bold() }
                GridRow { Text("SSD").foregroundStyle(.secondary); Text(ssd.connected ? ssd.free + " libres" : "desconectado").bold().foregroundStyle(ssd.connected ? Color.primary : .red) }
            }
            if !watch.fresh.isEmpty {
                Label("\(watch.fresh.count) programa nuevo arranca solo: revísalo en Arranque automático", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button("Abrir TP Optimizer") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
                Spacer()
                if m.relievedItems.isEmpty {
                    Button("Dar respiro") { Task { await m.reload(); m.breathe() } }.help("Baja la prioridad de lo pesado en segundo plano")
                } else {
                    Button("Quitar respiro") { m.restoreAll() }
                }
            }
            Button(game.session == nil ? "Empezar modo juego" : "Terminar modo juego") { Task { await game.toggleSession(m) } }
                .help("Mantiene la Mac despierta y baja la prioridad de lo pesado de fondo mientras juegas desde el iPad")
            Button(night.on ? "Apagar modo noche" : "Modo noche") { night.toggle(m) }
                .help("Duerme tus apps personales, deja trabajando los bots y no deja dormir la Mac")
            Button("Salir de TP Optimizer") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.secondary).font(.caption)
        }
        .padding(14)
        .frame(width: 290)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var m: Monitor
    @ObservedObject var watch: StartupWatch
    @ObservedObject var game: GameLink
    var body: some View {
        HStack(spacing: 3) {
            if game.session != nil {
                Image(systemName: "flame.fill")
                Text(game.menuText)
            }
            Image(systemName: watch.fresh.isEmpty ? (m.hot ? "thermometer.high" : "gauge.with.dots.needle.67percent") : "exclamationmark.triangle.fill")
            Text("\(m.ramFree) · \(m.swap)")
        }
    }
}

@MainActor
final class StartupWatch: ObservableObject {
    @Published var fresh: [String] = []
    private var timer: Timer?
    static let dirs = [NSHomeDirectory() + "/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"]

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if UserDefaults.standard.array(forKey: "knownStartup") == nil { accept() }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.check() } }
    }

    static func current() -> Set<String> {
        Set(dirs.flatMap { d in ((try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []).filter { $0.hasSuffix(".plist") }.map { d + "/" + $0 } })
    }

    func check() {
        let known = Set(UserDefaults.standard.array(forKey: "knownStartup") as? [String] ?? [])
        let now = StartupWatch.current()
        let added = now.subtracting(known).subtracting(fresh).sorted()
        guard !added.isEmpty else { return }
        fresh += added
        let content = UNMutableNotificationContent()
        content.title = "Un programa nuevo arranca solo"
        content.body = added.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".plist", with: "") }.joined(separator: ", ")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        TelegramBot.shared.alert("Un programa nuevo arranca solo: \(content.body)")
        record("Detecté arranque nuevo: \(content.body)")
    }

    func accept() {
        UserDefaults.standard.set(Array(StartupWatch.current()), forKey: "knownStartup")
        fresh = []
    }
}

struct Profile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var symbol: String
    var apps: [String]
}

@MainActor
final class Profiles: ObservableObject {
    @Published var list: [Profile] = []
    @Published var active: UUID?
    @Published var status = ""

    init() {
        if let data = UserDefaults.standard.data(forKey: "profiles"), let saved = try? JSONDecoder().decode([Profile].self, from: data) {
            list = saved
        } else {
            list = [Profile(name: "Trabajo", symbol: "briefcase", apps: ["BlueStacks", "BlueAI"]),
                    Profile(name: "Película", symbol: "film", apps: ["Firefox"])]
        }
    }

    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: "profiles") }

    func activate(_ p: Profile, monitor: Monitor) async {
        await monitor.reload()
        if let current = active, current != p.id, let old = list.first(where: { $0.id == current }) { await deactivate(old, monitor: monitor) }
        let targets = monitor.items.filter { p.apps.contains($0.name) && !$0.protected && !$0.paused }
        targets.forEach { monitor.setPaused($0, true) }
        active = p.id
        status = targets.isEmpty ? "\(p.name): ninguna de sus apps estaba abierta." : "\(p.name) activo: dormí \(targets.map(\.name).joined(separator: ", "))."
    }

    func deactivate(_ p: Profile, monitor: Monitor) async {
        await monitor.reload()
        monitor.items.filter { p.apps.contains($0.name) && $0.paused }.forEach { monitor.setPaused($0, false) }
        if active == p.id { active = nil }
        status = "\(p.name) desactivado: sus apps despertaron."
    }
}

struct ProfilesView: View {
    @ObservedObject var p: Profiles
    @ObservedObject var m: Monitor
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header(title: "Perfiles", subtitle: "Prepara la Mac para lo que vas a hacer: duerme lo que estorba, despierta con un clic.")
            Text(p.status).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach($p.list) { $profile in card($profile) }
                }
            }
            HStack {
                TextField("Nombre del perfil nuevo", text: $newName).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Button("Crear perfil") {
                    p.list.append(Profile(name: newName, symbol: "square.stack.3d.up", apps: [])); p.save(); newName = ""
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .onAppear { m.refresh() }
    }

    func card(_ profile: Binding<Profile>) -> some View {
        let isOn = p.active == profile.wrappedValue.id
        let candidates = Array(Set(m.items.filter { !$0.protected && $0.kind == .open && $0.name != "Claude" }.map(\.name) + profile.wrappedValue.apps)).sorted()
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: profile.wrappedValue.symbol).font(.title2).foregroundStyle(Color.brandTeal)
                Text(profile.wrappedValue.name).font(.title3.bold())
                if isOn { Text("Activo").font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(Color.brandTeal.opacity(0.18))) }
                Spacer()
                Button(isOn ? "Desactivar" : "Activar") { Task { isOn ? await p.deactivate(profile.wrappedValue, monitor: m) : await p.activate(profile.wrappedValue, monitor: m) } }
                    .buttonStyle(PrimaryButton())
                    .help(isOn ? "Despierta las apps de este perfil" : "Duerme las apps marcadas abajo")
                Button { p.list.removeAll { $0.id == profile.wrappedValue.id }; p.save() } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).help("Borrar este perfil")
            }
            Text("Duerme:").font(.caption).foregroundStyle(.secondary)
            FlowChips(items: candidates, selected: Set(profile.wrappedValue.apps)) { name in
                if profile.wrappedValue.apps.contains(name) { profile.wrappedValue.apps.removeAll { $0 == name } } else { profile.wrappedValue.apps.append(name) }
                p.save()
            }
        }
        .padding(14)
        .card(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isOn ? Color.brandTeal : Color.primary.opacity(0.08)))
    }
}

struct FlowChips: View {
    let items: [String]
    let selected: Set<String>
    let toggle: (String) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { name in
                Button { toggle(name) } label: {
                    Label(name, systemImage: selected.contains(name) ? "checkmark.circle.fill" : "circle")
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(selected.contains(name) ? Color.brandTeal.opacity(0.18) : Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .help(selected.contains(name) ? "Se duerme con este perfil. Toca para quitarla" : "Toca para que este perfil la duerma")
            }
        }
    }
}

struct BigFile: Identifiable {
    let id = UUID()
    let url: URL
    let size: Int64
    let lastOpened: Date?
}

@MainActor
final class BigFiles: ObservableObject {
    @Published var files: [BigFile] = []
    @Published var minMB = 500
    @Published var oldDays = 90
    @Published var scanning = false
    @Published var status = ""
    @Published var scanned = false
    static let ssd = "/Volumes/Respaldo"

    func scan() {
        scanning = true
        status = "Buscando…"
        let minBytes = Int64(minMB) * 1_000_000, cutoff = Date().addingTimeInterval(-Double(oldDays) * 86400)
        Task.detached {
            let found = BigFiles.find(minBytes: minBytes, cutoff: cutoff)
            await MainActor.run {
                self.files = found
                self.scanning = false
                self.scanned = true
                self.status = found.isEmpty ? "" : "\(found.count) archivos · \(formatBytes(found.reduce(0) { $0 + $1.size }))"
            }
        }
    }

    nonisolated static func find(minBytes: Int64, cutoff: Date) -> [BigFile] {
        let skip: Set<String> = ["Library", "node_modules", ".venv", ".git", ".Trash", ".cache", "Applications"]
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentAccessDateKey]
        var out: [BigFile] = []
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: NSHomeDirectory()), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        for case let url as URL in e {
            if skip.contains(url.lastPathComponent) { e.skipDescendants(); continue }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, v.isSymbolicLink != true,
                  let size = v.fileSize, Int64(size) >= minBytes else { continue }
            if let d = v.contentAccessDate, d > cutoff { continue }
            out.append(BigFile(url: url, size: Int64(size), lastOpened: v.contentAccessDate))
        }
        return out.sorted { $0.size > $1.size }
    }

    func toSSD(_ f: BigFile) async {
        guard FileManager.default.fileExists(atPath: BigFiles.ssd) else { status = "El SSD no está conectado."; return }
        let rel = f.url.path.replacingOccurrences(of: NSHomeDirectory() + "/", with: "")
        let dest = URL(fileURLWithPath: BigFiles.ssd + "/mac-offload/archivos/" + rel)
        status = "Copiando \(f.url.lastPathComponent) al SSD…"
        let ok = await Task.detached { () -> Bool in
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? FileManager.default.copyItem(at: f.url, to: dest)) != nil else { return false }
            return shellStatus("cmp -s \(q(f.url.path)) \(q(dest.path))") == 0
        }.value
        guard ok else { status = "No pude copiar \(f.url.lastPathComponent). El original sigue en su lugar."; return }
        _ = await recycle([f.url])
        try? FileManager.default.createSymbolicLink(at: f.url, withDestinationURL: dest)
        files.removeAll { $0.id == f.id }
        record("Mandé \(f.url.lastPathComponent) al SSD")
        status = "\(f.url.lastPathComponent) está en el SSD. En la Mac quedó un acceso directo; el original está en la Papelera."
    }

    func trash(_ f: BigFile) async {
        _ = await recycle([f.url])
        files.removeAll { $0.id == f.id }
        status = "\(f.url.lastPathComponent) en la Papelera."
        record("Mandé \(f.url.lastPathComponent) a la Papelera")
    }
}

struct BigFilesView: View {
    @ObservedObject var b: BigFiles
    @State private var trashTarget: BigFile?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header(title: "Archivos grandes y olvidados", subtitle: "Lo que más ocupa y hace tiempo no tocas. Muévelo al SSD y queda a un clic, sin perderlo.")
            HStack {
                Picker("Más de", selection: $b.minMB) { Text("100 MB").tag(100); Text("500 MB").tag(500); Text("1 GB").tag(1000); Text("5 GB").tag(5000) }
                    .frame(maxWidth: 180).help("Tamaño mínimo")
                Picker("Sin abrir hace", selection: $b.oldDays) { Text("1 mes").tag(30); Text("3 meses").tag(90); Text("6 meses").tag(180); Text("1 año").tag(365) }
                    .frame(maxWidth: 220).help("Solo archivos que no abriste en ese tiempo")
                Spacer()
                Button { b.scan() } label: { Label("Buscar", systemImage: "magnifyingglass") }.buttonStyle(PrimaryButton()).disabled(b.scanning)
                    .help("Revisa tu carpeta personal. No toca nada hasta que tú elijas")
            }
            HStack { if b.scanning { ProgressView().controlSize(.small) }; Text(b.status).foregroundStyle(.secondary) }
            if b.files.isEmpty {
                Placeholder(symbol: b.scanned ? "checkmark.circle" : "externaldrive.badge.questionmark", text: b.scanned ? "No hay archivos que cumplan esos filtros" : "Elige los filtros y toca Buscar")
            } else {
                List(b.files) { f in
                    HStack(spacing: 10) {
                        Thumb(url: f.url)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.url.lastPathComponent).fontWeight(.medium).lineLimit(1)
                            Text(f.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(f.lastOpened.map { "abierto " + $0.formatted(.relative(presentation: .named)) } ?? "nunca abierto").font(.caption).foregroundStyle(.secondary)
                        Text(formatBytes(f.size)).monospacedDigit().frame(width: 80, alignment: .trailing)
                        Button { NSWorkspace.shared.activateFileViewerSelecting([f.url]) } label: { Image(systemName: "eye") }.buttonStyle(.plain).help("Mostrar en Finder")
                        Button("Al SSD") { Task { await b.toSSD(f) } }.help("Lo copia al SSD, comprueba que quedó idéntico, manda el original a la Papelera y deja un acceso directo")
                        Button("Papelera") { trashTarget = f }.help("Lo manda a la Papelera")
                    }
                    .help(f.url.path)
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding()
        .confirmationDialog(trashTarget.map { "¿Mandar \($0.url.lastPathComponent) (\(formatBytes($0.size))) a la Papelera?" } ?? "",
                            isPresented: Binding(get: { trashTarget != nil }, set: { if !$0 { trashTarget = nil } })) {
            Button("A la Papelera", role: .destructive) { if let t = trashTarget { Task { await b.trash(t) } } }
        }
    }
}
