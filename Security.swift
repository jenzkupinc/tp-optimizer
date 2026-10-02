import SwiftUI
import AppKit

struct Check: Identifiable {
    var id: String { title }
    let title: String
    let ok: Bool
    let detail: String
    let settings: String?
}

func securityChecks() -> [Check] {
    let fw = shell("/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate")
    let ssh = shell("launchctl print-disabled system")
    let remote = ssh.contains("\"com.openssh.sshd\" => enabled")
    return [
        Check(title: "Protección del sistema (SIP)", ok: shell("csrutil status").contains("enabled"),
              detail: "Impide que un programa modifique macOS por dentro", settings: nil),
        Check(title: "Cifrado del disco (FileVault)", ok: shell("fdesetup status").contains("On"),
              detail: "Si te roban la Mac, nadie lee tus archivos sin tu clave", settings: "com.apple.settings.PrivacySecurity.extension"),
        Check(title: "Firewall", ok: fw.contains("enabled"),
              detail: "Bloquea conexiones que llegan de afuera sin permiso", settings: "com.apple.Network-Settings.extension"),
        Check(title: "Gatekeeper", ok: shell("spctl --status").contains("enabled"),
              detail: "Revisa que las apps que abres vengan de un desarrollador conocido", settings: "com.apple.settings.PrivacySecurity.extension"),
        Check(title: remote ? "Inicio de sesión remoto (SSH) encendido" : "Inicio de sesión remoto (SSH) apagado", ok: !remote,
              detail: remote ? "Cualquiera con tu usuario y clave puede entrar por terminal desde tu red. Si no lo usas con Termius, apágalo" : "Nadie puede entrar por terminal desde afuera",
              settings: "com.apple.Sharing-Settings.extension"),
    ]
}

enum Signature: String { case unsigned = "Sin firma", adhoc = "Firma local", developer = "Desarrollador identificado", apple = "Apple" }

struct SignedProc: Identifiable {
    var id: String { path }
    let path: String
    let sig: Signature
    let author: String
    var name: String { (path as NSString).lastPathComponent }
    var devTool: Bool {
        let home = NSHomeDirectory()
        return ["/opt/homebrew", "/usr/local", home + "/.nvm", home + "/.bun", home + "/.local", home + "/.claude", home + "/Library/Caches/ms-playwright", home + "/.cache"]
            .contains { path.hasPrefix($0) } || path.contains("node_modules") || path.contains(".venv")
    }
}

func signatures() -> [SignedProc] {
    let paths = Set(shell("ps -axo comm=").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("/") })
    return paths.filter { !$0.hasPrefix("/System/") && !$0.hasPrefix("/usr/libexec/") && !$0.hasPrefix("/usr/sbin/") && !$0.hasPrefix("/sbin/") && !$0.hasPrefix("/Library/Apple/") }
        .map { path -> SignedProc in
            let out = shell("codesign -dv --verbose=2 \(q(path)) 2>&1")
            let authority = out.split(separator: "\n").first { $0.hasPrefix("Authority=") }.map { String($0.dropFirst(10)) } ?? ""
            let sig: Signature = out.contains("not signed at all") ? .unsigned
                : out.contains("Signature=adhoc") ? .adhoc
                : authority.contains("Apple") && !authority.contains("Developer ID") ? .apple : .developer
            return SignedProc(path: path, sig: sig, author: authority.replacingOccurrences(of: "Developer ID Application: ", with: ""))
        }
        .filter { $0.sig != .apple }
        .sorted { ($0.sig == .unsigned ? 0 : $0.sig == .adhoc ? 1 : 2, $0.name) < ($1.sig == .unsigned ? 0 : $1.sig == .adhoc ? 1 : 2, $1.name) }
}

struct Access: Identifiable {
    let id = UUID()
    let date: Date
    let what: String
    let from: String
}

func accesses() -> [Access] {
    var out: [Access] = []
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let dir = NSHomeDirectory() + "/Library/Logs/RustDesk"
    let logs = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".log") }
    for log in logs {
        guard let text = try? String(contentsOfFile: dir + "/" + log, encoding: .utf8) else { continue }
        for line in text.split(separator: "\n") where line.contains("create_relay requested from") || line.contains("Connection closed") {
            guard line.count > 21, let d = fmt.date(from: String(line.dropFirst().prefix(19))) else { continue }
            if line.contains("create_relay"), let r = line.range(of: #"from [0-9.]+"#, options: .regularExpression) {
                out.append(Access(date: d, what: "RustDesk: alguien se conectó", from: String(line[r].dropFirst(5))))
            } else if line.contains("Connection closed") {
                out.append(Access(date: d, what: "RustDesk: se cerró la conexión", from: ""))
            }
        }
    }
    let lastFmt = DateFormatter()
    lastFmt.locale = Locale(identifier: "en_US_POSIX")
    lastFmt.dateFormat = "EEE MMM d HH:mm yyyy"
    let year = Calendar.current.component(.year, from: Date())
    for line in shell("last -50").split(separator: "\n") where !line.contains("ttys") && !line.hasPrefix("wtmp") && !line.isEmpty {
        let cols = line.split(separator: " ", omittingEmptySubsequences: true)
        guard cols.count >= 7 else { continue }
        let hasHost = cols[2].contains(".") || cols[2].contains(":")
        let dateStart = hasHost ? 3 : 2
        guard cols.count > dateStart + 3,
              let d = lastFmt.date(from: cols[dateStart...(dateStart + 3)].joined(separator: " ") + " \(year)") else { continue }
        let what = cols[1] == "console" ? "Inicio de sesión en la Mac" : cols[0] == "reboot" ? "La Mac se encendió" : cols[0] == "shutdown" ? "La Mac se apagó" : "Entrada por \(cols[1])"
        out.append(Access(date: d, what: what, from: hasHost ? String(cols[2]) : ""))
    }
    return out.sorted { $0.date > $1.date }.prefix(80).map { $0 }
}

@MainActor
final class InstallWatch: ObservableObject {
    @Published var fresh: [String] = []
    private var timer: Timer?
    static let key = "knownInstalls"

    init() {
        Task {
            if UserDefaults.standard.array(forKey: InstallWatch.key) == nil { await accept() }
            await check()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in Task { await self?.check() } }
    }

    nonisolated static func current() -> Set<String> {
        let fm = FileManager.default
        var all = Set<String>()
        for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".app") }.forEach { all.insert("App: " + $0.replacingOccurrences(of: ".app", with: "")) }
        }
        let brew = "/opt/homebrew/bin/brew"
        if fm.fileExists(atPath: brew) {
            shell("\(brew) list --formula -1 2>/dev/null").split(separator: "\n").forEach { all.insert("Homebrew: \($0)") }
            shell("\(brew) list --cask -1 2>/dev/null").split(separator: "\n").forEach { all.insert("Homebrew: \($0)") }
        }
        return all
    }

    func check() async {
        let known = Set(UserDefaults.standard.array(forKey: InstallWatch.key) as? [String] ?? [])
        let now = await Task.detached { InstallWatch.current() }.value
        let added = now.subtracting(known).subtracting(fresh).sorted()
        guard !added.isEmpty else { return }
        fresh += added
        notify("Se instaló algo nuevo", added.joined(separator: ", "))
        TelegramBot.shared.alert("Se instaló algo nuevo en la Mac: \(added.joined(separator: ", "))")
        record("Detecté instalación nueva: \(added.joined(separator: ", "))")
    }

    func accept() async {
        let now = await Task.detached { InstallWatch.current() }.value
        UserDefaults.standard.set(Array(now), forKey: InstallWatch.key)
        fresh = []
    }
}

struct SecurityPane: View {
    @ObservedObject var installs: InstallWatch
    @State private var checks: [Check] = []
    @State private var procs: [SignedProc] = []
    @State private var access: [Access] = []
    @State private var scanning = false
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header(title: "Seguridad", subtitle: "El estado de tus defensas, lo que corre sin firma y quién ha entrado a tu Mac.")
            HStack(spacing: 10) {
                ForEach(checks) { c in
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: c.ok ? "checkmark.shield.fill" : "exclamationmark.shield.fill").font(.title2).foregroundStyle(c.ok ? Color.green : .orange)
                        Text(c.title).font(.callout.weight(.semibold)).lineLimit(2)
                        Text(c.detail).font(.caption).foregroundStyle(.secondary).lineLimit(5)
                        Spacer(minLength: 0)
                        if let s = c.settings, !c.ok { Button("Abrir Ajustes") { openSettings(s) }.controlSize(.small) }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                    .card(12, tint: c.ok ? nil : .orange)
                }
            }
            if !installs.fresh.isEmpty {
                HStack {
                    Label("Instalado hace poco: \(installs.fresh.joined(separator: ", "))", systemImage: "shippingbox.fill").foregroundStyle(.orange).lineLimit(2)
                    Spacer()
                    Button("Marcar como revisado") { Task { await installs.accept() } }
                }
            }
            Picker("", selection: $tab) {
                Text("Procesos y su firma").tag(0)
                Text("Accesos a tu Mac").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if tab == 0 { procList } else { accessList }
        }
        .padding()
        .task {
            scanning = true
            async let c = Task.detached { securityChecks() }.value
            async let a = Task.detached { accesses() }.value
            async let p = Task.detached { signatures() }.value
            checks = await c
            access = await a
            procs = await p
            scanning = false
        }
    }

    var procList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if scanning { ProgressView().controlSize(.small); Text("Revisando la firma de cada programa…").foregroundStyle(.secondary) }
                else { Text("Sin firma no significa malicioso: tus bots, Python y Node casi nunca tienen firma. Revisa lo que esté en rojo.").font(.caption).foregroundStyle(.secondary) }
            }
            List(procs) { p in
                HStack(spacing: 10) {
                    Circle().fill(p.sig == .developer ? Color.green : p.devTool ? Color.secondary.opacity(0.5) : .red).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).fontWeight(.medium)
                        Text(p.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    Spacer()
                    Text(p.sig == .developer ? p.author : p.devTool ? "\(p.sig.rawValue) · herramienta tuya" : "\(p.sig.rawValue) · revisar")
                        .font(.caption).foregroundStyle(p.sig == .developer ? Color.secondary : p.devTool ? .secondary : .red).lineLimit(1)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.path)]) } label: { Image(systemName: "folder") }
                        .buttonStyle(.plain).help("Mostrar en Finder")
                }
            }
            .listStyle(.inset)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    var accessList: some View {
        Group {
            if access.isEmpty {
                Placeholder(symbol: "person.badge.shield.checkmark", text: "No hay accesos registrados")
            } else {
                List(access) { a in
                    HStack {
                        Image(systemName: a.what.hasPrefix("RustDesk") ? "display" : "person.crop.circle").foregroundStyle(Color.brandTeal)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.what).fontWeight(.medium)
                            Text(a.date.formatted(date: .abbreviated, time: .shortened) + (a.from.isEmpty ? "" : " · desde \(a.from)"))
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}
