import SwiftUI
import AppKit

struct InstalledApp: Identifiable {
    let id: URL
    let name: String
    let bundleID: String
    let icon: NSImage
    let size: Int64
    let leftovers: [URL]
    let leftoverSize: Int64
    let lastUsed: Date?
}

@MainActor
final class AppsModel: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var scanning = false
    @Published var status = ""

    func scan() {
        scanning = true
        status = "Revisando apps…"
        Task.detached {
            let found = AppsModel.find()
            await MainActor.run { self.apps = found; self.scanning = false; self.status = "\(found.count) apps que puedes desinstalar." }
        }
    }

    nonisolated static func find() -> [InstalledApp] {
        let fm = FileManager.default
        let lib = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        let places = ["Application Support", "Caches", "Containers", "Group Containers", "Preferences", "Saved Application State", "Logs", "HTTPStorages", "WebKit", "Application Scripts", "LaunchAgents"]
        var out: [InstalledApp] = []
        for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
            for url in (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "app" {
                guard let b = Bundle(url: url), let id = b.bundleIdentifier, !id.hasPrefix("com.apple.") else { continue }
                let name = (b.infoDictionary?["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
                var left: [URL] = []
                for place in places {
                    let base = lib.appendingPathComponent(place)
                    for entry in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] where entry.hasPrefix(id) || entry == name {
                        left.append(base.appendingPathComponent(entry))
                    }
                }
                let used = (try? url.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate
                out.append(InstalledApp(id: url, name: name, bundleID: id, icon: NSWorkspace.shared.icon(forFile: url.path),
                                        size: folderSize(url), leftovers: left, leftoverSize: left.reduce(0) { $0 + folderSize($1) }, lastUsed: used))
            }
        }
        return out.sorted { $0.size + $0.leftoverSize > $1.size + $1.leftoverSize }
    }

    func uninstall(_ app: InstalledApp) async {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first {
            running.terminate()
            try? await Task.sleep(for: .seconds(2))
        }
        for agent in app.leftovers where agent.deletingLastPathComponent().lastPathComponent == "LaunchAgents" {
            shell("launchctl bootout gui/\(getuid()) \(q(agent.path)) 2>/dev/null")
        }
        let all = 1 + app.leftovers.count
        let moved = await recycle([app.id] + app.leftovers)
        let gone = !FileManager.default.fileExists(atPath: app.id.path)
        status = gone
            ? (moved == all ? "\(app.name) desinstalada: \(moved) elementos en la Papelera." : "\(app.name) desinstalada, pero solo pude mover \(moved) de \(all) elementos: quedan restos.")
            : "No pude mover \(app.name) a la Papelera. Puede que macOS pida permiso."
        if gone { apps.removeAll { $0.id == app.id }; record("Desinstalé \(app.name) (\(moved) de \(all) elementos)") }
    }
}

struct AppsView: View {
    @ObservedObject var a: AppsModel
    @State private var target: InstalledApp?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header(title: "Desinstalar apps", subtitle: "Elimina una app por completo, con los rastros que suele dejar atrás. Las de Apple quedan a salvo.")
            HStack {
                Button { a.scan() } label: { Label("Buscar apps", systemImage: "square.grid.2x2") }.buttonStyle(PrimaryButton()).disabled(a.scanning).help("Lista las apps que no son de Apple, con cuánto ocupan")
                if a.scanning { ProgressView().controlSize(.small) }
                Text(a.status).foregroundStyle(.secondary)
            }
            if a.apps.isEmpty {
                Placeholder(symbol: "square.grid.2x2", text: "Toca Buscar apps")
            } else {
                List(a.apps) { app in
                    HStack(spacing: 10) {
                        Image(nsImage: app.icon).resizable().frame(width: 32, height: 32)
                            .help("\(app.id.path)\n\(app.bundleID)" + (app.leftovers.isEmpty ? "" : "\nRestos:\n" + app.leftovers.map(\.path).joined(separator: "\n")))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name).fontWeight(.medium)
                            Text(app.lastUsed.map { "Usada por última vez: \($0.formatted(date: .abbreviated, time: .omitted))" } ?? app.bundleID)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(formatBytes(app.size + app.leftoverSize)).monospacedDigit()
                            if app.leftoverSize > 0 { Text("restos \(formatBytes(app.leftoverSize))").font(.caption).foregroundStyle(.secondary) }
                        }
                        Button("Desinstalar") { target = app }
                            .disabled(app.bundleID == "com.anthropic.claudefordesktop")
                            .help(app.bundleID == "com.anthropic.claudefordesktop" ? "Claude corre esta sesión y tus chats: no se desinstala desde aquí" : "Quita la app y sus restos. Todo va a la Papelera")
                    }
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding()
        .confirmationDialog(target.map { "¿Desinstalar \($0.name)? La app y \($0.leftovers.count) restos (\(formatBytes($0.leftoverSize))) van a la Papelera. Los restos incluyen sus datos: perfiles, sesiones y ajustes." } ?? "",
                            isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })) {
            Button("Desinstalar", role: .destructive) { if let t = target { Task { await a.uninstall(t) } } }
        }
    }
}
