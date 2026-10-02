import SwiftUI

struct LabArm {
    private(set) var values: [Double] = []
    private(set) var lost = 0

    mutating func add(_ v: Double?) {
        if let v { values.append(v) } else { lost += 1 }
    }

    var n: Int { values.count }
    var p50: Double { Series.percentile(values, 0.5) }
    var p99: Double { Series.percentile(values, 0.99) }
    var peak: Double { values.max() ?? 0 }
    var spikes: Int { values.filter { $0 > 20 }.count }
    var lossPct: Double { n + lost > 0 ? Double(lost) / Double(n + lost) * 100 : 0 }
}

enum LabVerdict { case better, worse, same, thin }

enum Lab {
    nonisolated static let minSamples = 1000

    nonisolated static func judge(normal: LabArm, off: LabArm) -> LabVerdict {
        guard normal.n >= minSamples, off.n >= minSamples else { return .thin }
        let gain = normal.p99 - off.p99
        let better = gain >= max(1, 0.2 * normal.p99) || (normal.spikes >= 5 && Double(off.spikes) <= 0.5 * Double(normal.spikes))
        let worse = -gain >= max(1, 0.2 * off.p99) || (off.spikes >= 5 && Double(normal.spikes) <= 0.5 * Double(off.spikes))
        return better == worse ? .same : better ? .better : .worse
    }
}

struct PastSession: Codable, Identifiable {
    var id = UUID()
    let start: Date
    let seconds: Double
    let avg: Double
    let peak: Double
    let lost: Int
    let spikes: Int
    let playing: Bool
    let airdropOff: Bool
    var channel: String? = nil
    var jitter: Double? = nil
    var lossPct: Double? = nil
}

struct ChannelStat: Identifiable {
    let channel: String
    let sessions: Int
    let jitter: Double
    let spikesPerHour: Double
    let lossPct: Double
    var id: String { channel }
}

extension GameLink {
    nonisolated static func channelNumber(_ text: String) -> String? {
        text.split(separator: " ").first.flatMap { Int($0) }.map(String.init)
    }

    nonisolated static func byChannel(_ history: [PastSession]) -> [ChannelStat] {
        let tagged = history.filter { $0.channel != nil && $0.jitter != nil && $0.seconds > 0 }
        return Dictionary(grouping: tagged, by: { $0.channel ?? "" }).map { channel, list in
            let hours = list.reduce(0) { $0 + $1.seconds } / 3600
            let weight = list.reduce(0) { $0 + $1.seconds }
            return ChannelStat(channel: channel, sessions: list.count,
                               jitter: list.reduce(0) { $0 + ($1.jitter ?? 0) * $1.seconds } / weight,
                               spikesPerHour: Double(list.reduce(0) { $0 + $1.spikes }) / max(hours, 1.0 / 3600),
                               lossPct: list.reduce(0) { $0 + ($1.lossPct ?? 0) * $1.seconds } / weight)
        }.sorted { $0.jitter < $1.jitter }
    }
}

struct GameChannelCard: View {
    let history: [PastSession]

    var body: some View {
        let stats = GameLink.byChannel(history)
        if !stats.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Qué canal te va mejor").font(.headline)
                ForEach(stats) { s in
                    HStack(spacing: 10) {
                        Text("Canal \(s.channel)").fontWeight(.medium).frame(width: 84, alignment: .leading)
                        Text(plural(s.sessions, "sesión", "sesiones")).frame(width: 84, alignment: .leading).foregroundStyle(.secondary)
                        Text("jitter \(ms(s.jitter)) ms · \(ms(s.spikesPerHour)) saltos por hora · \(ms(s.lossPct))% de pérdida").foregroundStyle(.secondary).lineLimit(1)
                    }
                    .font(.callout.monospacedDigit())
                }
                Text(stats.contains { $0.sessions < 3 } ? "Con menos de 3 sesiones por canal no hay base para decidir. Cambia el canal en Compartir Internet, juega unas partidas y vuelve a mirar." : "Promedios ponderados por la duración de cada sesión. Cambiar de canal se hace en Compartir Internet.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }
}

struct PlanItem: Identifiable {
    let id: String
    let title: String
    let step: String
    let symbol: String
}

struct PlayStep: Identifiable {
    enum State { case waiting, running, done, skipped }
    let id: String
    let title: String
    var detail = ""
    var state = State.waiting
}

enum BackupOutcome { case idle, stopped, failed }

struct AirSettings: Equatable {
    enum State { case off, on, unknown }
    var airdrop: State
    var handoff: State

    nonisolated static func parseAirDrop(_ raw: String) -> State {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "Off": .off
        case "Contacts Only", "Everyone": .on
        default: .unknown
        }
    }

    nonisolated static func parseFlag(_ raw: String) -> State {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "0": .off
        case "1": .on
        default: .unknown
        }
    }

    nonisolated static func combine(advertising: State, receiving: State) -> State {
        if advertising == .on || receiving == .on { return .on }
        if advertising == .off && receiving == .off { return .off }
        return .unknown
    }

    nonisolated static func read() -> AirSettings {
        AirSettings(airdrop: parseAirDrop(shell("defaults read com.apple.sharingd DiscoverableMode 2>/dev/null")),
                    handoff: combine(advertising: parseFlag(shell("defaults read com.apple.coreservices.useractivityd ActivityAdvertisingAllowed 2>/dev/null")),
                                     receiving: parseFlag(shell("defaults read com.apple.coreservices.useractivityd ActivityReceivingAllowed 2>/dev/null"))))
    }
}

extension GameLink {
    nonisolated static func backupRunning(_ status: String) -> Bool { status.contains("Running = 1") }

    nonisolated static func stopBackupIfRunning() -> BackupOutcome {
        guard backupRunning(shell("/usr/bin/tmutil status 2>/dev/null")) else { return .idle }
        return shellStatus("/usr/bin/tmutil stopbackup >/dev/null 2>&1") == 0 ? .stopped : .failed
    }
}

struct PlayChecklist: View {
    let steps: [PlayStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(steps) { s in
                HStack(alignment: .top, spacing: 8) {
                    Group {
                        switch s.state {
                        case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
                        case .running: ProgressView().controlSize(.mini)
                        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(s.title).font(.callout)
                        if !s.detail.isEmpty { Text(s.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
            }
        }
    }
}

struct TweakRow: View {
    let symbol: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(isOn ? Color.brandTeal : .secondary).padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

struct GameTweaksCard: View {
    @ObservedObject var g: GameLink
    @ObservedObject var m: Monitor
    @State private var helperReady: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Qué se activa al jugar").font(.headline)
            group("Tu iPad") {
                TweakRow(symbol: "ipad", title: "Mantener el iPad despierto", detail: "Evita los picos de cientos de ms que se ven cuando el iPad está en reposo.", isOn: $g.keepAwake)
                    .help("La Mac le manda 20 paquetes diminutos por segundo al iPad para que no duerma su Wi-Fi entre mensajes")
                TweakRow(symbol: "scope", title: "Detectar el servidor del juego", detail: "Mientras juegas, busca a qué IP manda datos el iPad.", isOn: $g.autoServer)
                    .help("Durante una sesión, escucha 5 segundos cada 25 y actualiza la lista sin que hagas nada. No pide contraseña: si el ayudante no está listo, no lo intenta")
            }
            Divider()
            group("Tu Mac") {
                TweakRow(symbol: "gauge.with.dots.needle.33percent", title: "Bajar la prioridad de lo pesado", detail: "Lo que gasta CPU o disco de fondo pasa a segundo plano.", isOn: $g.lowerPriority)
                    .help("No cierra nada. Al terminar el modo juego todo vuelve a su prioridad")
                TweakRow(symbol: "moon.zzz", title: "Dormir las apps que usan la red", detail: "Se congelan sin cerrarse y despiertan al terminar.", isOn: $g.autoSilence)
                    .help("Durante la sesión congela las apps abiertas que usan la red, para que no le quiten línea al iPad. Nunca toca las apps protegidas ni las de tu lista de siempre")
                if !g.silenced.isEmpty {
                    HStack(spacing: 8) {
                        Text("Dormidas ahora: \(g.silenced.count == 1 ? "1 proceso" : "\(g.silenced.count) procesos")").font(.caption).foregroundStyle(Color.brandTeal)
                        Button("Despertar todo") { g.resumeSilenced(m) }.controlSize(.small)
                    }
                    .padding(.leading, 34)
                }
                TweakRow(symbol: "externaldrive", title: "Pausar la copia de Time Machine", detail: "Si hay una copia en curso al empezar, se detiene; vuelve sola.", isOn: $g.pauseBackup)
                    .help("Solo actúa si Time Machine está copiando justo al empezar. No borra nada: la copia se reanuda en su próximo horario")
                TweakRow(symbol: "antenna.radiowaves.left.and.right.slash", title: "Apagar AirDrop y Handoff", detail: "Evita que la radio de la Mac salte de canal. Vuelven al terminar.", isOn: $g.awdlDuringGame)
                    .help("AirDrop, Handoff, Sidecar y Universal Control usan una interfaz que hace saltar la radio de la Mac a otro canal. Se enciende sola al terminar el modo juego o cerrar la app. Pruébalo en el Laboratorio de la pestaña Red antes de dejarlo fijo")
                airdropLine.padding(.leading, 34)
            }
            Divider()
            group("Tu Wi-Fi") {
                TweakRow(symbol: "person.2.slash", title: "Limitar a los demás equipos", detail: "El iPhone, el reloj y otros quedan con tope. El iPad nunca.", isOn: $g.exclusive)
                    .help("Mientras juegas, los demás equipos del Wi-Fi compartido quedan limitados a la velocidad que elijas. Se quita solo al terminar o cerrar la app")
                if g.exclusive {
                    Picker("Límite a los demás", selection: $g.exclusiveMbit) {
                        Text("5").tag(5)
                        Text("10").tag(10)
                        Text("20").tag(20)
                        Text("50").tag(50)
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 260).padding(.leading, 34)
                    .help("Mbit/s que puede usar cada conjunto de otros equipos. 20 alcanza para navegar; 5 casi los congela")
                    if !g.limitNote.isEmpty { Text(g.limitNote).font(.caption).foregroundStyle(g.limited.isEmpty ? Color.secondary : Color.brandTeal).lineLimit(3).padding(.leading, 34) }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(16)
        .task { helperReady = await Task.detached { Root.ready() }.value }
        .onChange(of: g.awdlHeld) { _, _ in Task { helperReady = await Task.detached { Root.ready() }.value } }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
            content()
        }
    }

    @ViewBuilder private var airdropLine: some View {
        if g.awdlHeld {
            Label("AirDrop apagado ahora" + (g.awdlRetakes > 0 ? ". macOS lo volvió a encender \(plural(g.awdlRetakes, "vez", "veces")) y la app lo apagó otra vez" : ""), systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(Color.brandTeal).lineLimit(3)
        }
        if g.awdlDuringGame || g.awdlHeld {
            Text("Mientras esté apagado no funcionan AirDrop, Handoff, Universal Control ni Sidecar.").font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        if helperReady == false {
            Text("La primera vez te pide la contraseña, una sola vez, para actualizar el ayudante.").font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

struct GameTargetCard: View {
    @ObservedObject var g: GameLink
    @State private var custom = ""
    @State private var rejected = false
    private let presets = [("Cloudflare", "1.1.1.1"), ("Google", "8.8.8.8"), ("Quad9", "9.9.9.9")]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Destino del ping").font(.headline)
            HStack(spacing: 6) {
                ForEach(presets, id: \.1) { p in
                    Button(p.0) { _ = g.useTarget(p.1) }
                        .buttonStyle(.bordered)
                        .tint(g.destino == p.1 ? Color.brandTeal : nil)
                        .help("Mide el tramo hacia internet contra \(p.1)")
                }
            }
            HStack(spacing: 6) {
                TextField("Servidor de tu juego (nombre o IP)", text: $custom)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(apply)
                Button("Usar", action: apply).disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Mide contra ese servidor en vez de los de arriba")
            }
            Text(rejected ? "Escribe solo un nombre o una IP, sin espacios ni símbolos." : "Midiendo contra \(g.destino). Si ese servidor no responde ping verás pérdida total: vuelve a uno de los de arriba.")
                .font(.caption).foregroundStyle(rejected ? .orange : .secondary).lineLimit(3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(16)
    }

    private func apply() {
        rejected = !g.useTarget(custom)
        if !rejected { custom = "" }
    }
}

struct GameIdeasCard: View {
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 14) {
                section("Lo que más pesa: el Wi-Fi del iPad", [
                    ("iPad por cable", "Un adaptador USB-C a Ethernet quita el salto Wi-Fi, que es donde el iPad ahorra energía y mete picos. Apple lista los adaptadores USB-Ethernet entre lo que acepta el iPad. Falta probar aquí que Compartir Internet reparta por un segundo puerto Ethernet.", ("Apple: dispositivos USB del iPad", "https://support.apple.com/en-us/108894")),
                ])
                section("En el iPad, una sola vez", [
                    ("Sin AirDrop, Handoff ni AirPlay en la partida", "Son los que hacen saltar la radio de canal (AWDL). La app ya lo apaga en la Mac; en el iPad lo haces tú.", ("USENIX Security 2019: AWDL", "https://www.usenix.org/system/files/sec19-stute.pdf")),
                    ("iPad fresco", "Sin funda y con soporte. Con calor el iPad baja su rendimiento.", ("Apple: temperaturas del iPad", "https://support.apple.com/en-us/HT201678")),
                    ("Dirección Wi-Fi privada", "Apple dice que puede cambiar. Si cambia, esta app ve un equipo nuevo y te avisa.", ("Apple: dirección Wi-Fi privada", "https://support.apple.com/en-us/102509")),
                ])
                section("Lo que buscamos y no sirve", [
                    ("Modo de bajo consumo, datos bajos, Retransmisión privada", "Apple no documenta efecto en la latencia de juego.", nil),
                    ("Modo juego de Apple", "Prioriza CPU, GPU y Bluetooth. No menciona el Wi-Fi.", ("Apple: Modo juego", "https://support.apple.com/en-us/105118")),
                    ("Priorizar el juego por IP desde la Mac", "Con WireGuard la Mac solo ve UDP hacia tu VM: las IP del juego van dentro del túnel y no se pueden clasificar. Además pf no puede marcar DSCP en macOS. Esa prioridad vive en la VM (pubg_prio con DSCP EF); la pestaña Túnel mide cuánto tráfico cubre.", nil),
                    ("Tocar las colas de la Mac o el ancho de canal", "Sin evidencia de mejora. dnctl solo trae colas con pesos, sin CoDel, y la Mac ya usa FQ_CODEL en sus interfaces; se vio con netstat -qq.", nil),
                    ("Abrir puertos para PUBG Mobile", "El juego sale como cliente. Las listas de puertos que circulan vienen de un foro sin verificar.", nil),
                    ("Aceleradores tipo ExitLag", "No hallamos un estudio independiente. El FEC cambia ancho de banda por menos pérdida, no baja el ping base.", nil),
                ])
                Text("Investigado el 1 de octubre de 2026 con fuentes abiertas. Lo que no se pudo comprobar aquí está dicho en cada línea.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 10)
        } label: {
            Text("Ideas y lo que no sirve").font(.headline)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(16)
    }

    private func section(_ title: String, _ items: [(String, String, (String, String)?)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
            ForEach(items.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 1) {
                    Text(items[i].0).font(.callout.weight(.medium))
                    Text(items[i].1).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let link = items[i].2, let url = URL(string: link.1) {
                        Link(link.0, destination: url).font(.caption)
                    }
                }
            }
        }
    }
}

struct GameLabCard: View {
    @ObservedObject var g: GameLink
    private var ready: Bool { g.ipad == .awake && g.keepAwake }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Laboratorio").font(.headline)
            Text("¿Te sirve apagar AirDrop? Mide al iPad en 4 tramos de \(Int(g.labSeconds)) segundos, alternando AirDrop normal y apagado, y compara. Dura \(Int(g.labSeconds) * 4 / 60) minutos. No toques el iPad ni bajes nada grande.")
                .font(.callout).foregroundStyle(.secondary).lineLimit(4)
            if g.labRunning {
                let total = g.labSeconds * 4
                let done = Double(g.labPhase - 1) * g.labSeconds + (g.labSeconds - Double(g.labLeft))
                Text("Tramo \(g.labPhase) de 4 · AirDrop \(g.labPhase % 2 == 0 ? "apagado" : "normal") · faltan \(g.labLeft) s").font(.callout.weight(.medium)).monospacedDigit()
                Meter(value: done / total, tint: Color.brandTeal, height: 6)
                Button("Cancelar", action: g.cancelLab).help("Para la prueba y deja AirDrop como estaba")
            } else {
                Button { g.startLab() } label: { Label("Empezar prueba", systemImage: "flask") }
                    .disabled(!ready)
                    .help("Alterna AirDrop normal y apagado y compara el ping del iPad. La primera vez te pide la contraseña para actualizar el ayudante")
                if !ready { Text("Necesita al iPad despierto: enciende su pantalla y espera a que la app lo mida.").font(.caption).foregroundStyle(.secondary) }
            }
            if g.labNormal.n + g.labOff.n > 0 { results }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(16)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow { Text(""); Text("Normal").bold(); Text("Apagado").bold() }
                row("Muestras", "\(g.labNormal.n)", "\(g.labOff.n)")
                row("Mediana", "\(ms(g.labNormal.p50)) ms", "\(ms(g.labOff.p50)) ms")
                row("p99", "\(ms(g.labNormal.p99)) ms", "\(ms(g.labOff.p99)) ms")
                row("Pico", "\(ms(g.labNormal.peak)) ms", "\(ms(g.labOff.peak)) ms")
                row("Saltos de más de 20 ms", "\(g.labNormal.spikes)", "\(g.labOff.spikes)")
                row("Pérdida", "\(ms(g.labNormal.lossPct))%", "\(ms(g.labOff.lossPct))%")
            }
            .font(.caption.monospacedDigit())
            if let v = g.labVerdict {
                Text(text(v)).font(.callout.weight(.medium)).foregroundStyle(color(v)).lineLimit(3)
                Text("Criterio simple de la app: mejora si el p99 baja al menos 1 ms y 20%, o si los saltos se reducen a la mitad (con 5 o más). Otra tanda puede dar otro resultado.")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }

    @ViewBuilder private func row(_ title: String, _ a: String, _ b: String) -> some View {
        GridRow { Text(title).foregroundStyle(.secondary).gridColumnAlignment(.leading); Text(a); Text(b) }
    }

    private func text(_ v: LabVerdict) -> String {
        switch v {
        case .better: "Apagar AirDrop mejoró la medición. Activa «Apagar AirDrop y Handoff mientras juegas»."
        case .worse: "Apagar AirDrop empeoró la medición. Déjalo normal."
        case .same: "Sin diferencia medible en esta prueba. No lo apagues por el ping."
        case .thin: "Muy pocas muestras para concluir. Repite la prueba con el iPad despierto todo el rato."
        }
    }

    private func color(_ v: LabVerdict) -> Color {
        switch v {
        case .better: .green
        case .worse: .red
        case .same, .thin: .secondary
        }
    }
}

struct GameHistoryCard: View {
    let history: [PastSession]

    var body: some View {
        if !history.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Últimas sesiones").font(.headline)
                ForEach(history.prefix(5)) { h in
                    HStack(spacing: 10) {
                        Text(h.start.formatted(date: .abbreviated, time: .shortened)).frame(width: 128, alignment: .leading)
                        Text(elapsedText(h.seconds)).monospacedDigit().frame(width: 60, alignment: .leading)
                        Text("\(ms(h.avg)) ms de promedio · pico \(ms(h.peak)) ms · \(plural(h.lost, "pérdida", "pérdidas")) · \(plural(h.spikes, "salto", "saltos"))")
                            .foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text(h.playing ? "en juego" : "en reposo").font(.caption).foregroundStyle(.secondary)
                        if h.airdropOff { Text("AirDrop apagado").font(.caption).foregroundStyle(Color.brandTeal) }
                    }
                    .font(.callout)
                }
            }
        }
    }
}

struct GameCheck: Identifiable {
    enum Level { case good, warn, bad, info }
    let id: String
    let level: Level
    let title: String
    let detail: String
}

enum GameChecks {
    nonisolated static func build(sharing: Bool, hasPeer: Bool, ipad: IPadState, keepAwake: Bool, channel: String, uplink: String, awdlHeld: Bool, awdlActive: Bool, rhythmic: Bool, mbit: Double, spikes: Int, lossPct: Double, hasLocal: Bool, loadedMs: Double?, others: Int = 0, exclusive: Bool = false, limited: Int = 0, limitMbit: Int = 20, juegoPID: Int? = nil, awdlDuringGame: Bool = false, air: AirSettings? = nil) -> [GameCheck] {
        var out: [GameCheck] = []
        out.append(sharing
            ? GameCheck(id: "share", level: .good, title: "Compartir Internet activo", detail: "La Mac le da internet al iPad.")
            : GameCheck(id: "share", level: .bad, title: "Compartir Internet apagado", detail: "Enciéndelo en Ajustes del Sistema → General → Compartir."))
        if !hasPeer {
            out.append(GameCheck(id: "ipad", level: .warn, title: "No hay un iPad conectado", detail: "Conéctalo al Wi-Fi de la Mac."))
        } else if !keepAwake {
            out.append(GameCheck(id: "ipad", level: .warn, title: "El iPad puede dormirse", detail: "Sin «Mantener el iPad despierto» el Wi-Fi del iPad duerme entre mensajes y verás saltos de cientos de milisegundos."))
        } else if ipad == .awake {
            out.append(GameCheck(id: "ipad", level: .good, title: "iPad despierto y midiéndose", detail: "La Mac le manda 20 paquetes por segundo para que su Wi-Fi no duerma."))
        } else if ipad == .waiting {
            out.append(GameCheck(id: "ipad", level: .info, title: "Despertando al iPad", detail: "Si tarda, enciende su pantalla."))
        } else {
            out.append(GameCheck(id: "ipad", level: .warn, title: "El iPad no responde", detail: "Está dormido o salió del Wi-Fi."))
        }
        if channel.isEmpty {
            out.append(GameCheck(id: "band", level: .info, title: "Canal sin leer", detail: "Todavía no se pudo leer el canal del Wi-Fi compartido."))
        } else if channel.contains("2GHz") || channel.contains("2.4") {
            out.append(GameCheck(id: "band", level: .bad, title: "Wi-Fi en 2,4 GHz", detail: "Hay más interferencia y más latencia. Cambia a 5 GHz en Compartir Internet → Wi-Fi → Opciones."))
        } else {
            out.append(GameCheck(id: "band", level: .good, title: "Wi-Fi en 5 GHz", detail: "Canal \(channel)."))
        }
        if uplink.isEmpty {
            out.append(GameCheck(id: "uplink", level: .info, title: "Salida de la Mac sin leer", detail: "No se pudo saber por dónde sale la Mac a internet."))
        } else if uplink.localizedCaseInsensitiveContains("wi-fi") {
            out.append(GameCheck(id: "uplink", level: .warn, title: "La Mac sale a internet por Wi-Fi", detail: "Comparte la misma radio con el iPad y suma latencia. Conéctala por cable."))
        } else {
            out.append(GameCheck(id: "uplink", level: .good, title: "La Mac sale por cable", detail: "Conexión: \(uplink)."))
        }
        if awdlHeld {
            out.append(GameCheck(id: "awdl", level: .good, title: "AWDL apagada", detail: "La radio de la Mac no salta de canal por AirDrop, Handoff ni AirPlay. Vuelve sola al terminar."))
        } else if awdlActive && rhythmic {
            out.append(GameCheck(id: "awdl", level: .warn, title: "AWDL activa y los saltos son regulares", detail: "Apágala con «Apagar AirDrop y Handoff» en Tweaks."))
        } else {
            out.append(GameCheck(id: "awdl", level: .info, title: "AWDL activa", detail: "Es la interfaz que usan AirDrop, Handoff y AirPlay. Sin saltos periódicos hasta ahora. Pruébala apagada en el Laboratorio de la pestaña Red."))
        }
        out.append(mbit > 80
            ? GameCheck(id: "load", level: .bad, title: "El Wi-Fi compartido está saturado", detail: "\(ms(mbit)) Mbit/s: otro equipo lo está usando. Desconéctalo o pausa esa descarga.")
            : mbit > 40
            ? GameCheck(id: "load", level: .warn, title: "El Wi-Fi compartido está cargado", detail: "\(ms(mbit)) Mbit/s. Con más de 120 Mbit/s hacia otro equipo, el ping del iPad subió mucho en una prueba.")
            : GameCheck(id: "load", level: .good, title: "El Wi-Fi compartido está libre", detail: "\(ms(mbit)) Mbit/s en uso."))
        if !hasLocal {
            out.append(GameCheck(id: "calm", level: .info, title: "Estabilidad sin medir", detail: "Se mide cuando el iPad está despierto."))
        } else if lossPct > 0 || spikes > 2 {
            out.append(GameCheck(id: "calm", level: .warn, title: "Hubo saltos en el último minuto", detail: "\(spikes) saltos de más de 20 ms y \(ms(lossPct))% de pérdida en el tramo del iPad."))
        } else {
            out.append(GameCheck(id: "calm", level: .good, title: "Sin saltos en el último minuto", detail: "El tramo del iPad se mantuvo dentro de 20 ms."))
        }
        if others == 0 {
            out.append(GameCheck(id: "others", level: .info, title: "Sin otros equipos conectados", detail: "Nadie más usa el Wi-Fi compartido ahora."))
        } else if exclusive && limited > 0 {
            out.append(GameCheck(id: "others", level: .good, title: "Los demás equipos están limitados a \(limitMbit) Mbit/s", detail: "El iPad tiene la línea casi entera."))
        } else if exclusive {
            out.append(GameCheck(id: "others", level: .info, title: "Modo exclusivo sin aplicar", detail: "Se aplica al empezar el modo juego."))
        } else {
            out.append(GameCheck(id: "others", level: .info, title: "Los demás equipos no tienen límite", detail: "Si uno descarga, el iPad lo nota: en una prueba, 120 Mbit/s hacia otro equipo subieron el p99 del iPad de 7,7 a 37 ms. Actívalo en Ajustes."))
        }
        if let loaded = loadedMs {
            out.append(loaded <= 30
                ? GameCheck(id: "bloat", level: .good, title: "Sin lag bajo carga", detail: "Con la línea llena, unos \(ms(loaded)) ms.")
                : loaded <= 60
                ? GameCheck(id: "bloat", level: .warn, title: "Algo de lag bajo carga", detail: "Con la línea llena, unos \(ms(loaded)) ms. Evita descargas mientras juegas.")
                : GameCheck(id: "bloat", level: .bad, title: "Mucho lag bajo carga", detail: "Con la línea llena, unos \(ms(loaded)) ms. Nada de descargas mientras juegas."))
        } else {
            out.append(GameCheck(id: "bloat", level: .info, title: "Lag bajo carga sin medir", detail: "Usa «Medir saturación» en la pestaña Red, sin jugar."))
        }
        if let air {
            let on = air.airdrop == .on || air.handoff == .on
            if on && awdlHeld {
                out.append(GameCheck(id: "air", level: .info, title: "AirDrop o Handoff están encendidos", detail: "No importa ahora: AWDL está apagado mientras dure el modo juego."))
            } else if on {
                out.append(GameCheck(id: "air", level: .warn, title: "AirDrop o Handoff están encendidos", detail: "Hacen saltar la radio del Wi-Fi compartido. Apágalos en la Mac o activa «Apagar AirDrop y Handoff» en Tweaks."))
            } else if air.airdrop == .off && air.handoff == .off {
                out.append(GameCheck(id: "air", level: .good, title: "AirDrop y Handoff apagados en la Mac", detail: "Sin saltos de canal por AWDL."))
            } else if air.airdrop == .off {
                out.append(GameCheck(id: "air", level: .info, title: "AirDrop apagado, Handoff sin dato", detail: "macOS no guarda el ajuste de Handoff en esta Mac, así que no se sabe si está encendido."))
            } else {
                out.append(GameCheck(id: "air", level: .info, title: "AirDrop y Handoff sin dato", detail: "macOS no devolvió el estado. Míralo en Ajustes del Sistema, General, AirDrop y Handoff."))
            }
        }
        if let pid = juegoPID {
            out.append(GameCheck(id: "juego", level: .info, title: "El registro de partidas está corriendo (pid \(pid))", detail: awdlDuringGame
                ? "También mantiene AWDL apagado. Si lo cierras, enciende AirDrop y esta app lo vuelve a apagar."
                : "Mantiene AWDL apagado. Si lo cierras, AirDrop y Handoff vuelven a encenderse."))
        }
        return out
    }
}

enum GameProfile: String, CaseIterable, Identifiable {
    case competitive = "Competitivo", balanced = "Equilibrado", saver = "Solo medir"
    var id: String { rawValue }
    var about: String {
        switch self {
        case .competitive: "Todo encendido: prioridad total al iPad. Lo mantiene despierto, apaga AirDrop, limita a los demás equipos, duerme las apps de red de la Mac y pausa Time Machine."
        case .balanced: "Mantiene despierto al iPad y baja la prioridad de lo pesado. AirDrop, los demás equipos y las apps de red quedan como están."
        case .saver: "No toca nada. Solo mide lo que pase."
        }
    }
}

extension GameLink {
    var profile: GameProfile? {
        let all = [keepAwake, awdlDuringGame, autoServer, exclusive, autoSilence, lowerPriority, pauseBackup]
        if all.allSatisfy({ $0 }) { return .competitive }
        if keepAwake && !awdlDuringGame && autoServer && !exclusive && !autoSilence && lowerPriority && pauseBackup { return .balanced }
        if all.allSatisfy({ !$0 }) { return .saver }
        return nil
    }

    func apply(_ p: GameProfile) {
        switch p {
        case .competitive: keepAwake = true; awdlDuringGame = true; autoServer = true; exclusive = true; autoSilence = true; lowerPriority = true; pauseBackup = true
        case .balanced: keepAwake = true; awdlDuringGame = false; autoServer = true; exclusive = false; autoSilence = false; lowerPriority = true; pauseBackup = true
        case .saver: keepAwake = false; awdlDuringGame = false; autoServer = false; exclusive = false; autoSilence = false; lowerPriority = false; pauseBackup = false
        }
    }

    var checks: [GameCheck] {
        GameChecks.build(sharing: sharing, hasPeer: activePeer != nil, ipad: ipad, keepAwake: keepAwake, channel: channel, uplink: uplink,
                         awdlHeld: awdlHeld, awdlActive: awdl, rhythmic: rhythmic, mbit: (down + up) * 8 / 1e6, spikes: local.spikes,
                         lossPct: local.lossPct, hasLocal: hasLocal, loadedMs: quality?.loaded,
                         others: max(0, peers.count - (activePeer == nil ? 0 : 1)), exclusive: exclusive, limited: limited.count, limitMbit: exclusiveMbit, juegoPID: juegoPID, awdlDuringGame: awdlDuringGame, air: air)
    }
}

struct GameChecksCard: View {
    @ObservedObject var g: GameLink
    var compact = false
    @State private var showAll = false

    var body: some View {
        let items = g.checks
        let good = items.filter { $0.level == .good }.count
        let shown = compact && !showAll ? items.filter { $0.level == .warn || $0.level == .bad } : items
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(compact ? "Para revisar" : "Chequeo de gaming").font(.headline)
                Spacer()
                if compact {
                    Button(showAll ? "Solo problemas" : "Ver los \(items.count) puntos") { showAll.toggle() }.buttonStyle(.link).font(.caption)
                } else {
                    Text("\(good) de \(items.count) en orden").font(.caption).foregroundStyle(.secondary)
                }
            }
            if shown.isEmpty {
                Label("Todo en orden: \(good) de \(items.count)", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
            }
            ForEach(shown) { c in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon(c.level)).foregroundStyle(color(c.level)).frame(width: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(c.title).font(.callout.weight(.medium))
                        Text(c.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                    Spacer(minLength: 0)
                }
                .help(c.detail)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(16)
    }

    private func icon(_ l: GameCheck.Level) -> String {
        switch l {
        case .good: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .bad: "xmark.octagon.fill"
        case .info: "info.circle"
        }
    }

    private func color(_ l: GameCheck.Level) -> Color {
        switch l {
        case .good: .green
        case .warn: .orange
        case .bad: .red
        case .info: .secondary
        }
    }
}

struct GameProfileCard: View {
    @ObservedObject var g: GameLink
    private let custom = "Personalizado"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Perfil").font(.headline)
            Picker("", selection: Binding(get: { g.profile?.rawValue ?? custom }, set: { name in if let p = GameProfile(rawValue: name) { g.apply(p) } })) {
                ForEach(GameProfile.allCases) { Text($0.rawValue).tag($0.rawValue) }
                if g.profile == nil { Text(custom).tag(custom) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 460)
            .help("Cambia de golpe los siete interruptores de la pestaña Tweaks")
            Text(g.profile?.about ?? "Combinación tuya: los interruptores no coinciden con ningún perfil.").font(.callout).foregroundStyle(.secondary).lineLimit(3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(16)
    }
}
