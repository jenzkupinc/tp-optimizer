import SwiftUI
import AppKit

struct Junk: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let urls: [URL]
    let size: Int64
    var selected: Bool
}

@MainActor
final class Cleaner: ObservableObject {
    @Published var items: [Junk] = []
    @Published var scanning = false
    @Published var status = ""
    @Published var report = ""

    var selectedSize: Int64 { items.filter(\.selected).reduce(0) { $0 + $1.size } }

    func scan() {
        scanning = true
        status = "Buscando basura…"
        let running = Set(NSWorkspace.shared.runningApplications.flatMap { [$0.bundleIdentifier, $0.localizedName].compactMap { $0?.lowercased() } })
        Task.detached {
            let found = Cleaner.find(running: running)
            await MainActor.run {
                self.items = found.sorted { $0.size > $1.size }
                self.scanning = false
                self.status = found.isEmpty ? "No encontré basura." : "Encontré \(formatBytes(found.reduce(0) { $0 + $1.size })) que se puede limpiar."
            }
        }
    }

    nonisolated static func find(running: Set<String>) -> [Junk] {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var out: [Junk] = []
        let keep: Set<String> = ["ms-playwright", "ms-playwright-go", "com.apple.nsurlsessiond", "CloudKit"]

        let caches = home.appendingPathComponent("Library/Caches")
        for dir in (try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? [] {
            let name = dir.lastPathComponent
            if keep.contains(name) || name.hasPrefix("com.apple.") || name.hasPrefix("ms-playwright") { continue }
            let size = folderSize(dir)
            guard size > 20_000_000 else { continue }
            let inUse = running.contains { $0.contains(name.lowercased()) }
            out.append(Junk(title: "Caché · \(name)", detail: inUse ? "La app está abierta: ciérrala antes" : "Se regenera sola",
                            urls: [dir], size: size, selected: !inUse))
        }

        let simple: [(String, String, String)] = [
            (".bun/install/cache", "Caché de Bun", "Se vuelve a descargar si hace falta"),
            (".npm/_cacache", "Caché de npm", "Se vuelve a descargar si hace falta"),
            ("Library/Developer/Xcode/DerivedData", "Compilaciones de Xcode", "Se regeneran al compilar"),
            ("Library/Developer/CoreSimulator/Caches", "Caché de simuladores", "Se regenera sola"),
        ]
        for (path, title, detail) in simple {
            let url = home.appendingPathComponent(path)
            guard fm.fileExists(atPath: url.path), (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { continue }
            let size = folderSize(url)
            if size > 10_000_000 { out.append(Junk(title: title, detail: detail, urls: [url], size: size, selected: true)) }
        }

        let cutoff = Date().addingTimeInterval(-14 * 86400)
        var logs: [URL] = [], logSize: Int64 = 0
        if let e = fm.enumerator(at: home.appendingPathComponent("Library/Logs"), includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .totalFileAllocatedSizeKey]) {
            for case let f as URL in e {
                guard let v = try? f.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .totalFileAllocatedSizeKey]),
                      v.isRegularFile == true, let d = v.contentModificationDate, d < cutoff, f.lastPathComponent != "optimizer.log" else { continue }
                logs.append(f); logSize += Int64(v.totalFileAllocatedSize ?? 0)
            }
        }
        if !logs.isEmpty { out.append(Junk(title: "Logs viejos", detail: "\(logs.count) archivos de más de 14 días", urls: logs, size: logSize, selected: true)) }

        let oldCutoff = Date().addingTimeInterval(-60 * 86400)
        let dlKeys: Set<URLResourceKey> = [.addedToDirectoryDateKey, .creationDateKey, .totalFileAllocatedSizeKey, .isDirectoryKey]
        for f in (try? fm.contentsOfDirectory(at: home.appendingPathComponent("Downloads"), includingPropertiesForKeys: Array(dlKeys), options: .skipsHiddenFiles)) ?? [] {
            guard let v = try? f.resourceValues(forKeys: dlKeys), let d = v.addedToDirectoryDate ?? v.creationDate, d < oldCutoff else { continue }
            if ["dmg", "pkg"].contains(f.pathExtension.lowercased()) { continue }
            let size = v.isDirectory == true ? folderSize(f) : Int64(v.totalFileAllocatedSize ?? 0)
            guard size > 5_000_000 else { continue }
            out.append(Junk(title: "Descarga vieja · \(f.lastPathComponent)", detail: "En Descargas desde \(d.formatted(date: .abbreviated, time: .omitted)). Revisa antes de marcar",
                            urls: [f], size: size, selected: false))
        }

        let downloads = home.appendingPathComponent("Downloads")
        for f in (try? fm.contentsOfDirectory(at: downloads, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])) ?? []
        where ["dmg", "pkg"].contains(f.pathExtension.lowercased()) {
            let size = Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
            out.append(Junk(title: "Instalador · \(f.lastPathComponent)", detail: "En Descargas; si ya instalaste la app, sobra",
                            urls: [f], size: size, selected: false))
        }
        return out
    }

    func clean() async {
        let urls = items.filter(\.selected).flatMap(\.urls)
        guard !urls.isEmpty else { return }
        status = "Moviendo a la Papelera…"
        let moved = await recycle(urls)
        status = "Listo: \(plural(moved, "elemento", "elementos")) en la Papelera."
        record("Limpieza: \(formatBytes(selectedSize)) a la Papelera")
        scan()
    }

    @Published var oldTrash: [URL] = []
    @Published var trashLocked = false
    @Published var oldTrashSize: Int64 = 0

    func scanTrash() {
        Task.detached {
            let keys: Set<URLResourceKey> = [.addedToDirectoryDateKey, .isDirectoryKey, .totalFileAllocatedSizeKey]
            let cutoff = Date().addingTimeInterval(-30 * 86400)
            let all = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"), includingPropertiesForKeys: Array(keys))
            let items = (all ?? []).filter { ((try? $0.resourceValues(forKeys: keys))?.addedToDirectoryDate ?? Date()) < cutoff }
            let size = items.reduce(Int64(0)) { t, u in
                let v = try? u.resourceValues(forKeys: keys)
                return t + (v?.isDirectory == true ? folderSize(u) : Int64(v?.totalFileAllocatedSize ?? 0))
            }
            await MainActor.run { self.oldTrash = items; self.oldTrashSize = size; self.trashLocked = all == nil }
        }
    }

    func emptyOldTrash() {
        let removed = oldTrash.filter { (try? FileManager.default.removeItem(at: $0)) != nil }.count
        status = "Borré para siempre \(plural(removed, "elemento", "elementos")) que llevaban más de 30 días en la Papelera."
        record(status)
        scanTrash()
    }
}

struct CleanerView: View {
    @ObservedObject var c: Cleaner
    @State private var confirmTrash = false
    @State private var confirmOld = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header(title: "Limpieza profunda", subtitle: "Espacio que se recupera sin perder nada tuyo. Tú decides qué se va, y todo pasa por la Papelera.")
            HStack {
                Button { c.scan() } label: { Label("Escanear", systemImage: "magnifyingglass") }.buttonStyle(PrimaryButton()).disabled(c.scanning).help("Busca basura sin borrar nada todavía")
                Spacer()
                if c.trashLocked {
                    Button("Dar acceso a la Papelera") { openSettings("com.apple.preference.security?Privacy_AllFiles") }
                        .help("macOS no deja ver qué hay en la Papelera sin Acceso total al disco. Activa TP Optimizer en esa lista")
                } else if !c.oldTrash.isEmpty {
                    Button("Vaciar lo viejo (\(formatBytes(c.oldTrashSize)))") { confirmOld = true }
                    .help("Borra para siempre solo lo que lleva más de 30 días en la Papelera. Lo reciente se queda por si te arrepientes")
                }
                Button("Vaciar Papelera") { confirmTrash = true }.help("Borra para siempre lo que hay en la Papelera. Te pide confirmar")
            }
            if c.scanning { ProgressView().controlSize(.small) }
            Text(c.status).foregroundStyle(.secondary)
            if !c.items.isEmpty {
                List($c.items) { $j in
                    HStack {
                        Toggle("", isOn: $j.selected).labelsHidden()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(j.title).fontWeight(.medium)
                            Text(j.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(formatBytes(j.size)).monospacedDigit()
                    }
                    .help(j.urls.prefix(3).map(\.path).joined(separator: "\n") + (j.urls.count > 3 ? "\n… y \(j.urls.count - 3) más" : ""))
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                HStack {
                    Text("Seleccionado: \(formatBytes(c.selectedSize))").fontWeight(.medium)
                    Spacer()
                    Button("Mover a la Papelera") { Task { await c.clean() } }.buttonStyle(PrimaryButton()).disabled(c.selectedSize == 0).help("Mueve lo marcado a la Papelera. Puedes sacarlo de ahí si te arrepientes")
                }
            } else if !c.report.isEmpty {
                ScrollView { Text(c.report).font(.body.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                Placeholder(symbol: "sparkles", text: "Toca Escanear para ver qué se puede limpiar")
            }
        }
        .padding()
        .onAppear { c.scanTrash() }
        .confirmationDialog("Vaciar la Papelera borra para siempre lo que tenga dentro.", isPresented: $confirmTrash) {
            Button("Vaciar", role: .destructive) {
                if emptyTrash() { record("Vacié la Papelera") } else { c.status = "No pude vaciar la Papelera: macOS no dio permiso a Finder." }
                c.scanTrash()
            }
        }
        .confirmationDialog("¿Borrar para siempre \(c.oldTrash.count) elementos (\(formatBytes(c.oldTrashSize))) que llevan más de 30 días en la Papelera? No se puede deshacer.", isPresented: $confirmOld) {
            Button("Borrar para siempre", role: .destructive) { c.emptyOldTrash() }
        }
    }
}
