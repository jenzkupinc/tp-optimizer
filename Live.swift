import SwiftUI
import AppKit

struct Hog: Identifiable {
    let id: String
    let name: String
    let ramMB: Int
    let cpu: Double
    let slow: Bool
    var path: String { id }
    var bothers: Bool { cpu >= 30 || ramMB >= 1024 }
    var reason: String {
        var parts: [String] = []
        if cpu >= 30 { parts.append("\(Int(cpu.rounded()))% de procesador") }
        if ramMB >= 1024 { parts.append("\(memText(Int64(ramMB) << 20)) de RAM") }
        return parts.isEmpty ? "Normal" : "Usa " + parts.joined(separator: " y ")
    }
    static func ranked(_ a: Hog, _ b: Hog) -> Bool {
        func weight(_ h: Hog) -> Double { h.cpu / 100 + Double(h.ramMB) / 4096 }
        return a.bothers != b.bothers ? a.bothers : weight(a) > weight(b)
    }
}

struct Vitals {
    var freePct = 0.0
    var appBytes: Int64 = 0
    var wiredBytes: Int64 = 0
    var compressedBytes: Int64 = 0
    var freeBytes: Int64 = 0   // pages free right now, what a purge actually moves
    var cacheBytes: Int64 = 0  // file cache macOS can drop
    var totalBytes: Int64 = 0
    var usedBytes: Int64 { appBytes + wiredBytes + compressedBytes }
    var swapGB = 0.0
    var cpuPct = 0.0
    var pressure = 1
    var hogs: [Hog] = []

    var pressureName: String { pressure >= 4 ? "Crítica" : pressure == 2 ? "Alta" : "Normal" }
    var pressureColor: Color { pressure >= 4 ? .red : pressure == 2 ? .orange : .green }

    static func capture() async -> Vitals { await Task.detached { await Vitals.read() }.value }

    static func read() async -> Vitals {
        var v = Vitals()
        v.freePct = Double(sysctlInt("kern.memorystatus_level"))
        v.pressure = max(1, sysctlInt("kern.memorystatus_vm_pressure_level"))
        v.totalBytes = Int64(ProcessInfo.processInfo.physicalMemory)
        (v.appBytes, v.wiredBytes, v.compressedBytes) = memoryParts()
        (v.freeBytes, v.cacheBytes) = memoryFreeCache()
        var sw = xsw_usage()
        var n = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &sw, &n, nil, 0) == 0 { v.swapGB = Double(sw.xsu_used) / 1_073_741_824 }

        let a = psRows(), ta = cpuTicks(), t0 = Date()
        try? await Task.sleep(for: .milliseconds(600))
        let b = psRows(), tb = cpuTicks(), span = Date().timeIntervalSince(t0)
        let d = (0..<4).map { Double(tb[$0] &- ta[$0]) }
        let total = d.reduce(0, +)
        v.cpuPct = total > 0 ? (total - d[2]) / total * 100 : 0
        v.hogs = topHogs(a, b, span)
        return v
    }
}

private func sysctlInt(_ name: String) -> Int {
    var v: Int32 = 0
    var n = MemoryLayout<Int32>.size
    return sysctlbyname(name, &v, &n, nil, 0) == 0 ? Int(v) : 0
}

private func memoryParts() -> (Int64, Int64, Int64) {
    var vm = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let ok = withUnsafeMutablePointer(to: &vm) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
    }
    guard ok == KERN_SUCCESS else { return (0, 0, 0) }
    let page = Int64(vm_kernel_page_size)
    return ((Int64(vm.internal_page_count) - Int64(vm.purgeable_count)) * page, Int64(vm.wire_count) * page, Int64(vm.compressor_page_count) * page)
}

private func memoryFreeCache() -> (Int64, Int64) {
    var vm = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let ok = withUnsafeMutablePointer(to: &vm) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
    }
    guard ok == KERN_SUCCESS else { return (0, 0) }
    let page = Int64(vm_kernel_page_size)
    return (Int64(vm.free_count) * page, Int64(vm.external_page_count) * page)
}

private func cpuTicks() -> [UInt32] {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
    }
    return [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
}

private struct Row {
    let pid: Int32, ppid: Int32, rssKB: Int, seconds: Double, slow: Bool, path: String
}

private func psRows() -> [Row] {
    let uid = getuid()
    return shell("ps -axo pid=,ppid=,uid=,rss=,time=,pri=,comm=").split(separator: "\n").compactMap { line in
        let f = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true)
        guard f.count == 7, let pid = Int32(f[0]), let ppid = Int32(f[1]), UInt32(f[2]) == uid, let rss = Int(f[3]) else { return nil }
        let t = f[4].replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard t.count == 2, let m = Double(t[0]), let s = Double(t[1]) else { return nil }
        return Row(pid: pid, ppid: ppid, rssKB: rss, seconds: m * 60 + s, slow: (Int(f[5]) ?? 99) <= 4, path: String(f[6]))
    }
}

private func topHogs(_ a: [Row], _ b: [Row], _ span: Double) -> [Hog] {
    let before = Dictionary(b.compactMap { r in a.first { $0.pid == r.pid }.map { (r.pid, $0.seconds) } }, uniquingKeysWith: { x, _ in x })
    var mine: Set<Int32> = [getpid()], grew = true
    while grew {
        grew = false
        for r in b where !mine.contains(r.pid) && mine.contains(r.ppid) { mine.insert(r.pid); grew = true }
    }
    var groups: [String: (name: String, ramKB: Int, cpu: Double, slow: Bool)] = [:]
    for r in b where !mine.contains(r.pid) {
        let parts = r.path.split(separator: "/", omittingEmptySubsequences: true)
        let app = parts.firstIndex { $0.hasSuffix(".app") }
        let key = app.map { "/" + parts[...$0].joined(separator: "/") } ?? r.path
        let name = app.map { String(parts[$0].dropLast(4)) } ?? (r.path as NSString).lastPathComponent
        let cpu = before[r.pid].map { max(0, r.seconds - $0) / max(span, 0.1) * 100 } ?? 0
        var g = groups[key] ?? (name, 0, 0, false)
        g.ramKB += r.rssKB
        g.cpu += cpu
        g.slow = g.slow || r.slow
        groups[key] = g
    }
    return groups.map { Hog(id: $0.key, name: $0.value.name, ramMB: $0.value.ramKB / 1024, cpu: $0.value.cpu, slow: $0.value.slow) }
        .sorted(by: Hog.ranked)
        .prefix(12).map { $0 }
}

struct OpenApp: Identifiable {
    let id: String
    let name: String
}

@MainActor
final class LiveStats: ObservableObject {
    @Published private(set) var now = Vitals()
    @Published private(set) var history: [Double] = []
    @Published private(set) var open: [OpenApp] = []
    private var smoothed: [String: Double] = [:]

    func run() async {
        while !Task.isCancelled {
            if NSApp.occlusionState.contains(.visible) {
                var v = await Vitals.capture()
                let seen = smoothed
                smoothed = [:]
                v.hogs = v.hogs.map { h in
                    let cpu = seen[h.id].map { $0 * 0.6 + h.cpu * 0.4 } ?? h.cpu
                    smoothed[h.id] = cpu
                    return Hog(id: h.id, name: h.name, ramMB: h.ramMB, cpu: cpu, slow: h.slow)
                }.sorted(by: Hog.ranked)
                now = v
                history.append(v.freePct)
                if history.count > 45 { history.removeFirst(history.count - 45) }
                open = NSWorkspace.shared.runningApplications
                    .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
                    .compactMap { a in a.bundleURL.map { OpenApp(id: $0.path, name: a.localizedName ?? $0.deletingPathExtension().lastPathComponent) } }
            }
            try? await Task.sleep(for: .milliseconds(1400))
        }
    }
}

func gbText(_ g: Double) -> String { String(format: "%.1f GB", g).replacingOccurrences(of: ".", with: ",") }

func memText(_ bytes: Int64) -> String {
    bytes < 1_073_741_824 ? "\(bytes >> 20) MB" : gbText(Double(bytes) / 1_073_741_824)
}

struct Meter: View {
    let value: Double
    var ghost: Double?
    var tint: Color = .brandTeal
    var height: CGFloat = 10

    private func fill(_ c: some ShapeStyle, _ v: Double) -> some View {
        Capsule().fill(c).mask(alignment: .leading) { Rectangle().scaleEffect(x: max(min(v, 1), 0.0001), anchor: .leading) }
    }

    var body: some View {
        Capsule().fill(Color.primary.opacity(0.08))
            .overlay {
                ZStack {
                    if let ghost { fill(tint.opacity(0.28), ghost) }
                    fill(tint.gradient, value)
                }
            }
            .frame(height: height)
    }
}

struct Spark: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let step = size.width / 44
            let pts = values.enumerated().map { i, v in
                CGPoint(x: size.width - CGFloat(values.count - 1 - i) * step, y: size.height * (1 - min(max(v, 0), 100) / 100))
            }
            var line = Path()
            line.move(to: pts[0])
            pts.dropFirst().forEach { line.addLine(to: $0) }
            var area = line
            area.addLine(to: CGPoint(x: pts.last!.x, y: size.height))
            area.addLine(to: CGPoint(x: pts[0].x, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.28), tint.opacity(0)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            if let last = pts.last { ctx.fill(Path(ellipseIn: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)), with: .color(tint)) }
        }
    }
}

struct LiveCard: View {
    @ObservedObject var live: LiveStats

    var body: some View {
        let v = live.now
        let tint: Color = v.freePct < 20 ? .red : v.freePct < 35 ? .orange : .brandTeal
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.green)
                Text("En vivo").font(.headline)
                Spacer()
                Text("Lo mide macOS mientras miras").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(Int(v.freePct))%").font(.system(size: 44, weight: .semibold)).tracking(-1).monospacedDigit()
                    Text("de RAM libre").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Spark(values: live.history, tint: tint).frame(width: 150, height: 46)
            }
            Meter(value: v.freePct / 100, tint: tint)
            Text("Apps \(memText(v.appBytes)) · Núcleo \(memText(v.wiredBytes)) · Comprimida \(memText(v.compressedBytes))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .help("Lo que ocupa la memoria: tus apps, el núcleo de macOS, y datos poco usados que macOS aprieta para no llenar la RAM")
            HStack(spacing: 0) {
                StatChip(title: "Swap", value: gbText(v.swapGB), symbol: "arrow.left.arrow.right", tint: v.swapGB > 4 ? .orange : .brandTeal,
                         tip: "Memoria que macOS prestó del disco porque la RAM se llenó. Si sube mucho, la Mac se siente lenta")
                StatChip(title: "Procesador", value: "\(Int(v.cpuPct.rounded()))%", symbol: "cpu", tint: v.cpuPct > 80 ? .orange : .brandTeal,
                         tip: "Cuánto del procesador se usó en el último instante")
                StatChip(title: "Presión de memoria", value: v.pressureName, symbol: "gauge.with.dots.needle.33percent", tint: v.pressureColor,
                         tip: "El semáforo de macOS: Normal está bien, Alta significa que está comprimiendo o prestando memoria del disco")
            }
        }
        .padding(16)
        .card(16)
        .help("La RAM libre incluye la caché de archivos, que macOS suelta sola cuando otra app la necesita")
    }
}

struct HogsList: View {
    @ObservedObject var live: LiveStats

    var body: some View {
        let hogs = Array(live.now.hogs.prefix(5))
        let n = hogs.filter(\.bothers).count
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Lo que más pesa").font(.headline)
                Spacer()
                Label(n == 0 ? "Nada molesta ahora" : n == 1 ? "1 molesta" : "\(n) molestan",
                      systemImage: n == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.callout.weight(.medium)).foregroundStyle(n == 0 ? Color.green : .orange)
            }
            ForEach(hogs) { HogRow(hog: $0, total: live.now.totalBytes) }
            if !live.open.isEmpty {
                let flagged = Set(live.now.hogs.filter(\.bothers).map(\.id))
                HStack(spacing: 10) {
                    Text("Abiertas · \(live.open.count)").font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(live.open) { a in
                                Image(nsImage: NSWorkspace.shared.icon(forFile: a.id)).resizable().frame(width: 24, height: 24)
                                    .overlay(alignment: .topTrailing) {
                                        if flagged.contains(a.id) { Circle().fill(.orange).frame(width: 8, height: 8).offset(x: 2, y: -2) }
                                    }
                                    .help(a.name)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .scrollIndicators(.hidden)
                }
                .padding(.top, 2)
            }
        }
    }
}

private struct HogRow: View {
    let hog: Hog
    let total: Int64

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: hog.path)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(hog.name).fontWeight(.medium).lineLimit(1)
                    if hog.slow {
                        Image(systemName: "wind").font(.caption2).foregroundStyle(Color.brandTeal)
                            .help("Ya tiene prioridad baja: cede el procesador a lo que estás usando")
                    }
                }
                Text(hog.reason).font(.caption).foregroundStyle(hog.bothers ? Color.orange : .secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(memText(Int64(hog.ramMB) << 20)) · \(Int(hog.cpu.rounded()))% CPU")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Meter(value: Double(hog.ramMB << 20) / Double(max(total, 1)), tint: hog.bothers ? .orange : .brandTeal, height: 5).frame(width: 130)
            }
        }
    }
}
