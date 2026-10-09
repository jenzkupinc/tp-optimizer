import SwiftUI
import AppKit

struct DiskInfo: Identifiable {
    var id: String { mount }
    let mount: String
    let name: String
    let media: String
    let smart: String
    let total: Int64
    let free: Int64
    var health: (String, Color) {
        switch smart {
        case "Verified": ("Sano", .green)
        case "Failing": ("Está fallando: copia tus datos ya", .red)
        case "": ("No informa su salud", .secondary)
        default: ("No informa su salud", .secondary)
        }
    }
}

func diskInfo(_ mount: String) -> DiskInfo? {
    guard FileManager.default.fileExists(atPath: mount) else { return nil }
    let info = shell("diskutil info \(q(mount))")
    func field(_ key: String) -> String {
        info.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(key + ":") }
            .map { String($0.split(separator: ":", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces) } ?? ""
    }
    var smart = field("SMART Status"), media = field("Device / Media Name")
    let whole = field("Part of Whole")
    if (smart.isEmpty || smart == "Not Supported" || media.isEmpty), !whole.isEmpty {
        let parent = shell("diskutil info \(whole)").split(separator: "\n")
        func pf(_ key: String) -> String? { parent.first { $0.contains(key + ":") }.map { String($0.split(separator: ":", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces) } }
        if smart.isEmpty || smart == "Not Supported" { smart = pf("SMART Status") ?? smart }
        if media.isEmpty { media = pf("Device / Media Name") ?? "" }
    }
    if smart == "Not Supported" { smart = "" }
    let v = try? URL(fileURLWithPath: mount).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedNameKey])
    return DiskInfo(mount: mount, name: v?.volumeLocalizedName ?? mount, media: media, smart: smart,
                    total: Int64(v?.volumeTotalCapacity ?? 0), free: v?.volumeAvailableCapacityForImportantUsage ?? 0)
}

@MainActor
final class BackupModel: ObservableObject {
    @Published var folders: [String] = UserDefaults.standard.stringArray(forKey: "backupFolders") ?? [] { didSet { UserDefaults.standard.set(folders, forKey: "backupFolders") } }
    @Published var nightly = UserDefaults.standard.bool(forKey: "backupNightly") { didSet { UserDefaults.standard.set(nightly, forKey: "backupNightly") } }
    @Published var hour = UserDefaults.standard.object(forKey: "backupHour") as? Int ?? 3 { didSet { UserDefaults.standard.set(hour, forKey: "backupHour") } }
    @Published var lastRun = UserDefaults.standard.object(forKey: "backupLast") as? Date { didSet { UserDefaults.standard.set(lastRun, forKey: "backupLast") } }
    @Published var running = false
    @Published var status = ""
    nonisolated static let dest = SSDWatch.path + "/respaldo-mac"
    nonisolated static let excludes = ["node_modules", ".venv", "venv", ".next", "__pycache__", ".cache", "DerivedData", ".Trash"]
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }

    func tick() {
        guard nightly, !running, !folders.isEmpty else { return }
        let today = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        guard Date() >= today, (lastRun ?? .distantPast) < today else { return }
        Task { await run() }
    }

    func add() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        p.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        if p.runModal() == .OK { folders += p.urls.map(\.path).filter { !folders.contains($0) } }
    }

    func run() async {
        guard FileManager.default.fileExists(atPath: SSDWatch.path) else {
            status = "El SSD no está conectado: no se hizo el respaldo. Se reintenta cada minuto hasta que vuelva."
            let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
            if UserDefaults.standard.integer(forKey: "backupAlertDay") != day {
                UserDefaults.standard.set(day, forKey: "backupAlertDay")
                TelegramBot.shared.alert("No se hizo el respaldo nocturno: el SSD no está conectado. Se reintenta cada minuto y este aviso no se repite hoy.")
            }
            return
        }
        running = true
        status = "Copiando al SSD…"
        let folders = folders
        let failed = await Task.detached { () -> [String] in
            let ex = BackupModel.excludes.map { "--exclude \(q($0))" }.joined(separator: " ")
            return folders.filter { src in
                let dest = BackupModel.dest + "/" + (src as NSString).lastPathComponent
                return shellStatus("mkdir -p \(q(dest)) && /usr/bin/rsync -a \(ex) \(q(src + "/")) \(q(dest + "/"))") != 0
            }
        }.value
        running = false
        lastRun = Date()
        status = failed.isEmpty ? "Respaldo listo: \(plural(folders.count, "carpeta", "carpetas")) en el SSD." : "Algunas carpetas no se copiaron completas: \(failed.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))."
        record(status)
        if !failed.isEmpty { TelegramBot.shared.alert("Respaldo con problemas: \(status)") }
    }
}

struct DisksPane: View {
    @ObservedObject var backup: BackupModel
    @State private var disks: [DiskInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header(title: "Discos y respaldo", subtitle: "El pulso de tus discos, y una copia de lo que te importa en el SSD mientras duermes.")
            HStack(spacing: 12) {
                ForEach(disks) { d in
                    HStack(spacing: 12) {
                        Image(systemName: d.mount == "/" ? "internaldrive.fill" : "externaldrive.fill").font(.title).foregroundStyle(Color.brandTeal)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(d.mount == "/" ? "Disco de la Mac" : d.name).font(.headline)
                            Text(d.media).font(.caption).foregroundStyle(.secondary)
                            Label(d.health.0, systemImage: d.smart == "Verified" ? "heart.fill" : d.smart == "Failing" ? "exclamationmark.triangle.fill" : "questionmark.circle")
                                .font(.callout.weight(.medium)).foregroundStyle(d.health.1)
                            ProgressView(value: Double(d.total - d.free), total: Double(max(d.total, 1))).tint(Double(d.free) / Double(max(d.total, 1)) < 0.1 ? .red : Color.brandTeal)
                            Text("\(formatBytes(d.free)) libres de \(formatBytes(d.total))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(12)
                    .help(d.smart.isEmpty ? "Este disco no entrega su estado de salud a macOS, algo común en discos por USB" : "Estado SMART que reporta el disco: \(d.smart)")
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Respaldo al SSD").font(.headline)
                    Spacer()
                    Toggle("Cada noche a las", isOn: $backup.nightly).disabled(backup.folders.isEmpty)
                    Picker("", selection: $backup.hour) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                        .labelsHidden().fixedSize().disabled(!backup.nightly)
                }
                Text("Copia a \(BackupModel.dest). Nunca borra nada del respaldo, y deja fuera node_modules, entornos de Python y cachés. Funciona mientras TP Optimizer esté abierto.")
                    .font(.caption).foregroundStyle(.secondary)
                if backup.folders.isEmpty {
                    Text("Todavía no elegiste carpetas.").foregroundStyle(.secondary)
                }
                ForEach(backup.folders, id: \.self) { f in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(Color.brandTeal)
                        Text(f.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { backup.folders.removeAll { $0 == f } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("Quitar del respaldo. Lo que ya se copió se queda en el SSD")
                    }
                }
                HStack {
                    Button { backup.add() } label: { Label("Agregar carpeta", systemImage: "plus") }
                    Spacer()
                    if backup.running { ProgressView().controlSize(.small) }
                    Text(backup.status.isEmpty ? backup.lastRun.map { "Último respaldo \($0.formatted(.relative(presentation: .named)))" } ?? "Nunca se respaldó" : backup.status)
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Respaldar ahora") { Task { await backup.run() } }.buttonStyle(PrimaryButton()).disabled(backup.folders.isEmpty || backup.running)
                }
            }
            .padding(14)
            .card(12)
            Spacer(minLength: 0)
        }
        .padding()
        .task { disks = await Task.detached { ["/", SSDWatch.path].compactMap(diskInfo) }.value }
    }
}
