import SwiftUI
import AppKit
import WebKit

enum Hosts {
    static let start = "# TP Optimizer: inicio"
    static let end = "# TP Optimizer: fin"
    static let trackers = ["doubleclick.net", "www.doubleclick.net", "googlesyndication.com", "pagead2.googlesyndication.com",
                           "googleadservices.com", "www.googleadservices.com", "adservice.google.com", "adnxs.com", "ib.adnxs.com",
                           "taboola.com", "cdn.taboola.com", "outbrain.com", "widgets.outbrain.com", "criteo.com", "static.criteo.net",
                           "scorecardresearch.com", "sb.scorecardresearch.com", "hotjar.com", "static.hotjar.com", "ads.yahoo.com"]

    static func read() -> [String] {
        let text = (try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)) ?? ""
        guard let a = text.range(of: start), let b = text.range(of: end), a.upperBound < b.lowerBound else { return [] }
        return text[a.upperBound..<b.lowerBound].split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ")
            return parts.count == 2 && parts[0] == "0.0.0.0" ? String(parts[1]) : nil
        }
    }

    static func valid(_ d: String) -> Bool { d.range(of: #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"#, options: .regularExpression) != nil }

    static func write(_ domains: [String]) async -> Bool {
        let clean = Array(Set(domains.filter(valid))).sorted()
        return await Task.detached { Root.run(["hosts"] + clean) }.value
    }
}

struct Device: Identifiable {
    var id: String { ip }
    let ip: String
    let mac: String
    let isRouter: Bool
    let isMe: Bool
    var privateMAC: Bool { mac.count > 1 && "26ae".contains(mac[mac.index(after: mac.startIndex)]) }
}

struct FirewallApp: Identifiable {
    var id: String { path }
    let path: String
    let blocked: Bool
    var name: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
}

struct Listener: Identifiable {
    var id: String { name + address }
    let name: String
    let address: String
    var open: Bool { address.hasPrefix("*") || address.hasPrefix("0.0.0.0") || address.hasPrefix("[::]") }
}

@MainActor
final class NetworkModel: ObservableObject {
    @Published var gateway = ""
    @Published var model = ""
    @Published var devices: [Device] = []
    @Published var blocked: [String] = []
    @Published var fwOn = false
    @Published var stealth = false
    @Published var apps: [FirewallApp] = []
    @Published var listeners: [Listener] = []
    @Published var status = ""
    nonisolated static let fw = "/usr/libexec/ApplicationFirewall/socketfilterfw"

    func refresh() async {
        let (gw, arp, fw, list, listen) = await Task.detached {
            (shell("route -n get default | awk '/gateway/{print $2}'").trimmingCharacters(in: .whitespacesAndNewlines),
             shell("arp -an"),
             shell("\(NetworkModel.fw) --getglobalstate --getstealthmode"),
             shell("\(NetworkModel.fw) --listapps"),
             shell("lsof -nP -iTCP -sTCP:LISTEN | awk 'NR>1{print $1\" \"$9}' | sort -u"))
        }.value
        gateway = gw
        let me = shell("ipconfig getifaddr en0").trimmingCharacters(in: .whitespacesAndNewlines)
        devices = arp.split(separator: "\n").compactMap { line in
            let s = String(line)
            guard let ipR = s.range(of: #"\((\d+\.\d+\.\d+\.\d+)\)"#, options: .regularExpression),
                  let macR = s.range(of: #"at ([0-9a-f:]+) "#, options: .regularExpression) else { return nil }
            let ip = String(s[ipR]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            let mac = String(s[macR]).replacingOccurrences(of: "at ", with: "").trimmingCharacters(in: .whitespaces)
            guard !ip.hasPrefix("169.254"), !ip.hasPrefix("224."), !ip.hasPrefix("239."), !ip.hasSuffix(".255") else { return nil }
            return Device(ip: ip, mac: mac, isRouter: ip == gw, isMe: ip == me)
        }
        .sorted { ($0.isRouter ? 0 : $0.isMe ? 1 : 2, $0.ip.count, $0.ip) < ($1.isRouter ? 0 : $1.isMe ? 1 : 2, $1.ip.count, $1.ip) }
        fwOn = fw.contains("enabled")
        stealth = fw.contains("stealth mode is on")
        var parsed: [FirewallApp] = [], pending: String?
        for line in list.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let r = t.range(of: #"^\d+ : "#, options: .regularExpression) { pending = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces) }
            else if let p = pending, t.hasPrefix("(") { parsed.append(FirewallApp(path: p, blocked: t.contains("Block"))); pending = nil }
        }
        apps = parsed.sorted { ($0.blocked ? 0 : 1, $0.name) < ($1.blocked ? 0 : 1, $1.name) }
        listeners = listen.split(separator: "\n").compactMap { l in
            let p = l.split(separator: " ", maxSplits: 1)
            return p.count == 2 ? Listener(name: String(p[0]), address: String(p[1])) : nil
        }
        .sorted { ($0.open ? 0 : 1, $0.name) < ($1.open ? 0 : 1, $1.name) }
        blocked = Hosts.read()
        for attempt in 0..<3 where model.isEmpty && !gw.isEmpty {
            if attempt > 0 { try? await Task.sleep(for: .seconds(3)) }
            model = await routerModel(gw)
        }
    }

    func routerModel(_ ip: String) async -> String {
        guard let url = URL(string: "http://\(ip)/"),
              let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 4)) else { return "" }
        let html = String(decoding: data, as: UTF8.self)
        let brand = html.localizedCaseInsensitiveContains("huawei") ? "Huawei " : ""
        if let r = html.range(of: #"\b(EG|HG|HN|HS|WS|AX)\d{3,4}[A-Z0-9]*\b"#, options: .regularExpression) { return brand + html[r] }
        return brand.isEmpty ? "Router" : "Huawei"
    }

    func block(_ domains: [String]) {
        let add = domains.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter(Hosts.valid)
        guard !add.isEmpty else { status = "Escribe un dominio válido, por ejemplo tiktok.com"; return }
        Task {
            if await Hosts.write(blocked + add) {
                status = "Bloqueado en toda la Mac: \(add.count == 1 ? add[0] : plural(add.count, "sitio", "sitios"))."
                add.forEach { record("Bloqueé \($0) en toda la Mac", undo: .unblockDomain($0)) }
            } else { status = "No se aplicó el bloqueo." }
            blocked = Hosts.read()
        }
    }

    func unblock(_ d: String) {
        Task {
            if await Hosts.write(blocked.filter { $0 != d }) { record("Desbloqueé \(d)"); status = "\(d) desbloqueado." }
            blocked = Hosts.read()
        }
    }

    func setStealth(_ on: Bool) {
        Task {
            if await Task.detached(operation: { Root.run(["fw", "stealth", on ? "on" : "off"]) }).value {
                record("Modo invisible del firewall \(on ? "encendido" : "apagado")")
            } else {
                status = "No pude cambiar el modo invisible del firewall: el ayudante no recibió permiso."
            }
            await refresh()
        }
    }

    func setBlocked(_ app: FirewallApp, _ block: Bool) {
        Task {
            if await Task.detached(operation: { Root.run(["fw", block ? "block" : "unblock", app.path]) }).value {
                record("Firewall: \(block ? "bloqueé" : "permití") conexiones entrantes a \(app.name)", undo: block ? .unblockApp(app.path) : nil)
            } else {
                status = "No pude cambiar el firewall para \(app.name): el ayudante no recibió permiso."
            }
            await refresh()
        }
    }

    func addApp() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        guard p.runModal() == .OK, let url = p.url else { return }
        Task {
            if await Task.detached(operation: { Root.run(["fw", "add", url.path]) }).value {
                record("Firewall: bloqueé conexiones entrantes a \(url.deletingPathExtension().lastPathComponent)", undo: .unblockApp(url.path))
            } else {
                status = "No pude agregar \(url.deletingPathExtension().lastPathComponent) al firewall: el ayudante no recibió permiso."
            }
            await refresh()
        }
    }
}

struct RouterWeb: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let w = WKWebView(frame: .zero, configuration: config)
        w.load(URLRequest(url: url))
        return w
    }
    func updateNSView(_ w: WKWebView, context: Context) {}
}

struct NetworkPane: View {
    @StateObject private var n = NetworkModel()
    @State private var tab = 0
    @State private var domain = ""
    @State private var showWeb = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header(title: "Red y router", subtitle: "Tu router, tu red y tus reglas: quién se conecta y quién se queda afuera.")
            HStack {
                Picker("", selection: $tab) {
                    Text("Router").tag(0)
                    Text("Dispositivos").tag(1)
                    Text("Bloqueador").tag(2)
                    Text("Firewall").tag(3)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Text(n.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button { Task { await n.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Volver a leer")
            }
            switch tab {
            case 0: router
            case 1: devices
            case 2: blocker
            default: firewall
            }
        }
        .padding()
        .task { await n.refresh() }
    }

    var router: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "wifi.router").font(.system(size: 34)).foregroundStyle(Color.brandTeal)
                VStack(alignment: .leading, spacing: 2) {
                    Text(n.model.isEmpty ? "Router" : n.model).font(.title3.bold())
                    Text(n.gateway.isEmpty ? "Sin conexión" : "Dirección \(n.gateway) · \(plural(n.devices.count, "equipo conectado", "equipos conectados"))")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !n.gateway.isEmpty {
                    Button(showWeb ? "Cerrar panel" : "Abrir panel del router") { showWeb.toggle() }.buttonStyle(PrimaryButton())
                        .help("Abre la página de administración del router aquí mismo. El usuario y la clave los escribes tú")
                    Button { NSWorkspace.shared.open(URL(string: "http://\(n.gateway)")!) } label: { Image(systemName: "safari") }
                        .help("Abrirlo en el navegador")
                }
            }
            .padding(14)
            .card(12)
            if showWeb, let url = URL(string: "http://\(n.gateway)") {
                RouterWeb(url: url).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Cómo recuperar el control").font(.headline)
                        step(1, "Revisa la etiqueta debajo del router. Algunos Huawei traen ahí un usuario y una clave para entrar al panel. Si es así, esa clave suele dejar cambiar el Wi‑Fi, no todo.")
                        step(2, "Pide a tu proveedor el acceso de administrador, o pregunta si pueden poner el equipo en modo puente (bridge).")
                        step(3, "Lo más sólido: conecta tu propio router detrás del de tu proveedor. Así el Wi‑Fi, la clave, el QoS y los equipos son 100% tuyos, y tu proveedor no los toca.")
                        Label("No reinicies el router de fábrica sin hablar con tu proveedor: se puede borrar la configuración de la fibra y quedarte sin internet hasta que venga un técnico.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).font(.callout)
                        Label("Tu proveedor puede cambiar la configuración a distancia. Lo que ajustes en su router puede volver a como estaba.", systemImage: "info.circle")
                            .foregroundStyle(.secondary).font(.callout)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    func step(_ i: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(i)").font(.caption.bold()).frame(width: 22, height: 22).background(Circle().fill(Color.brandTeal.opacity(0.18)))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    var devices: some View {
        List(n.devices) { d in
            HStack(spacing: 10) {
                Image(systemName: d.isRouter ? "wifi.router" : d.isMe ? "macmini" : d.privateMAC ? "iphone" : "desktopcomputer")
                    .foregroundStyle(Color.brandTeal).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.isRouter ? "Router" : d.isMe ? "Esta Mac" : d.privateMAC ? "Teléfono o tablet (dirección privada)" : "Equipo").fontWeight(.medium)
                    Text("\(d.ip) · \(d.mac)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
            }
            .help(d.privateMAC ? "Los iPhone y Android usan una dirección privada que cambia. Por eso no se sabe la marca" : "Dirección física del equipo")
        }
        .listStyle(.inset)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    var blocker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Lo que bloquees aquí no abre en ningún navegador ni app de esta Mac. Bloquea el dominio exacto: tiktok.com no bloquea www.tiktok.com.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Dominio, por ejemplo tiktok.com", text: $domain).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                    .onSubmit { n.block([domain, "www." + domain]); domain = "" }
                Button("Bloquear") { n.block([domain, "www." + domain]); domain = "" }.buttonStyle(PrimaryButton())
                    .disabled(domain.isEmpty).help("Bloquea el dominio y su versión con www. Te pide tu contraseña")
                Spacer()
                Button("Bloquear publicidad y rastreadores") { n.block(Hosts.trackers) }
                    .help("Agrega \(Hosts.trackers.count) dominios de anuncios y rastreo conocidos. Algunos anuncios de Google dejarán de abrir")
            }
            if n.blocked.isEmpty {
                Placeholder(symbol: "hand.raised", text: "No hay nada bloqueado")
            } else {
                List(n.blocked, id: \.self) { d in
                    HStack {
                        Image(systemName: "hand.raised.fill").foregroundStyle(.red)
                        Text(d)
                        Spacer()
                        Button("Desbloquear") { n.unblock(d) }
                    }
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    var firewall: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(n.fwOn ? "Firewall encendido" : "Firewall apagado", systemImage: n.fwOn ? "checkmark.shield.fill" : "xmark.shield")
                    .foregroundStyle(n.fwOn ? Color.green : .red).fontWeight(.medium)
                Spacer()
                Toggle("Modo invisible", isOn: Binding(get: { n.stealth }, set: { n.setStealth($0) }))
                    .help("La Mac no responde a quien la busque en la red. RustDesk y tus bots siguen funcionando")
                Button("Bloquear una app") { n.addApp() }.help("Elige una app para que nadie de afuera pueda conectarse a ella")
            }
            List {
                Section("Apps con permiso de recibir conexiones") {
                    ForEach(n.apps) { a in
                        HStack {
                            Circle().fill(a.blocked ? Color.red : .green).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.name).fontWeight(.medium)
                                Text(a.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Button(a.blocked ? "Permitir" : "Bloquear") { n.setBlocked(a, !a.blocked) }
                        }
                    }
                }
                Section("Puertos abiertos ahora") {
                    ForEach(n.listeners) { l in
                        HStack {
                            Image(systemName: l.open ? "network" : "lock").foregroundStyle(l.open ? Color.orange : .secondary)
                            Text(l.name).fontWeight(.medium)
                            Text(l.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Spacer()
                            Text(l.open ? "Visible en tu red" : "Solo esta Mac").font(.caption).foregroundStyle(l.open ? Color.orange : .secondary)
                        }
                        .help(l.open ? "Cualquier equipo de tu Wi‑Fi puede intentar conectarse. El firewall decide si lo deja" : "Solo programas de esta Mac pueden usarlo")
                    }
                }
            }
            .listStyle(.inset)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}
