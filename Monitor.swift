import SwiftUI
import AppKit

struct Stats {
    let ramFree: String, swap: String, cpu: String, disk: String, uptime: Double

    static func read() -> Stats {
        let load = Double(shell("sysctl -n vm.loadavg | awk '{print $2}'").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let free = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        return Stats(ramFree: shell("memory_pressure | awk -F': ' '/free percentage/{print $2}'").trimmingCharacters(in: .whitespacesAndNewlines),
                     swap: shell("sysctl -n vm.swapusage | awk '{v=$6; sub(/M/,\"\",v); printf \"%.1f GB\", v/1024}'").trimmingCharacters(in: .whitespacesAndNewlines),
                     cpu: String(format: "%.0f%%", min(100, load / Double(ProcessInfo.processInfo.activeProcessorCount) * 100)),
                     disk: free.map(formatBytes) ?? "?", uptime: uptimeDays())
    }
}

struct Proc {
    let pid: Int32, ppid: Int32, rssKB: Int, cpu: Double, age: String, path: String, stopped: Bool, slow: Bool
    var name: String { (path as NSString).lastPathComponent }
}

struct Item: Identifiable {
    let id: Int32
    let name: String
    let icon: NSImage
    let kind: Kind
    let app: NSRunningApplication?
    let ramMB: Int
    let cpu: Double
    let procs: [Proc]
    enum Kind: String, CaseIterable { case open = "Abiertas", background = "Segundo plano", loose = "Procesos sueltos" }
    var protected: Bool {
        Item.protectedNames.contains(name) || (app != nil && app?.bundleIdentifier == Bundle.main.bundleIdentifier)
            || (kind != .open && Item.systemPrefixes.contains { procs.first?.path.hasPrefix($0) == true })
    }
    static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]
    var paused: Bool { procs.first?.stopped ?? false }
    static let protectedNames: Set<String> = ["Finder", "Dock", "SystemUIServer", "loginwindow", "ControlCenter", "Centro de control",
                                              "NotificationCenter", "Centro de notificaciones", "WindowManager", "Spotlight", "Optimizer", "TP Optimizer", "Claude", "claude"]
}

func snapshot() -> [Proc] {
    let uid = getuid()
    return shell("ps -axo pid=,ppid=,uid=,rss=,%cpu=,stat=,etime=,pri=,comm=").split(separator: "\n").compactMap { line in
        let f = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard f.count == 9, let pid = Int32(f[0]), let ppid = Int32(f[1]), let u = UInt32(f[2]), u == uid,
              let rss = Int(f[3]), let cpu = Double(f[4].replacingOccurrences(of: ",", with: ".")) else { return nil }
        return Proc(pid: pid, ppid: ppid, rssKB: rss, cpu: cpu, age: String(f[6]), path: String(f[8]), stopped: f[5].hasPrefix("T"), slow: (Int(f[7]) ?? 99) <= 4)
    }
}

func cwd(_ pid: Int32) -> String {
    shell("lsof -a -p \(pid) -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'").trimmingCharacters(in: .whitespacesAndNewlines)
}

@MainActor
final class Monitor: ObservableObject {
    @Published var items: [Item] = []
    @Published var selected: Set<Int32> = []
    @Published var ramFree = "?"
    @Published var swap = "?"
    @Published var disk = "?"
    @Published var cpuLoad = "?"
    @Published var thermal = "Normal"
    @Published var hot = false
    @Published var uptime = 0.0
    @Published var relieved: Set<Int32> = []
    private var selfLowered: Set<Int32> = []

    static func noteRelieved(_ pids: Set<Int32>, _ on: Bool) {
        var set = Set(UserDefaults.standard.array(forKey: "relievedPIDs") as? [Int32] ?? [])
        if on { set.formUnion(pids) } else { set.subtract(pids) }
        UserDefaults.standard.set(Array(set), forKey: "relievedPIDs")
    }

    static func restorePersisted() {
        let pids = UserDefaults.standard.array(forKey: "relievedPIDs") as? [Int32] ?? []
        guard !pids.isEmpty else { return }
        let procs = snapshot()
        _ = setPolicy(withDescendants(Set(pids), procs), false)
        UserDefaults.standard.set([Int32](), forKey: "relievedPIDs")
    }

    static func wakePersisted() {
        let pids = UserDefaults.standard.array(forKey: "pausedPIDs") as? [Int32] ?? []
        pids.forEach { kill($0, SIGCONT) }
        UserDefaults.standard.set([Int32](), forKey: "pausedPIDs")
    }

    static func notePaused(_ pids: [Int32], _ paused: Bool) {
        var set = Set(UserDefaults.standard.array(forKey: "pausedPIDs") as? [Int32] ?? [])
        if paused { set.formUnion(pids) } else { set.subtract(pids) }
        UserDefaults.standard.set(Array(set), forKey: "pausedPIDs")
    }

    static func withDescendants(_ roots: Set<Int32>, _ procs: [Proc]) -> Set<Int32> {
        var all = roots, grew = true
        while grew {
            grew = false
            for p in procs where !all.contains(p.pid) && all.contains(p.ppid) { all.insert(p.pid); grew = true }
        }
        return all
    }
    @Published var status = ""
    @Published var busy: Set<Int32> = []
    private var hotStreak: [Int32: Int] = [:]
    var ramFreePct: Double { Double(ramFree.replacingOccurrences(of: "%", with: "")) ?? 100 }
    var swapGB: Double { Double(swap.replacingOccurrences(of: " GB", with: "").replacingOccurrences(of: ",", with: ".")) ?? 0 }
    var diskGB: Double {
        Double((try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0) / 1e9
    }

    private var ticker: Timer?

    init() { DispatchQueue.main.async { self.startTicker() } }

    func startTicker() {
        guard ticker == nil else { return }
        quickStats()
        ticker = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in Task { @MainActor in self?.quickStats() } }
    }

    func quickStats() {
        Task {
            apply(await Task.detached { Stats.read() }.value)
            TelegramBot.shared.watchHealth()
        }
    }

    private func apply(_ st: Stats) {
        ramFree = st.ramFree
        swap = st.swap
        cpuLoad = st.cpu
        disk = st.disk
        uptime = st.uptime
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "Normal"; hot = false
        case .fair: thermal = "Tibia"; hot = false
        case .serious: thermal = "Caliente"; hot = true
        case .critical: thermal = "Crítica"; hot = true
        @unknown default: thermal = "?"
        }
    }

    private var loading = false

    func refresh() { Task { await reload() } }

    func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let apps = NSWorkspace.shared.runningApplications.sorted { ($0.activationPolicy == .regular ? 0 : 1) < ($1.activationPolicy == .regular ? 0 : 1) }
        let (procs, st) = await Task.detached { (snapshot(), Stats.read()) }.value
        var children: [Int32: [Proc]] = [:]
        for p in procs { children[p.ppid, default: []].append(p) }
        func tree(_ pid: Int32) -> [Proc] {
            var out: [Proc] = [], stack = [pid]
            while let cur = stack.popLast() {
                for c in children[cur] ?? [] { out.append(c); stack.append(c.pid) }
            }
            return out
        }
        let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var claimed = Set<Int32>()
        var result: [Item] = []
        for app in apps where !claimed.contains(app.processIdentifier) {
            guard let own = byPid[app.processIdentifier] else { continue }
            let all = [own] + tree(own.pid)
            all.forEach { claimed.insert($0.pid) }
            result.append(Item(id: own.pid, name: app.localizedName ?? own.name,
                               icon: app.icon ?? NSWorkspace.shared.icon(forFile: own.path),
                               kind: app.activationPolicy == .regular ? .open : .background, app: app,
                               ramMB: all.reduce(0) { $0 + $1.rssKB } / 1024, cpu: all.reduce(0) { $0 + $1.cpu }, procs: all))
        }
        for p in procs where p.ppid == 1 && !claimed.contains(p.pid) {
            let all = [p] + tree(p.pid)
            let ram = all.reduce(0) { $0 + $1.rssKB } / 1024
            guard ram >= 80 else { continue }
            result.append(Item(id: p.pid, name: p.name, icon: NSWorkspace.shared.icon(forFile: p.path), kind: .loose,
                               app: nil, ramMB: ram, cpu: all.reduce(0) { $0 + $1.cpu }, procs: all))
        }
        items = result.sorted { $0.ramMB > $1.ramMB }
        for item in items where !item.protected { hotStreak[item.id] = item.cpu >= 90 ? (hotStreak[item.id] ?? 0) + 1 : 0 }
        busy = Set(hotStreak.filter { $0.value >= 3 }.keys).intersection(items.map(\.id))
        selected = selected.filter { id in items.contains { $0.id == id } }
        apply(st)
        relieved = Set(procs.filter { p in p.slow && !selfLowered.contains(p.pid) && !Item.systemPrefixes.contains { p.path.hasPrefix($0) } }.map(\.pid))
    }

    nonisolated static func setPolicy(_ pids: Set<Int32>, _ on: Bool) -> Set<Int32> {
        guard !pids.isEmpty else { return [] }
        shell("for p in \(pids.map(String.init).joined(separator: " ")); do taskpolicy \(on ? "-b" : "-B") -p $p 2>/dev/null; done")
        return on ? [] : Set(snapshot().filter { pids.contains($0.pid) && $0.slow }.map(\.pid))
    }

    private func apply(_ pids: Set<Int32>, _ on: Bool) {
        if on { relieved.formUnion(pids) } else { relieved.subtract(pids) }
        Monitor.noteRelieved(pids, on)
        Task {
            let stuck = await Task.detached { Monitor.setPolicy(pids, on) }.value
            selfLowered.formUnion(stuck)
            await reload()
        }
    }

    @discardableResult
    func breathe(loose: Bool = true) -> [Item] {
        let heavy = items.filter { !$0.protected && $0.kind != .open && (loose || $0.kind == .background) && ($0.ramMB >= 300 || $0.cpu >= 15) }
        apply(Set(heavy.flatMap { $0.procs.map(\.pid) }), true)
        status = heavy.isEmpty ? "No hay nada pesado en segundo plano." : "Respiro para \(plural(heavy.count, "proceso", "procesos")) de fondo. Se quita solo al cerrar TP Optimizer."
        if !heavy.isEmpty { record("Di respiro a " + heavy.map(\.name).joined(separator: ", ")) }
        return heavy
    }

    func restoreAll() {
        let saved = Set(UserDefaults.standard.array(forKey: "relievedPIDs") as? [Int32] ?? [])
        apply(Monitor.withDescendants(Set(relievedItems.flatMap { $0.procs.map(\.pid) }).union(saved), snapshot()), false)
        status = "Todas las apps vuelven a su prioridad normal."
        record("Quité el respiro a todo")
    }

    func relieve(_ item: Item, _ on: Bool) {
        guard !item.protected else { return }
        apply(on ? Set(item.procs.map(\.pid)) : Monitor.withDescendants(Set(item.procs.map(\.pid)), snapshot()), on)
        record("\(on ? "Di respiro a" : "Quité el respiro a") \(item.name)")
    }

    func isRelieved(_ item: Item) -> Bool { item.procs.contains { relieved.contains($0.pid) } }
    var relievedItems: [Item] { items.filter { !$0.protected && isRelieved($0) } }

    func close(_ ids: Set<Int32>, force: Bool) {
        for item in items where ids.contains(item.id) && !item.protected {
            if item.paused { item.procs.forEach { kill($0.pid, SIGCONT) }; Monitor.notePaused(item.procs.map(\.pid), false) }
            if let app = item.app { _ = force ? app.forceTerminate() : app.terminate() }
            else { kill(item.id, force ? SIGKILL : SIGTERM) }
            record("\(force ? "Forcé el cierre de" : "Cerré") \(item.name)")
        }
        selected.removeAll()
        later(3)
    }

    func setPaused(_ item: Item, _ pause: Bool) {
        guard !item.protected else { return }
        item.procs.forEach { kill($0.pid, pause ? SIGSTOP : SIGCONT) }
        Monitor.notePaused(item.procs.map(\.pid), pause)
        record("\(pause ? "Dormí" : "Desperté") \(item.name)")
        later(1)
    }

    func killProcess(_ pid: Int32) { kill(pid, SIGTERM); later(2) }

    private func later(_ s: Double) { DispatchQueue.main.asyncAfter(deadline: .now() + s) { self.refresh() } }
}

struct MonitorView: View {
    @ObservedObject var m: Monitor
    @ObservedObject var watch: StartupWatch
    @ObservedObject var ssd: SSDWatch
    @ObservedObject var night: NightMode
    @ObservedObject var cleaner: Cleaner
    @State private var focus: Int32?
    @State private var confirmClose = false
    @State private var filter: Item.Kind?
    @State private var sort = 0
    @State private var search = ""
    let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 12) {
                HealthCard(m: m, watch: watch, ssd: ssd, night: night, cleaner: cleaner)
                HStack(spacing: 0) {
                    StatChip(title: "RAM disponible", value: m.ramFree, symbol: "memorychip", tip: "Memoria que macOS puede dar ahora mismo. Por debajo de 20% la Mac empieza a ir lenta")
                    Divider().frame(height: 30)
                    StatChip(title: "Swap usado", value: m.swap, symbol: "arrow.left.arrow.right", tip: "Memoria que macOS tuvo que pasar al disco porque la RAM no alcanzó. Mucho swap = Mac lenta. Se vacía al reiniciar")
                    Divider().frame(height: 30)
                    StatChip(title: "Uso de CPU", value: m.cpuLoad, symbol: "cpu", tip: "Cuánto trabaja el procesador, promedio del último minuto")
                    Divider().frame(height: 30)
                    StatChip(title: "Temperatura", value: m.thermal, symbol: m.hot ? "thermometer.high" : "thermometer.medium", tint: m.hot ? .red : .brandTeal, tip: "Nivel térmico que usa macOS. En Caliente o Crítica, macOS frena el procesador para enfriarse. macOS no deja leer los grados exactos")
                    Divider().frame(height: 30)
                    StatChip(title: "Disco libre", value: m.disk, symbol: "internaldrive", tip: "Espacio libre en el disco de la Mac, sin contar el SSD")
                }
                .padding(.vertical, 12).padding(.horizontal, 16)
                .card(14)
                Picker("", selection: $filter) {
                    Text("Todo").tag(Item.Kind?.none)
                    ForEach(Item.Kind.allCases, id: \.self) { Text($0.rawValue).tag(Item.Kind?.some($0)) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .help("Abiertas: apps con ventana. Segundo plano: apps sin ventana. Procesos sueltos: bots y servidores que no cuelgan de ninguna app")
                HStack(spacing: 10) {
                    Text("Ordenar por").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $sort) {
                        Label("RAM", systemImage: "memorychip").tag(0)
                        Label("CPU", systemImage: "cpu").tag(1)
                        Label("Nombre", systemImage: "textformat").tag(2)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().help("Ordena la lista por memoria, procesador o nombre")
                    TextField("Buscar app", text: $search).textFieldStyle(.roundedBorder).frame(minWidth: 120).help("Escribe parte del nombre para filtrar")
                }
                List(selection: $focus) {
                    ForEach(Item.Kind.allCases.filter { filter == nil || $0 == filter }, id: \.self) { kind in
                        let group = shown.filter { $0.kind == kind }
                        if !group.isEmpty {
                            Section("\(kind.rawValue) · \(group.reduce(0) { $0 + $1.ramMB }) MB") {
                                ForEach(group) { ProcRow(item: $0, m: m).tag($0.id) }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                HStack {
                    Button("Cerrar seleccionadas (\(m.selected.count))") { confirmClose = true }.disabled(m.selected.isEmpty).help("Cierra las apps marcadas. Cada una te pide guardar si hace falta")
                    Text(m.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if !m.relievedItems.isEmpty {
                        Button("Quitar respiro (\(m.relievedItems.count))") { m.restoreAll() }
                            .help("Con prioridad baja ahora: " + m.relievedItems.map(\.name).joined(separator: ", ") + ". Toca para devolverlas a su prioridad normal")
                    }
                    Button { m.breathe() } label: { Label("Dar respiro", systemImage: "wind") }.buttonStyle(PrimaryButton())
                        .help("Manda al final de la fila del procesador lo pesado en segundo plano y los procesos sueltos. Tus apps abiertas no se tocan. Nada se cierra, y se quita solo al cerrar TP Optimizer")
                }
            }
        .padding()
        .inspector(isPresented: Binding(get: { focus != nil }, set: { if !$0 { focus = nil } })) {
            Group {
                if let id = focus, let item = m.items.first(where: { $0.id == id }) { DeepLook(item: item, m: m) }
                else { Placeholder(symbol: "sparkle.magnifyingglass", text: "La app ya no está abierta") }
            }
            .inspectorColumnWidth(min: 280, ideal: 330, max: 460)
        }
        .onAppear { m.refresh() }
        .onReceive(timer) { _ in m.refresh() }
        .confirmationDialog(closeMessage, isPresented: $confirmClose) {
            Button("Cerrar", role: .destructive) { m.close(m.selected, force: false) }
        }
    }

    var shown: [Item] {
        let q = search.lowercased()
        let list = q.isEmpty ? m.items : m.items.filter { $0.name.lowercased().contains(q) }
        switch sort {
        case 1: return list.sorted { $0.cpu > $1.cpu }
        case 2: return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        default: return list
        }
    }

    var closeMessage: String {
        let names = m.items.filter { m.selected.contains($0.id) }.map(\.name)
        return "¿Cerrar \(names.joined(separator: ", "))? Cada app te pedirá guardar si hace falta."
            + (names.contains("Claude") ? " Cerrar Claude cierra todos tus chats." : "")
    }
}

struct ProcRow: View {
    let item: Item
    @ObservedObject var m: Monitor
    var caption: String {
        if item.app?.bundleIdentifier == Bundle.main.bundleIdentifier { return "Esta app" }
        if item.protected { return "Del sistema" }
        if item.paused { return "Dormida" }
        if m.busy.contains(item.id) { return "Usa mucho procesador hace rato" }
        let since = item.app?.launchDate.map { "abierta " + $0.formatted(.relative(presentation: .named)) } ?? "hace \(humanAge(item.procs.first?.age ?? "?"))"
        return "\(plural(item.procs.count, "proceso", "procesos")) · \(since)" + (m.isRelieved(item) ? " · con respiro (prioridad baja)" : "")
    }
    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { m.selected.contains(item.id) },
                                     set: { if $0 { m.selected.insert(item.id) } else { m.selected.remove(item.id) } }))
                .labelsHidden().disabled(item.protected)
            Image(nsImage: item.icon).resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).fontWeight(.medium)
                Text(caption).font(.caption).foregroundStyle(item.paused ? Color.indigo : m.busy.contains(item.id) ? Color.orange : m.isRelieved(item) ? Color.brandTeal : .secondary)
            }
            Spacer()
            Text(String(format: "%.0f%%", item.cpu)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text("\(item.ramMB) MB").monospacedDigit().frame(width: 76, alignment: .trailing)
                .foregroundStyle(item.ramMB > 1000 ? Color.red : item.ramMB > 400 ? .orange : .primary)
        }
        .padding(.vertical, 2)
        .help(item.app?.bundleURL?.path ?? item.procs.first?.path ?? item.name)
    }
}

struct DeepLook: View {
    let item: Item
    @ObservedObject var m: Monitor
    @State private var folders: [Int32: String] = [:]
    @State private var confirmForce = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(nsImage: item.icon).resizable().frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.title2.bold())
                        Text("\(item.kind.rawValue) · \(item.ramMB) MB · \(String(format: "%.0f", item.cpu))% CPU").foregroundStyle(.secondary)
                    }
                }
                if let app = item.app {
                    if let url = app.bundleURL { Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    if let d = app.launchDate { Text("Abierta desde \(d.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                }
                if item.name == "Claude" { Label("Cerrar o dormir Claude afecta a todos tus chats.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if !item.protected {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                        Button("Cerrar") { m.close([item.id], force: false) }.help("Cierra la app como si le dieras Cmd+Q")
                        Button(item.paused ? "Despertar" : "Dormir") { m.setPaused(item, !item.paused) }.help(item.paused ? "La descongela y sigue donde estaba" : "La congela: deja de usar procesador hasta que la despiertes. Su memoria queda ocupada")
                        Button(m.isRelieved(item) ? "Prioridad normal" : "Dar respiro") { m.relieve(item, !m.isRelieved(item)) }.help("Sigue funcionando, pero pasa al final de la fila del procesador para que lo que usas vaya más rápido")
                        Button("Forzar cierre", role: .destructive) { confirmForce = true }.help("Cierra de golpe, sin preguntar. Úsalo solo si la app no responde")
                    }
                    Text("Dormir congela la app hasta que la despiertes. Dar respiro la deja funcionando con menos prioridad.").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text("Procesos, de mayor a menor RAM").font(.headline)
                ForEach(item.procs.sorted { $0.rssKB > $1.rssKB }.prefix(40), id: \.pid) { p in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).font(.callout.weight(.medium))
                            Text("PID \(p.pid) · hace \(humanAge(p.age))" + (folders[p.pid].map { " · \($0)" } ?? ""))
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Text("\(p.rssKB / 1024) MB").font(.callout.monospacedDigit())
                        if p.pid != item.id && !item.protected { Button("Cerrar") { m.killProcess(p.pid) }.controlSize(.small).help("Cierra solo este proceso: \(p.path)") }
                    }
                    Divider()
                }
            }
            .padding()
        }
        .task(id: item.id) {
            folders = [:]
            for p in item.procs.sorted(by: { $0.rssKB > $1.rssKB }).prefix(15) {
                let pid = p.pid
                let dir = await Task.detached { cwd(pid) }.value
                if !dir.isEmpty && dir != "/" { folders[pid] = dir.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
            }
        }
        .confirmationDialog("¿Forzar el cierre de \(item.name)? Se pierde lo que no esté guardado.", isPresented: $confirmForce) {
            Button("Forzar cierre", role: .destructive) { m.close([item.id], force: true) }
        }
    }
}
