import SwiftUI
import AppKit
import UserNotifications

struct HealthReport {
    let score: Int
    let tips: [String]
    let restartAdvice: Bool
}

func notify(_ title: String, _ body: String) {
    let c = UNMutableNotificationContent()
    c.title = title
    c.body = body
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
}

func uptimeDays() -> Double {
    let out = shell("sysctl -n kern.boottime")
    guard let r = out.range(of: #"sec = (\d+)"#, options: .regularExpression),
          let secs = Double(out[r].split(separator: " ").last ?? "") else { return 0 }
    return (Date().timeIntervalSince1970 - secs) / 86400
}

@MainActor
func healthReport(_ m: Monitor, _ watch: StartupWatch, _ ssd: SSDWatch) -> HealthReport {
    var score = 100
    var tips: [String] = []
    func penalty(_ n: Int, _ tip: String) { score -= n; tips.append(tip) }
    if m.ramFreePct < 20 { penalty(25, "Queda poca RAM: cierra o duerme apps que no uses") } else if m.ramFreePct < 35 { penalty(10, "La RAM se está llenando") }
    if m.swapGB > 8 { penalty(20, "Swap muy lleno: reinicia cuando los bots no estén trabajando") } else if m.swapGB > 4 { penalty(10, "El swap está alto") }
    if m.diskGB < 15 { penalty(20, "Poco disco libre: pasa por Limpieza profunda o Archivos grandes") } else if m.diskGB < 30 { penalty(8, "El disco se está llenando") }
    switch ProcessInfo.processInfo.thermalState {
    case .serious: penalty(20, "La Mac está caliente: macOS ya frena el procesador")
    case .critical: penalty(35, "Temperatura crítica: cierra lo pesado ya")
    default: break
    }
    let busyNames = m.items.filter { m.busy.contains($0.id) }.map(\.name)
    if !busyNames.isEmpty { penalty(min(20, 10 * busyNames.count), "\(busyNames.joined(separator: ", ")) usa mucho procesador hace rato") }
    let slowOpen = m.relievedItems.filter { $0.kind == .open }.map(\.name)
    if !slowOpen.isEmpty { penalty(5, "\(slowOpen.joined(separator: ", ")) sigue con respiro: toca Quitar respiro si la sientes lenta") }
    if !watch.fresh.isEmpty { penalty(5, "Hay un programa nuevo que arranca solo: revísalo") }
    if !ssd.connected { penalty(10, "El SSD no está conectado: la memoria y el mapa de código no funcionan") }
    let botsWorking = m.items.contains { $0.kind == .loose && $0.cpu > 5 }
    let restart = m.swapGB > 6 && m.uptime > 3 && !botsWorking
    if tips.isEmpty { tips = ["Todo en orden"] }
    return HealthReport(score: max(0, score), tips: tips, restartAdvice: restart)
}

@MainActor
final class SSDWatch: ObservableObject {
    nonisolated static let path = "/Volumes/Respaldo"
    @Published var connected = FileManager.default.fileExists(atPath: SSDWatch.path)
    @Published var free = ""
    private var observers: [NSObjectProtocol] = []

    init() {
        update()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let was = self.connected
                    self.update()
                    if was != self.connected {
                        notify(self.connected ? "SSD conectado" : "SSD desconectado",
                               self.connected ? "La memoria y el mapa de código vuelven a funcionar." : "Conecta el disco de respaldo: los archivos movidos dependen de él.")
                        record(self.connected ? "El SSD se conectó" : "El SSD se desconectó")
                        if !self.connected { TelegramBot.shared.alert("El disco de respaldo se desconectó de la Mac.") }
                    }
                }
            })
        }
    }

    func update() {
        connected = FileManager.default.fileExists(atPath: SSDWatch.path)
        if connected, let v = try? URL(fileURLWithPath: SSDWatch.path).resourceValues(forKeys: [.volumeAvailableCapacityKey]), let b = v.volumeAvailableCapacity {
            free = formatBytes(Int64(b))
        } else { free = "—" }
    }
}

@MainActor
final class NightMode: ObservableObject {
    @Published var on = false
    @Published var slept: [String] = []
    private var awake: Process?
    static let keep: Set<String> = ["Claude", "Finder", "TP Optimizer", "Terminal", "Termius", "RustDesk", "Screen Sharing"]

    func toggle(_ m: Monitor) { Task { on ? await stop(m) : await start(m) } }

    func start(_ m: Monitor) async {
        await m.reload()
        let targets = m.items.filter { $0.kind == .open && !$0.protected && !$0.paused && !NightMode.keep.contains($0.name) }
        targets.forEach { m.setPaused($0, true) }
        slept = targets.map(\.name)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-i", "-w", "\(ProcessInfo.processInfo.processIdentifier)"]
        try? p.run()
        awake = p
        on = true
        m.status = slept.isEmpty ? "Modo noche: la Mac no se dormirá y los bots siguen." : "Modo noche: dormí \(slept.joined(separator: ", ")). La Mac no se dormirá y los bots siguen."
        record("Encendí el modo noche")
    }

    func stop(_ m: Monitor) async {
        await m.reload()
        m.items.filter { slept.contains($0.name) && $0.paused }.forEach { m.setPaused($0, false) }
        awake?.terminate()
        awake = nil
        on = false
        slept = []
        m.status = "Modo noche apagado: tus apps despertaron."
        record("Apagué el modo noche")
    }
}

@MainActor
func optimizeAll(_ m: Monitor, _ c: Cleaner) async -> String {
    let running = Set(NSWorkspace.shared.runningApplications.flatMap { [$0.bundleIdentifier, $0.localizedName].compactMap { $0?.lowercased() } })
    let junk = await Task.detached { Cleaner.find(running: running) }.value.filter(\.selected)
    let moved = await recycle(junk.flatMap(\.urls))
    await m.reload()
    m.breathe()
    let text = "Listo: \(formatBytes(junk.reduce(0) { $0 + $1.size })) de basura segura a la Papelera (\(plural(moved, "elemento", "elementos"))) y respiro para lo pesado en segundo plano."
    record(text)
    return text
}

struct HealthCard: View {
    @ObservedObject var m: Monitor
    @ObservedObject var watch: StartupWatch
    @ObservedObject var ssd: SSDWatch
    @ObservedObject var night: NightMode
    @ObservedObject var cleaner: Cleaner
    @State private var confirmAll = false
    @State private var confirmRestart = false
    @State private var working = false

    var body: some View {
        let r = healthReport(m, watch, ssd)
        let color: Color = r.score >= 80 ? .green : r.score >= 55 ? .orange : .red
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 8)
                Circle().trim(from: 0, to: CGFloat(r.score) / 100).stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round)).rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(r.score)").font(.title.bold().monospacedDigit())
                    Text("salud").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 78, height: 78)
            .help("Puntaje de 0 a 100 que junta RAM, swap, disco, temperatura, apps trabadas, arranques nuevos y el SSD")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(r.tips.prefix(3), id: \.self) { Label($0, systemImage: $0 == "Todo en orden" ? "checkmark.circle" : "lightbulb").font(.callout).lineLimit(2) }
                HStack(spacing: 6) {
                    Image(systemName: ssd.connected ? "externaldrive.fill" : "externaldrive.badge.xmark").foregroundStyle(ssd.connected ? Color.brandTeal : .red)
                    Text(ssd.connected ? "SSD conectado · \(ssd.free) libres" : "SSD desconectado").font(.caption).foregroundStyle(.secondary)
                }
                .help("El disco de respaldo guarda lo que mandaste desde la Mac")
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Button { confirmAll = true } label: { Label(working ? "Optimizando…" : "Optimizar todo", systemImage: "sparkles") }
                    .buttonStyle(PrimaryButton()).disabled(working)
                    .help("Manda a la Papelera solo la basura segura y da respiro a lo pesado en segundo plano. Te pregunta antes")
                Button { night.toggle(m) } label: { Label(night.on ? "Apagar modo noche" : "Modo noche", systemImage: night.on ? "sun.max" : "moon.stars") }
                    .help(night.on ? "Despierta tus apps y deja que la Mac vuelva a dormirse sola" : "Duerme tus apps personales, deja trabajando solo los bots y no deja que la Mac se duerma. Se apaga solo al cerrar TP Optimizer")
                if r.restartAdvice {
                    Button { confirmRestart = true } label: { Label("Buen momento para reiniciar", systemImage: "arrow.clockwise.circle") }
                        .help("El swap está lleno, la Mac lleva días encendida y ningún bot está trabajando fuerte. Reiniciar vacía el swap")
                }
            }
            .fixedSize()
        }
        .padding(14)
        .card(12)
        .confirmationDialog("Optimizar todo: se mueve a la Papelera solo lo que ya viene marcado como seguro (cachés de apps cerradas, logs viejos, compilaciones) y se da respiro a lo pesado en segundo plano. Tus apps abiertas y tus descargas no se tocan.", isPresented: $confirmAll) {
            Button("Optimizar") {
                working = true
                Task { m.status = await optimizeAll(m, cleaner); working = false }
            }
        }
        .confirmationDialog("¿Reiniciar la Mac ahora? Cada app te pedirá guardar lo que tengas abierto.", isPresented: $confirmRestart) {
            Button("Reiniciar", role: .destructive) { NSAppleScript(source: "tell application \"System Events\" to restart")?.executeAndReturnError(nil) }
        }
    }
}

struct SystemExtension: Identifiable {
    var id: String { bundleID }
    let name: String
    let bundleID: String
    let state: String
}

func systemExtensions() -> [SystemExtension] {
    shell("systemextensionsctl list").split(separator: "\n").compactMap { line in
        guard line.contains("["), let open = line.lastIndex(of: "["), let paren = line.firstIndex(of: "(") else { return nil }
        let cols = line.split(separator: "\t")
        guard cols.count >= 4, !cols[3].hasPrefix("bundleID") else { return nil }
        let idPart = cols[3].components(separatedBy: " (").first ?? ""
        let name = String(line[line.index(after: line[paren...].firstIndex(of: ")") ?? paren)..<open]).trimmingCharacters(in: .whitespaces)
        return SystemExtension(name: name, bundleID: idPart, state: String(line[open...]).trimmingCharacters(in: CharacterSet(charactersIn: "[] ")))
    }
}
