import SwiftUI
import AppKit

struct MsLine: View {
    let values: [Double]
    var window = GameLink.window
    var goal = 20.0
    var top = 40.0

    var body: some View {
        Canvas { ctx, size in
            func y(_ v: Double) -> CGFloat { size.height * (1 - min(max(v, 0), top) / top) }
            var dash = Path()
            dash.move(to: CGPoint(x: 0, y: y(goal)))
            dash.addLine(to: CGPoint(x: size.width, y: y(goal)))
            ctx.stroke(dash, with: .color(.green.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(window - 1)
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: size.width - CGFloat(values.count - 1 - i) * step, y: y(v))
                i == 0 ? line.move(to: p) : line.addLine(to: p)
            }
            ctx.stroke(line, with: .color(Color.brandTeal), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}

enum GameTab: String, CaseIterable, Identifiable {
    case live = "Jugar", tune = "Tweaks", net = "Red", log = "Historial"
    var id: String { rawValue }
}

struct GamePane: View {
    @ObservedObject var g: GameLink
    @ObservedObject var m: Monitor
    @State private var juegoSummary: JuegoSummary?
    @State private var confirmLoad = false

    @AppStorage("gameTab2") private var tabName = GameTab.live.rawValue
    private var totalMs: Double { g.totalMs }
    private var hasLocal: Bool { g.hasLocal }

    private var heat: (Double, String) {
        switch verdict.0 {
        case "Excelente": (1, "Ping en llamas: todo dentro de 0 a 20 ms")
        case "Aceptable": (0.6, "Fuego medio: el ping aguanta pero se mueve")
        case "Con problemas": (0.25, "Brasas: el ping no está limpio")
        case "iPad dormido": (0.3, "Brasas: el iPad está dormido")
        case "iPad en reposo": (0.3, "Brasas: el iPad está en reposo, abre el juego para medir")
        default: (0.3, "Esperando la medición…")
        }
    }

    private var verdict: (String, Color, String) {
        guard !g.net.got.isEmpty else { return ("Midiendo…", .secondary, "Espera unos segundos.") }
        if g.activePeer != nil, g.keepAwake, g.ipad != .awake {
            return g.ipad == .waiting
                ? ("Despertando al iPad…", .secondary, "Puede tardar unos segundos. Si tarda más, enciende la pantalla del iPad.")
                : ("iPad dormido", .secondary, "No responde: está dormido o salió del Wi-Fi. Enciende su pantalla y en unos segundos vuelve a medirse.")
        }
        if g.ipadDead { return ("iPad sin respuesta", .secondary, "No responde: está apagado, dormido o salió del Wi-Fi. Enciende su pantalla y vuelve a mirar.") }
        let jitter = max(g.local.jitter, g.net.jitter), loss = max(g.local.lossPct, g.net.lossPct)
        let why: String
        var idle = false
        if hasLocal, g.local.lossPct > 0 || g.local.spikes > 2 || g.local.jitter > 5, (g.down + g.up) * 8 / 1e6 > 80 {
            why = "El Wi-Fi compartido está muy cargado (\(Int((g.down + g.up) * 8 / 1e6)) Mbit/s): otro equipo lo está usando. Desconéctalo o pausa esa descarga."
        } else if hasLocal, g.local.lossPct > 0 || g.local.spikes > 2 || g.local.jitter > 5, !g.playing {
            idle = true
            why = "El iPad casi no usa la red ahora (\(ms((g.down + g.up) * 8 / 1e6)) Mbit/s). En reposo el Wi-Fi duerme entre mensajes y se ven saltos que no sentirás jugando. Abre el juego y vuelve a mirar."
        } else if hasLocal, g.local.lossPct > 0 || g.local.spikes > 2 || g.local.jitter > 5, g.rhythmic, g.awdl {
            why = "Los saltos se repiten a ritmo regular. Puede ser AirDrop o algo del aire: compruébalo en el Laboratorio de la pestaña Red, no lo damos por cierto."
        } else if hasLocal, g.local.lossPct > 0 || g.local.spikes > 2 || g.local.jitter > 5 {
            why = g.keepAwake ? (g.awdl ? "El tramo iPad ↔ Mac se mueve: es el aire del Wi-Fi. Acerca el iPad, apaga AirDrop o cambia de canal."
                                       : (g.aligned == true ? "El tramo iPad ↔ Mac se mueve con AirDrop apagado y el canal \(g.channelNumber ?? 0) ya elegido: es el aire del Wi-Fi o el propio iPad. Acércalo al Mac."
                                          : "El tramo iPad ↔ Mac se mueve y AirDrop ya está apagado, así que no es eso: es el aire del Wi-Fi. Acerca el iPad o cambia el canal a 44 (ahora: \(g.channelNumber.map(String.init) ?? "sin dato"))."))
                : "El tramo iPad ↔ Mac se mueve. Con el iPad en reposo el Wi-Fi duerme entre mensajes: activa «Mantener el iPad despierto» en Tweaks para medir como en partida."
        } else if g.net.jitter > 5 || g.net.lossPct > 0 {
            if let top = g.hogs.first, top.rate >= 1_000_000 {
                why = "La línea está ocupada: \(g.owner(top, m)?.name ?? top.name) mueve \(rateText(top.rate)). Actívale «Dormir las apps que usan la red» en Tweaks."
            } else {
                why = "El tramo hacia internet se mueve: es la fibra o el router de tu proveedor."
            }
        } else if totalMs > 20 {
            why = "Tu red está estable. Lo que suma es la distancia hasta el servidor."
        } else {
            why = "Todo dentro de la meta de 0 a 20 ms."
        }
        // an idle iPad naps between messages: its latency says nothing about a match, so no red alarm
        if idle { return ("iPad en reposo", .secondary, why) }
        if loss == 0, totalMs <= 20, jitter <= 5 { return ("Excelente", .green, why) }
        if loss < 2, totalMs <= 40, jitter <= 15 { return ("Aceptable", .orange, why) }
        return ("Con problemas", .red, why)
    }

    var body: some View {
        let v = verdict
        VStack(alignment: .leading, spacing: 14) {
            Header(title: "Modo juego", subtitle: "Tu Mac le da internet al iPad. Un toque y queda lo más rápido que permite el aire.")
            Picker("", selection: $tabName) {
                ForEach(GameTab.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 480)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !g.sharing { sharingOff }
                    switch GameTab(rawValue: tabName) ?? .live {
                    case .live: liveTab(v)
                    case .tune: tuneTab
                    case .net: netTab
                    case .log: logTab
                    }
                }
                .padding(.horizontal, 2).padding(.bottom, 6)
            }
            .scrollIndicators(.hidden)
        }
        .padding()
        .onAppear { g.watch(true) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in g.refreshChannel() }
        .onDisappear { g.watch(false) }
        .task(id: tabName) {
            if tabName == GameTab.log.rawValue { juegoSummary = await Task.detached { JuegoLog.load() }.value }
        }
        .confirmationDialog("La prueba llena tu internet unos 25 segundos. No la hagas en plena partida: el iPad se va a sentir lento mientras dure.", isPresented: $confirmLoad) {
            Button("Medir ahora") { Task { await g.measureLoad() } }
        }
    }

    private var pathNote: String? {
        var parts: [String] = []
        if hasLocal, !g.lan.got.isEmpty, !g.net.got.isEmpty {
            parts.append("Con el iPad por cable (estimado): \(ms(g.lan.avg + g.net.avg)) ms en vez de \(ms(g.totalMs)) ms. Es el tramo de tu Mac al router más internet; no está medido con tu iPad.")
        }
        if !g.net6.got.isEmpty, !g.net.got.isEmpty {
            parts.append("Hasta Cloudflare por IPv6: \(ms(g.net6.avg)) ms" + (g.destino == "1.1.1.1" ? "; por IPv4: \(ms(g.net.avg)) ms" : "; tu destino (\(g.destino)): \(ms(g.net.avg)) ms") + ". El iPad usa IPv6 cuando el servidor lo ofrece.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func hero(_ v: (String, Color, String)) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(g.net.got.isEmpty || g.ipadDead ? "—" : ms(totalMs)).font(.system(size: 56, weight: .semibold)).tracking(-1.5).monospacedDigit()
                        Text("ms").font(.title3).foregroundStyle(.secondary)
                    }
                    Text(g.ipadDead ? "el iPad no responde" : hasLocal ? "de tu iPad a \(g.destino), ida y vuelta" : "de tu Mac a \(g.destino), ida y vuelta").font(.callout).foregroundStyle(.secondary)
                    Label(v.0, systemImage: v.0 == "Excelente" ? "checkmark.circle.fill" : v.1 == .secondary ? "hourglass" : "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold)).foregroundStyle(v.1).padding(.top, 4)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    MsLine(values: Array(g.local.got.suffix(600)), window: 600).frame(width: 300, height: 56)
                    Text("iPad ↔ Mac, últimos 30 s. Línea verde: 20 ms").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(v.2).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            if v.0 == "Con problemas" || v.0 == "Aceptable" {
                HStack(spacing: 8) {
                    Button { Task { await g.fixNow(m) } } label: { Label(g.fixing ? "Arreglando…" : "Arreglar ahora", systemImage: "wrench.and.screwdriver.fill") }
                        .buttonStyle(PrimaryButton()).disabled(g.fixing)
                        .help("Sin preguntas: activa el modo juego con tus tweaks y mide el tramo del iPad antes y después")
                    Button("Cambiar canal") { openSettings("com.apple.Sharing-Settings.extension") }
                        .controlSize(.regular)
                        .help("Compartir Internet → Wi-Fi → Opciones → Canal 44. Es un ajuste del sistema: lo cambias tú")
                    if !g.fixNote.isEmpty { Text(g.fixNote).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                }
            }
            if !g.destinoNote.isEmpty { Text(g.destinoNote).font(.callout).foregroundStyle(.orange).lineLimit(3) }
            Divider()
            HStack(alignment: .top, spacing: 24) {
                Hop(title: "iPad ↔ Mac (Wi-Fi)", symbol: "wifi", w: hasLocal ? g.local : Series(capacity: 1),
                    empty: !g.sharing ? "Compartir Internet apagado" : g.activePeer == nil ? "Sin iPad conectado" : g.ipadDead ? "Sin respuesta del iPad" : g.ipad == .waiting ? "Despertando al iPad…" : "Dormido o fuera del Wi-Fi")
                Hop(title: "Mac ↔ router (cable)", symbol: "cable.connector", w: g.lan, empty: "Midiendo…")
                Hop(title: "Mac ↔ internet (fibra)", symbol: "network", w: g.net, empty: "Midiendo…")
            }
            if g.session != nil {
                FireBand(heat: heat.0, label: heat.1, live: NSApp.occlusionState.contains(.visible))
            }
        }
        .padding(16)
        .card(16)
    }

    private func liveTab(_ v: (String, Color, String)) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            hero(v)
            HStack(alignment: .top, spacing: 16) {
                playCard
                GameChecksCard(g: g, compact: true)
            }
        }
    }

    private var tuneTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            GameProfileCard(g: g)
            GameTweaksCard(g: g, m: m)
            if !g.hogs.isEmpty { hogs }
            GameIdeasCard()
        }
    }

    private var netTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                hotspot
                diagnostics
            }
            HStack(alignment: .top, spacing: 16) {
                GameServerCard(g: g)
                GameDNSCard(g: g)
            }
            HStack(alignment: .top, spacing: 16) {
                GameTargetCard(g: g)
                GameLabCard(g: g)
            }
            GameIPsCard(g: g)
        }
    }

    private var logTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            if g.history.isEmpty {
                Text("Todavía no hay sesiones. Se guardan al terminar el modo juego, si duraron lo bastante para medir.").font(.callout).foregroundStyle(.secondary)
            }
            GameHistoryCard(history: g.history)
            GameChannelCard(history: g.history)
            GameJuegoCard(summary: juegoSummary)
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnóstico").font(.headline)
            HStack(spacing: 8) {
                Button { confirmLoad = true } label: { Label(g.measuring ? "Midiendo…" : "Medir saturación", systemImage: "gauge.with.dots.needle.67percent") }
                    .disabled(g.measuring)
                    .help("Llena tu internet 25 segundos y mide cuánto sube la latencia bajo carga (bufferbloat)")
                Button { g.copyReport() } label: { Label("Copiar informe", systemImage: "doc.on.clipboard") }
                    .help("Copia las mediciones con fecha, listas para mandarlas a tu proveedor")
            }
            if let note = pathNote { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(5) }
            if let q = g.quality {
                Text("Saturación: \(Int(q.rpm)) RPM, unos \(ms(q.loaded)) ms bajo carga hasta el servidor de Apple (en reposo \(ms(q.baseRTT)) ms). Bajada \(Int(q.down)) y subida \(Int(q.up)) Mbit/s.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                if !g.loadNote.isEmpty { Text(g.loadNote).font(.caption.weight(.medium)).foregroundStyle(Color.brandTeal).lineLimit(3) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(16)
    }

    private var sharingOff: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Compartir Internet está apagado").font(.headline)
                Text("Enciéndelo en Ajustes del Sistema → General → Compartir para que el iPad use el Wi-Fi de tu Mac.").font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Abrir Compartir") { openSettings("com.apple.Sharing-Settings.extension") }
        }
        .padding(14)
        .card(14, tint: .orange)
    }

    private var playCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let s = g.session {
                HStack(alignment: .firstTextBaseline) {
                    TimelineView(.periodic(from: .now, by: 1)) { tl in
                        Text("Jugando \(elapsedText(tl.date.timeIntervalSince(s.start)))").font(.title3.weight(.semibold).monospacedDigit())
                    }
                    Spacer()
                    Button { Task { await g.toggleSession(m) } } label: { Label("Terminar", systemImage: "stop.fill") }
                        .buttonStyle(PrimaryButton())
                        .help("Termina el modo juego y deja todo como estaba")
                }
                if s.resumed != nil { Label("Se retomó al abrir la app. Las cifras cuentan desde entonces.", systemImage: "arrow.clockwise").font(.caption).foregroundStyle(Color.brandTeal) }
                Text(s.play.n > 0
                     ? "En juego: iPad ↔ Mac \(ms(s.play.avg)) ms de promedio, pico \(ms(s.play.peak)) ms, \(plural(s.play.lost, "pérdida", "pérdidas")), \(plural(s.play.spikes, "salto", "saltos")) de más de 20 ms."
                     : s.local.n > 0 ? "El iPad está en reposo: todavía no hay partida que contar. Se cuenta cuando el Wi-Fi mueve más de \(ms(GameLink.activeMbit)) Mbit/s."
                     : "Esperando al iPad para empezar a contar.")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(3)
                if !s.relieved.isEmpty { Text("Con prioridad baja: \(s.relieved.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                chips
            } else {
                Button { Task { await g.play(m) } } label: {
                    Label("Activar modo juego", systemImage: "flame.fill").frame(maxWidth: .infinity).padding(.vertical, 3)
                }
                .buttonStyle(FireButton())
                .disabled(!g.playSteps.isEmpty)
                .help("Un toque: aplica lo que tengas encendido en Tweaks. Al terminar vuelve todo a como estaba")
                if g.playSteps.isEmpty {
                    chips
                    HStack(spacing: 6) {
                        Text(g.note.isEmpty ? "Se aplica al tocar el botón." : g.note).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        Spacer(minLength: 0)
                        Button("Cambiar") { tabName = GameTab.tune.rawValue }.buttonStyle(.link).font(.caption)
                    }
                } else {
                    PlayChecklist(steps: g.playSteps)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button { Task { await g.fixNow(m) } } label: {
                    Label(g.fixing ? "Arreglando…" : "Arreglar ahora", systemImage: "wrench.and.screwdriver.fill")
                }
                .buttonStyle(PrimaryButton())
                .disabled(g.fixing)
                .help("Sin preguntas: activa el modo juego, apaga AirDrop, y mide el tramo del iPad antes y después")
                if !g.fixNote.isEmpty { Text(g.fixNote).font(.caption).foregroundStyle(.secondary).lineLimit(4) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(16)
    }

    private var chips: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(g.plan) { item in
                Label(item.title, systemImage: item.symbol).font(.caption).lineLimit(1)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.quaternary.opacity(0.7), in: Capsule())
            }
        }
    }

    private var hotspot: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tu Wi-Fi compartido").font(.headline)
                Spacer()
                Button { openSettings("com.apple.Sharing-Settings.extension") } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).help("Abre Compartir Internet para cambiar el canal y la seguridad")
            }
            Text(g.channel.isEmpty ? "Canal sin datos" : "Canal \(g.channel)").font(.callout).foregroundStyle(.secondary)
            if let ok = g.aligned {
                Label(ok ? "Igual que el canal de AirDrop: la radio no tiene que saltar" : "AirDrop usa los canales 44 y 149; el tuyo es distinto",
                      systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.caption).foregroundStyle(ok ? Color.green : .orange)
                    .help("Cuando AirDrop o Handoff buscan equipos, la radio de la Mac salta a su canal y vuelve. Si tu Wi-Fi compartido ya está en ese canal, no hay salto y el iPad no lo nota. Fuente: investigación de IIJ (2025) y pruebas de la comunidad")
                if !ok { Button("Cambiar canal") { openSettings("com.apple.Sharing-Settings.extension") }.font(.caption).help("En Compartir Internet → Wi-Fi → Opciones → Canal: elige 44, o 149 si aparece en tu lista") }
            }
            if let n = g.newcomer {
                HStack(spacing: 8) {
                    Image(systemName: "person.fill.questionmark").foregroundStyle(.orange)
                    Text("Equipo nuevo: \(n.name) (\(n.mac))").font(.caption).lineLimit(2)
                    Spacer()
                    Button("Es mío") { g.trust(n) }.controlSize(.small)
                }
                .help("Un equipo que no habías visto entró a tu Wi-Fi compartido. Si no es tuyo, cambia la contraseña en Compartir Internet")
            }
            ForEach(g.peers) { p in
                Button { g.peerID = p.id } label: {
                    HStack(spacing: 10) {
                        Image(systemName: p.symbol).frame(width: 22).foregroundStyle(Color.brandTeal)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(p.name).fontWeight(.medium)
                            Text(p.id).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if g.activePeer?.id == p.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.brandTeal).help("Es el equipo que se está midiendo") }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if g.peers.isEmpty && g.sharing { Text("Ningún equipo conectado").font(.callout).foregroundStyle(.secondary) }
            Divider()
            let mbit = (g.down + g.up) * 8 / 1e6
            HStack(spacing: 14) {
                Label(rateText(g.down), systemImage: "arrow.down").help("Lo que bajan los equipos conectados ahora")
                Label(rateText(g.up), systemImage: "arrow.up").help("Lo que suben los equipos conectados ahora")
                Spacer()
                Text("\(ms(mbit)) Mbit/s").fontWeight(.medium)
            }
            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Meter(value: mbit / 120, tint: mbit > 80 ? .red : mbit > 40 ? .orange : Color.brandTeal, height: 5)
                .help("Cuánto aire usan los equipos del Wi-Fi compartido. En una prueba aquí, 40 Mbit/s hacia otro equipo no movieron el ping del iPad; 120 Mbit/s subieron su p99 de 7,7 a 37 ms")
            if !g.lockChecked {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.open").foregroundStyle(.secondary)
                    Text("Comprueba en el iPad que «\(g.ssid.isEmpty ? "tu red" : g.ssid)» tenga candado. Un error de macOS 15.5 y de las betas de 26 puede dejar el Wi-Fi compartido sin contraseña.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(4)
                    Button("Ya lo comprobé") { g.lockChecked = true }.controlSize(.small)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(16)
    }

    private var hogs: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quién usa la red en tu Mac").font(.headline)
            ForEach(g.hogs) { h in
                let item = g.owner(h, m)
                HStack(spacing: 10) {
                    if let item { Image(nsImage: item.icon).resizable().frame(width: 22, height: 22) } else { Image(systemName: "gearshape").frame(width: 22) }
                    Text(item?.name ?? h.name).fontWeight(.medium).lineLimit(1)
                    Spacer()
                    Text(rateText(h.rate)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    if let item, !item.protected, item.kind != .loose, !NightMode.keep.contains(item.name) {
                        Button(item.paused ? "Despertar" : "Dormir") { m.setPaused(item, !item.paused) }.controlSize(.small)
                            .help(item.paused ? "Despierta esta app" : "Congela esta app para que no use la red. No pierde nada")
                    }
                }
            }
            Text("Solo aparece lo que usa la Mac. Lo que usan el iPad o el iPhone pasa por el Wi-Fi compartido y se ve arriba en bajada y subida.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }

}

private struct Hop: View {
    let title: String, symbol: String
    let w: Series
    let empty: String

    var body: some View {
        let ok = w.lossPct == 0 && w.avg <= 20 && w.jitter <= 5
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.callout.weight(.medium))
            if w.got.isEmpty {
                Text(empty).font(.callout).foregroundStyle(.secondary)
            } else {
                Text("\(ms(w.avg)) ms").font(.title2.weight(.semibold).monospacedDigit())
                Meter(value: w.avg / 20, tint: ok ? .green : w.avg > 40 ? .red : .orange, height: 6)
                Text("p99 \(ms(w.percentile(0.99))) ms · jitter \(ms(w.jitter)) ms" + (w.lossPct > 0 ? " · pérdida \(ms(w.lossPct))%" : ""))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .help("Jitter \(ms(w.jitter)) ms · p99 \(ms(w.percentile(0.99))) ms · pico \(ms(w.peak)) ms · pérdida \(ms(w.lossPct))%. Jitter: cuánto varían los tiempos de respuesta. p99: el valor que solo el 1% de los paquetes supera, lo que más se nota al jugar. Todo es del último minuto")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
