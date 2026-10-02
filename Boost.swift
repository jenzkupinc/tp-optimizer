import SwiftUI
import AppKit

struct BoostStep: Identifiable {
    let id = UUID()
    let symbol: String
    let text: String
    var detail = ""
}

struct Lowered: Identifiable {
    let id: String
    let name: String
    let detail: String
}

@MainActor
final class Boost: ObservableObject {
    enum Phase { case idle, sweeping, relieving, deep, done }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var progress = 0.0
    @Published private(set) var steps: [BoostStep] = []
    @Published private(set) var before: Vitals?
    @Published private(set) var after: Vitals?
    @Published private(set) var trashed: Int64 = 0
    @Published private(set) var relieved: [String] = []
    @Published private(set) var lowered: [Lowered] = []
    @Published private(set) var heavy: Item?
    @Published private(set) var emptied: Bool?
    @Published private(set) var admin: Bool?
    @Published private(set) var quiet = Root.installed
    @Published private(set) var quietBusy = false
    @Published private(set) var quietNote = ""
    private(set) var started: Date?
    private(set) var stopped: Date?
    var running: Bool { phase != .idle && phase != .done }

    var summary: String {
        var parts: [String] = []
        if trashed > 0 { parts.append("\(formatBytes(trashed)) \(emptied == true ? "liberados" : "esperan en la Papelera").") }
        if !relieved.isEmpty { parts.append("Respiro para \(plural(relieved.count, "app", "apps")) de fondo.") }
        if admin == true { parts.append("Caché de memoria purgada y DNS renovado.") }
        if admin == false { parts.append("Sin permiso de administrador: se omitió el nivel profundo.") }
        if let s = before, let e = after {
            parts.append(abs(e.freePct - s.freePct) < 1 ? "La RAM libre se mantuvo en \(Int(e.freePct))%." : "RAM libre de \(Int(s.freePct))% a \(Int(e.freePct))%.")
            if e.freeBytes - s.freeBytes > 200_000_000 { parts.append("Memoria libre al instante: de \(memText(s.freeBytes)) a \(memText(e.freeBytes)).") }
        }
        return parts.joined(separator: " ")
    }

    func run(_ m: Monitor, admin asAdmin: Bool = false) async {
        guard !running else { return }
        let t0 = Date()
        started = t0
        stopped = nil
        steps = []
        before = nil
        after = nil
        trashed = 0
        relieved = []
        lowered = []
        heavy = nil
        emptied = nil
        admin = nil
        go(.sweeping, 0.04)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)

        note("waveform.path.ecg", "Midiendo cómo está tu Mac")
        let start = await Vitals.capture()
        before = start
        go(.sweeping, 0.1)

        let open = Set(NSWorkspace.shared.runningApplications.flatMap { [$0.bundleIdentifier, $0.localizedName].compactMap { $0?.lowercased() } })
        let junk = await Task.detached { Cleaner.find(running: open) }.value.filter(\.selected)
        let gap = min(0.3, 3.5 / Double(max(junk.count, 1)))
        for (i, j) in junk.enumerated() {
            _ = await recycle(j.urls)
            if j.urls.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) {
                trashed += j.size
                note("trash", j.title, formatBytes(j.size))
            } else {
                note("exclamationmark.triangle", "No pude mover \(j.title)")
            }
            go(.sweeping, 0.1 + 0.42 * Double(i + 1) / Double(junk.count))
            try? await Task.sleep(for: .seconds(gap))
        }
        if junk.isEmpty { note("checkmark.circle", "No había basura segura que barrer") }
        await pace(since: t0, 2.4)

        stopped = Date()
        go(.relieving, 0.56)
        await m.reload()
        let lightened = m.breathe(loose: false)
        relieved = lightened.map(\.name)
        for item in lightened {
            note("wind", "Prioridad baja · \(item.name)", memText(Int64(item.ramMB) << 20))
            try? await Task.sleep(for: .seconds(0.25))
        }
        if lightened.isEmpty { note("checkmark.circle", "Nada pesado en segundo plano") }
        go(.relieving, 0.7)

        if asAdmin {
            go(.deep, 0.74)
            var ok = await Task.detached { Root.runQuiet(["deep"]) }.value
            if ok {
                note("lock.open", "Con tu acceso guardado, sin contraseña")
            } else {
                note("lock.shield", "Pidiendo tu contraseña, solo esta vez")
                try? await Task.sleep(for: .seconds(0.4))
                ok = await Task.detached { Root.run(["deep"]) }.value
                if ok {
                    quiet = Root.installed
                    quietNote = quiet ? "Acceso de administrador guardado: ningún panel vuelve a pedir contraseña." : "No pude guardar el acceso: la próxima vez pedirá contraseña otra vez."
                    note(quiet ? "key.fill" : "exclamationmark.triangle", quiet ? "Acceso guardado, no volverá a pedirla" : "El acceso no quedó guardado")
                    record(quiet ? "Guardé el acceso de administrador para TP Optimizer" : "No se pudo guardar el acceso de administrador")
                }
            }
            admin = ok
            if ok {
                note("memorychip", "Caché de memoria purgada")
                note("network", "Caché de DNS renovada")
            } else {
                note("lock.slash", "Sin permiso: se omitió el nivel profundo")
            }
            go(.deep, 0.84)
        }

        try? await Task.sleep(for: .seconds(1.2))
        note("waveform.path.ecg", "Midiendo de nuevo")
        go(phase, 0.92)
        let end = await Vitals.capture()
        after = end
        lowered = start.hogs.compactMap { h in
            guard relieved.contains(h.name), let n = end.hogs.first(where: { $0.id == h.id }) else { return nil }
            var parts: [String] = []
            if h.cpu - n.cpu >= 10 { parts.append("CPU \(Int(h.cpu.rounded()))% → \(Int(n.cpu.rounded()))%") }
            if h.ramMB - n.ramMB >= 100 { parts.append("RAM \(memText(Int64(h.ramMB) << 20)) → \(memText(Int64(n.ramMB) << 20))") }
            return parts.isEmpty ? nil : Lowered(id: h.id, name: h.name, detail: parts.joined(separator: " · "))
        }
        if end.freePct < 30 || end.swapGB > 4 || end.pressure > 1 {
            heavy = m.items.filter { $0.kind == .open && !$0.protected && !NightMode.keep.contains($0.name) && $0.app?.isActive != true && $0.ramMB >= 1200 }
                .max { $0.ramMB < $1.ramMB }
        }

        go(.done, 1)
        record("Boost: " + (trashed > 0 ? "\(formatBytes(trashed)) a la Papelera, " : "") + "RAM libre \(Int(start.freePct))% → \(Int(end.freePct))%"
               + (relieved.isEmpty ? "" : ", prioridad baja a \(plural(relieved.count, "app", "apps"))") + (admin == true ? ", nivel profundo" : ""))
        let sound = NSSound(named: "Glass")
        sound?.volume = 0.35
        sound?.play()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    func revokeQuiet() async {
        guard !quietBusy, !running else { return }
        quietBusy = true
        defer { quietBusy = false }
        if await Task.detached(operation: { Root.revoke() }).value {
            quiet = false
            quietNote = "Acceso quitado: los paneles vuelven a pedir contraseña."
            record("Quité el acceso de administrador guardado")
        }
    }

    func undoRespite(_ m: Monitor) {
        m.restoreAll()
        relieved = []
    }

    func closeHeavy(_ m: Monitor) {
        guard let h = heavy else { return }
        m.close([h.id], force: false)
        heavy = nil
    }

    func emptyBin() {
        emptied = emptyTrash()
        if emptied == true { record("Vacié la Papelera después del Boost") }
    }

    private func go(_ p: Phase, _ v: Double) {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { phase = p; progress = v }
    }

    private func note(_ symbol: String, _ text: String, _ detail: String = "") {
        withAnimation(.smooth(duration: 0.3)) { steps.append(BoostStep(symbol: symbol, text: text, detail: detail)) }
    }

    private func pace(since t: Date, _ seconds: Double) async {
        let rest = seconds - Date().timeIntervalSince(t)
        if rest > 0 { try? await Task.sleep(for: .seconds(rest)) }
    }
}

struct BoostPane: View {
    @ObservedObject var b: Boost
    @ObservedObject var m: Monitor
    @ObservedObject var live: LiveStats
    @State private var confirmEmpty = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header(title: "Boost", subtitle: "Un toque barre la basura que se regenera sola y le quita peso al fondo. Al lado ves cómo está tu Mac en vivo y qué cambió.")
            HStack(alignment: .top, spacing: 26) {
                VStack(spacing: 14) {
                    BoostDial(b: b) { Task { await b.run(m) } }
                    VStack(spacing: 5) {
                        Text(headline).font(.system(.title2, weight: .semibold)).tracking(-0.4)
                        Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3, reservesSpace: true)
                    }
                    .id(b.phase)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                    Button { Task { await b.run(m, admin: true) } } label: { Label("Boost profundo", systemImage: "lock.shield") }
                        .disabled(b.running)
                        .help("Hace el Boost y además purga la caché de memoria y renueva la de DNS. La primera vez pide tu contraseña y guarda un ayudante con una lista corta de tareas (este Boost, firewall, sitios bloqueados, arranque y horario); después no vuelve a pedirla. macOS reconstruye esas cachés sola. El porcentaje de RAM libre ya cuenta esa caché, por eso no se mueve; la fila «Libre al instante» muestra lo que sí cambia")
                    Text(b.quietNote.isEmpty ? "Tus apps siguen abiertas y nada se borra para siempre." : b.quietNote)
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2, reservesSpace: true)
                    if b.quiet {
                        Button("Quitar el acceso guardado") { Task { await b.revokeQuiet() } }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(Color.brandTeal).disabled(b.running || b.quietBusy)
                            .help("Borra el ayudante y su permiso. Firewall, sitios bloqueados, arranque, horario y Boost profundo vuelven a pedir contraseña")
                    }
                }
                .frame(width: 330)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        LiveCard(live: live)
                        activity
                        HogsList(live: live)
                    }
                    .padding(.horizontal, 2).padding(.bottom, 6)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding()
        .task { await live.run() }
        .confirmationDialog("Vaciar la Papelera borra para siempre todo lo que tiene dentro, también lo que ya estaba antes del Boost.", isPresented: $confirmEmpty) {
            Button("Vaciar", role: .destructive) { b.emptyBin() }
        }
    }

    private var acted: Bool { b.trashed > 0 || !b.relieved.isEmpty || b.admin == true }

    private var headline: String {
        switch b.phase {
        case .idle: "Listo cuando tú digas"
        case .sweeping: "Barriendo…"
        case .relieving: "Aliviando el fondo…"
        case .deep: "Nivel administrador…"
        case .done: acted ? "Listo. Esto fue lo que cambió" : "Tu Mac ya estaba en orden"
        }
    }

    private var detail: String {
        switch b.phase {
        case .idle: "Tarda unos segundos, y todo lo que hace se puede deshacer."
        case .sweeping: "Cachés de apps cerradas, logs viejos y restos de compilaciones, directo a la Papelera."
        case .relieving: "Las apps pesadas que no estás mirando le ceden el procesador a lo que usas. Tus bots siguen igual."
        case .deep: b.quiet ? "Con tu acceso guardado purga la caché de memoria y renueva la de DNS." : "Escribe tu contraseña una sola vez. Con ella purga la caché de memoria y renueva la de DNS, y la próxima ya no la pide."
        case .done: b.summary.isEmpty ? "No encontré basura segura ni procesos pesados de fondo." : b.summary
        }
    }

    @ViewBuilder private var activity: some View {
        switch b.phase {
        case .idle:
            VStack(alignment: .leading, spacing: 12) {
                Promise(symbol: "sparkles", title: "Barre", text: "Cachés de apps cerradas, npm, Bun, Xcode y logs de más de 14 días. Todo pasa por la Papelera.")
                Promise(symbol: "wind", title: "Alivia", text: "Las apps pesadas de fondo bajan de prioridad. Tus bots y scripts no se tocan.")
                Promise(symbol: "waveform.path.ecg", title: "Mide", text: "Compara antes y después con los números de macOS. Si algo no cambió, te lo dice.")
                Promise(symbol: "lock.shield", title: "Profundo", text: "Purga la caché de memoria y renueva el DNS. Pide tu contraseña solo la primera vez. El porcentaje no se mueve porque ya cuenta esa caché; la fila «Libre al instante» muestra la memoria que queda lista.")
            }
            .transition(.opacity)
        case .done:
            results.transition(.opacity.combined(with: .offset(y: -8)))
        default:
            VStack(alignment: .leading, spacing: 10) {
                Text("Haciendo ahora").font(.headline)
                Feed(steps: Array(b.steps.suffix(7)))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(16)
            .transition(.opacity)
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let s = b.before, let e = b.after {
                HStack {
                    Text("Antes y después").font(.headline)
                    Spacer()
                    Text("Medido por macOS. RAM y procesador también cambian solos").font(.caption).foregroundStyle(.secondary)
                }
                Compare(title: "RAM libre", symbol: "memorychip", before: s.freePct, after: e.freePct, cap: 100, eps: 1, higherIsBetter: true) { "\(Int($0.rounded()))%" }
                Compare(title: "Libre al instante", symbol: "bolt.horizontal", before: Double(s.freeBytes), after: Double(e.freeBytes), cap: Double(max(e.totalBytes, 1)),
                        eps: 200_000_000, higherIsBetter: true) { memText(Int64($0)) }
                Compare(title: "Memoria en uso", symbol: "square.stack.3d.up", before: Double(s.usedBytes), after: Double(e.usedBytes), cap: Double(max(e.totalBytes, 1)),
                        eps: 50_000_000, higherIsBetter: false) { memText(Int64($0)) }
                Compare(title: "Swap", symbol: "arrow.left.arrow.right", before: s.swapGB, after: e.swapGB, cap: max(8, s.swapGB, e.swapGB), eps: 0.05,
                        higherIsBetter: false, text: gbText)
                Compare(title: "Procesador", symbol: "cpu", before: s.cpuPct, after: e.cpuPct, cap: 100, eps: 3, higherIsBetter: false) { "\(Int($0.rounded()))%" }
                HStack(spacing: 6) {
                    Image(systemName: "gauge.with.dots.needle.33percent").foregroundStyle(Color.brandTeal).frame(width: 18)
                    Text("Presión de memoria").font(.callout.weight(.medium))
                    Spacer()
                    Text(s.pressureName).foregroundStyle(s.pressureColor)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                    Text(e.pressureName).foregroundStyle(e.pressureColor)
                }
                .font(.callout.weight(.semibold))
                Divider()
            }
            if b.lowered.isEmpty {
                Label(b.relieved.isEmpty ? "No había apps pesadas de fondo que aliviar" : "Las apps aliviadas no cambiaron de forma notable en esta medición",
                      systemImage: "equal.circle").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Apps aliviadas que bajaron").font(.subheadline.weight(.semibold))
                ForEach(b.lowered) { d in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: d.id)).resizable().frame(width: 22, height: 22)
                        Text(d.name).fontWeight(.medium)
                        Spacer()
                        Text(d.detail).font(.callout.monospacedDigit()).foregroundStyle(.green)
                    }
                }
            }
            Feed(steps: b.steps)
            HStack(spacing: 8) {
                if let h = b.heavy {
                    Button("Cerrar \(h.name) · \(memText(Int64(h.ramMB) << 20))") { b.closeHeavy(m) }
                        .help("Es la app abierta que más memoria ocupa. Se cierra como con Salir, así que te avisa si hay algo sin guardar")
                }
                Spacer()
                if !b.relieved.isEmpty { Button("Quitar respiro") { b.undoRespite(m) }.help("Devuelve todo a su prioridad normal ahora mismo") }
                if b.trashed > 0 && b.emptied != true {
                    Button("Vaciar Papelera") { confirmEmpty = true }.buttonStyle(PrimaryButton()).help("Libera el espacio de verdad. Te pide confirmar")
                }
            }
        }
        .padding(16)
        .card(16)
    }
}

private struct Promise: View {
    let symbol: String, title: String, text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Color.brandTeal).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Feed: View {
    let steps: [BoostStep]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(steps) { s in
                HStack(spacing: 8) {
                    Image(systemName: s.symbol).font(.caption).foregroundStyle(Color.brandTeal).frame(width: 16)
                    Text(s.text).font(.caption).lineLimit(1)
                    Spacer(minLength: 8)
                    if !s.detail.isEmpty { Text(s.detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
        }
    }
}

private struct Compare: View {
    let title: String, symbol: String
    let before: Double, after: Double, cap: Double, eps: Double
    let higherIsBetter: Bool
    let text: (Double) -> String

    var body: some View {
        let d = after - before
        let moved = abs(d) >= eps
        let good = higherIsBetter ? d > 0 : d < 0
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(Color.brandTeal).frame(width: 18)
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Text("\(text(before)) → \(text(after))").font(.callout.monospacedDigit())
                Text(moved ? (d > 0 ? "+" : "−") + text(abs(d)) : "Igual")
                    .font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(!moved ? Color.secondary : good ? .green : .orange)
                    .frame(width: 74, alignment: .trailing)
            }
            Meter(value: after / cap, ghost: before / cap, tint: !moved ? Color.brandTeal : good ? .green : .orange, height: 6)
        }
    }
}
