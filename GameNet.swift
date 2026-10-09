import SwiftUI

struct GameFlow: Identifiable {
    let proto: String
    let ip: String
    let port: Int
    var bytes: Int64
    var id: String { "\(proto)-\(ip)-\(port)" }

    nonisolated static func isPublic(_ ip: String) -> Bool {
        if ip.contains(":") {
            let h = ip.lowercased()
            return h.range(of: #"^[0-9a-f:]+$"#, options: .regularExpression) != nil && (h.hasPrefix("2") || h.hasPrefix("3"))
        }
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4, p.allSatisfy({ (0...255).contains($0) }) else { return false }
        if p[0] == 0 || p[0] == 10 || p[0] == 127 || p[0] >= 224 { return false }
        if p[0] == 172 && (16...31).contains(p[1]) { return false }
        if p[0] == 192 && p[1] == 168 { return false }
        if p[0] == 169 && p[1] == 254 { return false }
        if p[0] == 100 && (64...127).contains(p[1]) { return false }
        return true
    }

    nonisolated static func parse(_ text: String) -> [GameFlow] {
        let v4 = try! NSRegularExpression(pattern: #"IP (\d{1,3}(?:\.\d{1,3}){3})\.(\d+) > (\d{1,3}(?:\.\d{1,3}){3})\.(\d+): (\w+)"#)
        let v6 = try! NSRegularExpression(pattern: #"IP6 ([0-9a-fA-F:]+)\.(\d+) > ([0-9a-fA-F:]+)\.(\d+): (\w+)"#)
        let size = try! NSRegularExpression(pattern: #"(\d+)\s*$"#)
        func part(_ m: NSTextCheckingResult, _ i: Int, in s: String) -> String? { Range(m.range(at: i), in: s).map { String(s[$0]) } }
        var map: [String: GameFlow] = [:]
        for line in text.components(separatedBy: "\n") {
            let whole = NSRange(line.startIndex..., in: line)
            guard let m = (line.contains("IP6 ") ? v6 : v4).firstMatch(in: line, range: whole),
                  let src = part(m, 1, in: line), let dst = part(m, 3, in: line),
                  let sp = part(m, 2, in: line).flatMap({ Int($0) }), let dp = part(m, 4, in: line).flatMap({ Int($0) }) else { continue }
            let remote: (String, Int)
            if isPublic(dst) { remote = (dst, dp) } else if isPublic(src) { remote = (src, sp) } else { continue }
            guard ![53, 853, 5353, 123].contains(remote.1) else { continue }
            let proto = (part(m, 5, in: line) ?? "?").lowercased()
            let bytes = size.firstMatch(in: line, range: whole).flatMap { part($0, 1, in: line) }.flatMap { Int64($0) } ?? 0
            let flow = GameFlow(proto: proto, ip: remote.0, port: remote.1, bytes: bytes)
            if var seen = map[flow.id] {
                seen.bytes += bytes
                map[flow.id] = seen
            } else {
                map[flow.id] = flow
            }
        }
        return Array(map.values.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }.prefix(8))
    }

    nonisolated static func likely(_ flows: [GameFlow]) -> String? { flows.first { $0.proto == "udp" && GameFlow.portNames[$0.port] == nil }?.id }

    nonisolated static let portNames: [Int: String] = [51820: "túnel WireGuard", 1194: "túnel OpenVPN", 500: "túnel IPsec", 4500: "túnel IPsec"]

    var tunnel: String? { proto == "udp" ? GameFlow.portNames[port] : nil }

    nonisolated static func lastHop(_ out: String) -> (hop: Int, ip: String, ms: Double)? {
        let row = try! NSRegularExpression(pattern: #"^\s*(\d+)\s+(\S+)\s+([\d.]+) ms"#)
        var best: (hop: Int, ip: String, ms: Double)?
        for line in out.components(separatedBy: "\n") {
            guard let m = row.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let h = Range(m.range(at: 1), in: line).flatMap({ Int(line[$0]) }),
                  let ip = Range(m.range(at: 2), in: line).map({ String(line[$0]) }),
                  let t = Range(m.range(at: 3), in: line).flatMap({ Double(line[$0]) }) else { continue }
            best = (h, ip, t)
        }
        return best
    }

    nonisolated static func summary(trace out: String) -> String {
        guard let last = lastHop(out) else { return "No responde a ping ni a la ruta. Probablemente bloquea todo lo que no es de su juego." }
        return "No responde a ping, pero el camino llega hasta el salto \(last.hop) en \(ms(last.ms)) ms. Es lo más cerca que se puede medir; el servidor está unos milisegundos más allá."
    }

    nonisolated static func summary(ping out: String) -> String {
        guard let r = out.range(of: #"= [\d.]+/[\d.]+/[\d.]+/[\d.]+ ms"#, options: .regularExpression) else {
            return "No responde a ping. Muchos servidores de juego lo bloquean: no sirve para medir."
        }
        let v = String(out[r]).replacingOccurrences(of: "= ", with: "").replacingOccurrences(of: " ms", with: "").split(separator: "/").compactMap { Double($0) }
        let loss = out.range(of: #"[\d.]+(?=% packet loss)"#, options: .regularExpression).map { String(out[$0]) } ?? "0"
        guard v.count >= 3 else { return "Respuesta ilegible." }
        return "\(ms(v[1])) ms de promedio · mínimo \(ms(v[0])) · máximo \(ms(v[2])) · pérdida \(loss.replacingOccurrences(of: ".", with: ","))%"
    }
}

struct DNSResult: Identifiable {
    let name: String
    let ips: [String]
    let warm: Double?
    let cold: Double?
    let answered: Int
    let total: Int
    let router: Bool
    var ip: String { ips[0] }
    var id: String { ip }
    var score: Double? { cold ?? warm }
}

enum DNSProbe {
    nonisolated static let names = ["pubgmobile.com", "tencent.com", "krafton.com", "apple.com", "google.com"]
    nonisolated static let coldBases = ["pubgmobile.com", "tencent.com", "apple.com"]
    nonisolated static let providers: [(name: String, ips: [String])] = [
        ("Cloudflare", ["1.1.1.1", "1.0.0.1"]), ("Google", ["8.8.8.8", "8.8.4.4"]), ("Quad9", ["9.9.9.9", "149.112.112.112"]),
        ("OpenDNS", ["208.67.222.222", "208.67.220.220"]), ("AdGuard", ["94.140.14.14", "94.140.15.15"]),
    ]

    nonisolated static func queryMs(_ out: String) -> Double? {
        out.range(of: #"(?<=Query time: )\d+(?= msec)"#, options: .regularExpression).flatMap { Double(out[$0]) }
    }

    nonisolated static func status(_ out: String) -> String {
        out.range(of: #"(?<=status: )[A-Z]+"#, options: .regularExpression).map { String(out[$0]) } ?? ""
    }

    nonisolated static func isOk(_ status: String) -> Bool { status == "NOERROR" || status == "NXDOMAIN" }

    nonisolated static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    nonisolated static func ask(_ server: String, _ name: String) -> Double? {
        let out = shell("dig +tries=1 +time=2 +noall +comments +stats @\(q(server)) \(q(name)) 2>/dev/null")
        return isOk(status(out)) ? queryMs(out) : nil
    }

    nonisolated static func measure(_ server: String) -> (warm: Double?, cold: Double?, ok: Int) {
        var warm: [Double] = [], cold: [Double] = []
        for name in names {
            _ = ask(server, name)
            if let t = ask(server, name) { warm.append(t) }
        }
        for base in coldBases {
            if let t = ask(server, "tp\(Int.random(in: 100_000...999_999)).\(base)") { cold.append(t) }
        }
        return (median(warm), median(cold), warm.count)
    }

    nonisolated static func measureAll(_ servers: [String]) -> [(warm: Double?, cold: Double?, ok: Int)] {
        let lock = NSLock()
        var out = [(warm: Double?, cold: Double?, ok: Int)](repeating: (nil, nil, 0), count: servers.count)
        DispatchQueue.concurrentPerform(iterations: servers.count) { i in
            let r = measure(servers[i])
            lock.lock()
            out[i] = r
            lock.unlock()
        }
        return out
    }

    nonisolated static func currentServers() -> [String] {
        var out: [String] = []
        var inFirst = false
        for line in shell("scutil --dns 2>/dev/null").components(separatedBy: "\n") {
            if line.hasPrefix("resolver #1") { inFirst = true; continue }
            if line.hasPrefix("resolver #") { break }
            guard inFirst, line.contains("nameserver["), let ip = line.components(separatedBy: " : ").last?.trimmingCharacters(in: .whitespaces), !out.contains(ip) else { continue }
            out.append(ip)
        }
        return Array(out.prefix(8))
    }

    nonisolated static func gateway() -> String? {
        shell("route -n get default 2>/dev/null").components(separatedBy: "\n").first { $0.contains("gateway:") }
            .flatMap { $0.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) }
    }

    nonisolated static func parseServiceOrder(_ text: String, device: String) -> String? {
        let head = try! NSRegularExpression(pattern: #"^\((?:\d+|\*)\) (.+)$"#)
        var name = ""
        for line in text.components(separatedBy: "\n") {
            if let m = head.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let r = Range(m.range(at: 1), in: line) { name = String(line[r]) }
            if line.contains("Device: \(device))"), !name.isEmpty { return name }
        }
        return nil
    }

    nonisolated static func activeService() -> String? {
        guard let dev = shell("route -n get default 2>/dev/null").components(separatedBy: "\n").first(where: { $0.contains("interface:") })?
            .components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces), !dev.isEmpty else { return nil }
        return parseServiceOrder(shell("networksetup -listnetworkserviceorder 2>/dev/null"), device: dev)
    }

    nonisolated static func manualServers(_ service: String) -> [String] {
        shell("networksetup -getdnsservers \(q(service)) 2>/dev/null").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("There aren't") }
    }
}

struct KnownIP: Codable, Identifiable {
    let proto: String
    let ip: String
    let port: Int
    var bytes: Int64
    var first: Date
    var last: Date
    var source: String? = nil
    var id: String { "\(proto)-\(ip)-\(port)" }
}

extension GameLink {
    nonisolated static func loadKnown() -> [KnownIP] {
        UserDefaults.standard.data(forKey: "gameKnownIPs").flatMap { try? JSONDecoder().decode([KnownIP].self, from: $0) } ?? []
    }

    nonisolated static func merge(_ list: [KnownIP], with flows: [GameFlow], at now: Date) -> [KnownIP] {
        var out = list
        for f in flows {
            let id = "\(f.proto)-\(f.ip)-\(f.port)"
            if let i = out.firstIndex(where: { $0.id == id }) {
                out[i].bytes += f.bytes
                out[i].last = now
            } else {
                out.append(KnownIP(proto: f.proto, ip: f.ip, port: f.port, bytes: f.bytes, first: now, last: now))
            }
        }
        return Array(out.sorted { $0.last > $1.last }.prefix(200))
    }

    nonisolated static func ipsetText(_ list: [KnownIP]) -> String {
        let v4 = Set(list.filter { !$0.ip.contains(":") }.map(\.ip)).sorted(), v6 = Set(list.filter { $0.ip.contains(":") }.map(\.ip)).sorted()
        var out: [String] = []
        if !v4.isEmpty { out += ["ipset create pubg4 hash:ip family inet -exist"] + v4.map { "ipset add pubg4 \($0) -exist" } }
        if !v6.isEmpty { out += ["ipset create pubg6 hash:ip family inet6 -exist"] + v6.map { "ipset add pubg6 \($0) -exist" } }
        return out.joined(separator: "\n")
    }

    nonisolated static func allowedIPsText(_ list: [KnownIP]) -> String {
        Set(list.map { $0.ip.contains(":") ? "\($0.ip)/128" : "\($0.ip)/32" }).sorted().joined(separator: ", ")
    }

    func remember(_ found: [GameFlow]) {
        knownIPs = GameLink.merge(knownIPs, with: found, at: Date())
        if let d = try? JSONEncoder().encode(knownIPs) { UserDefaults.standard.set(d, forKey: "gameKnownIPs") }
    }

    func forgetKnown() {
        knownIPs = []
        UserDefaults.standard.removeObject(forKey: "gameKnownIPs")
    }

    nonisolated static func parseNDP(_ text: String) -> [(addr: String, mac: String)] {
        text.components(separatedBy: "\n").compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 3, f[2] == "bridge100", f[0].lowercased().hasPrefix("fd"), !line.contains("permanent"), !line.contains("(incomplete)"),
                  let mac = GameLink.normalizeMAC(f[1]) else { return nil }
            return (f[0].lowercased(), mac)
        }
    }

    nonisolated static func others(peers: [Peer], ndp: [(addr: String, mac: String)], ipadMAC: String) -> [String] {
        var out: [String] = []
        for p in peers {
            guard let mac = normalizeMAC(p.mac), mac != ipadMAC, p.id != "192.168.2.1" else { continue }
            out.append(p.id)
        }
        for n in ndp where n.mac != ipadMAC && !out.contains(n.addr) { out.append(n.addr) }
        return Array(out.prefix(16))
    }

    nonisolated static func ipadAddresses(ipadID: String?, ipadMAC: String?, ndp: [(addr: String, mac: String)]) -> [String] {
        var out: [String] = []
        if let ipadID, ipadID.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil { out.append(ipadID) }
        if let ipadMAC { for n in ndp where n.mac == ipadMAC && !out.contains(n.addr) { out.append(n.addr) } }
        return Array(out.prefix(4))
    }

    func currentIPadAddresses() -> [String] {
        guard let ipad = activePeer, let mac = GameLink.normalizeMAC(ipad.mac) else { return [] }
        return GameLink.ipadAddresses(ipadID: ipad.id, ipadMAC: mac, ndp: GameLink.parseNDP(shell("ndp -an 2>/dev/null")))
    }

    func refreshLimit(interactive: Bool) async {
        guard exclusive, session != nil, let ipad = activePeer, let ipadMAC = GameLink.normalizeMAC(ipad.mac) else {
            if !exclusive { await dropLimit() }
            return
        }
        let current = peers
        let ndp = await Task.detached { GameLink.parseNDP(shell("ndp -an 2>/dev/null")) }.value
        guard session != nil else { return }
        let targets = GameLink.others(peers: current.filter { $0.id != ipad.id }, ndp: ndp, ipadMAC: ipadMAC)
        let signature = "\(exclusiveMbit)|" + targets.joined(separator: ",")
        guard signature != lastLimit else { return }
        if targets.isEmpty {
            await dropLimit()
            limitNote = "No hay otros equipos conectados: nada que limitar."
            lastLimit = signature
            return
        }
        let run = qosRunner, mbit = exclusiveMbit
        let ok = await Task.detached { run(["apply", String(mbit)] + targets, interactive) }.value
        if ok, session == nil {
            // the session ended while the rules were being applied: take them back out
            UserDefaults.standard.set(true, forKey: "gameQosHeld")
            await dropLimit(force: true)
            return
        }
        if ok {
            lastLimit = signature
            limited = targets
            UserDefaults.standard.set(true, forKey: "gameQosHeld")
            limitNote = "\(plural(targets.count, "dirección", "direcciones")) de otros equipos limitadas a \(mbit) Mbit/s. El iPad no tiene límite."
        } else if interactive {
            limitNote = "No pude limitar a los demás equipos: el ayudante no recibió permiso."
        }
    }

    /// `force` re-runs the idempotent clear even when the app believes nothing is held: at launch without a session, no limiter should exist.
    func dropLimit(force: Bool = false) async {
        guard force || UserDefaults.standard.bool(forKey: "gameQosHeld") || !limited.isEmpty else { return }
        let run = qosRunner
        if await Task.detached(operation: { run(["clear"], false) }).value {
            UserDefaults.standard.set(false, forKey: "gameQosHeld")
            limited = []
            lastLimit = ""
            limitNote = ""
        }
    }

    nonisolated static func normalizeMAC(_ s: String) -> String? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6, parts.allSatisfy({ (1...2).contains($0.count) && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        return parts.map { $0.count == 1 ? "0" + $0 : String($0) }.joined(separator: ":").lowercased()
    }

    func findServer(auto: Bool = false) async {
        guard let peer = activePeer else {
            if !auto { flowsNote = "No hay un iPad conectado al Wi-Fi compartido." }
            return
        }
        guard let mac = GameLink.normalizeMAC(peer.mac) else {
            if !auto { flowsNote = "No pude leer la dirección física del iPad." }
            return
        }
        guard !flowsBusy else { return }
        flowsBusy = true
        defer { flowsBusy = false }
        let reader = flowsReader
        let seconds = auto ? 5 : flowsSeconds
        guard let text = await Task.detached(operation: { reader(mac, seconds, !auto) }).value else {
            if !auto { flowsNote = "No pude leer el tráfico: el ayudante no recibió permiso." }
            return
        }
        let found = GameFlow.parse(text)
        if found.isEmpty {
            if !auto || flows.isEmpty { flowsNote = "No vi tráfico del iPad hacia internet en \(seconds) s. Abre el juego, entra a una partida y vuelve a buscar mientras juegas." }
            return
        }
        flows = found
        remember(found)
        flowsNote = ""
        flowsAt = Date()
        if !auto { probes = [:] }
    }

    func probe(_ flow: GameFlow) async {
        guard GameLink.validTarget(flow.ip) else { return }
        probes[flow.ip] = "Probando…"
        let ip = flow.ip
        let out = await Task.detached { shell((ip.contains(":") ? "/sbin/ping6 -c 6 -i 0.2 " : "/sbin/ping -c 6 -i 0.2 -W 1000 ") + q(ip) + " 2>&1") }.value
        guard !out.contains("round-trip") else {
            probes[flow.ip] = GameFlow.summary(ping: out)
            return
        }
        probes[flow.ip] = "No responde a ping. Midiendo el camino…"
        let trace = await Task.detached { shell((ip.contains(":") ? "/usr/sbin/traceroute6" : "/usr/sbin/traceroute") + " -n -w 1 -q 1 -m 16 " + q(ip) + " 2>&1") }.value
        probes[flow.ip] = GameFlow.summary(trace: trace)
    }

    func testDNS() async {
        dnsBusy = true
        defer { dnsBusy = false }
        dnsNote = ""
        let found = await Task.detached { () -> ([String], [DNSResult]) in
            let current = DNSProbe.currentServers()
            var specs: [(String, [String], Bool)] = []
            if let gw = DNSProbe.gateway() { specs.append(("Tu router", [gw], true)) }
            for p in DNSProbe.providers { specs.append((p.name, p.ips, false)) }
            for ip in current where !specs.contains(where: { $0.1.contains(ip) }) { specs.append(("DNS que ya usas", [ip], false)) }
            let measured = DNSProbe.measureAll(specs.map { $0.1[0] })
            let results = zip(specs, measured).map { DNSResult(name: $0.0, ips: $0.1, warm: $1.warm, cold: $1.cold, answered: $1.ok, total: DNSProbe.names.count, router: $0.2) }
            return (current, results)
        }.value
        dnsCurrent = found.0
        dnsResults = found.1.sorted { ($0.score ?? .infinity) < ($1.score ?? .infinity) }
    }

    func useDNS(_ ips: [String]) async {
        guard let service = await Task.detached(operation: { DNSProbe.activeService() }).value else {
            dnsNote = "No pude saber qué conexión usa tu Mac para salir a internet."
            return
        }
        let previous = await Task.detached { DNSProbe.manualServers(service) }.value
        let run = dnsRunner
        guard await Task.detached(operation: { run(["set", service] + ips) }).value else {
            dnsNote = "No pude cambiar el DNS: el ayudante no recibió permiso."
            return
        }
        var saved = UserDefaults.standard.dictionary(forKey: "dnsPrevious") as? [String: [String]] ?? [:]
        if saved[service] == nil { saved[service] = previous }
        UserDefaults.standard.set(saved, forKey: "dnsPrevious")
        try? await Task.sleep(for: .milliseconds(700))
        dnsCurrent = await Task.detached { DNSProbe.currentServers() }.value
        dnsNote = "DNS de la Mac cambiado a \(ips.joined(separator: ", ")). Puedes volver al anterior."
        record("DNS de la Mac (\(service)): \(previous.isEmpty ? "automático" : previous.joined(separator: ", ")) → \(ips.joined(separator: ", "))")
    }

    func restoreDNS() async {
        guard let service = await Task.detached(operation: { DNSProbe.activeService() }).value,
              let saved = (UserDefaults.standard.dictionary(forKey: "dnsPrevious") as? [String: [String]])?[service] else {
            dnsNote = "No hay un DNS anterior guardado."
            return
        }
        let run = dnsRunner
        guard await Task.detached(operation: { run(saved.isEmpty ? ["reset", service] : ["set", service] + saved) }).value else {
            dnsNote = "No pude volver al DNS anterior: el ayudante no recibió permiso."
            return
        }
        var all = UserDefaults.standard.dictionary(forKey: "dnsPrevious") as? [String: [String]] ?? [:]
        all[service] = nil
        UserDefaults.standard.set(all, forKey: "dnsPrevious")
        try? await Task.sleep(for: .milliseconds(700))
        dnsCurrent = await Task.detached { DNSProbe.currentServers() }.value
        dnsNote = "DNS de la Mac de vuelta a \(saved.isEmpty ? "automático" : saved.joined(separator: ", "))."
        record("DNS de la Mac (\(service)) restaurado a \(saved.isEmpty ? "automático" : saved.joined(separator: ", "))")
    }

    var canRestoreDNS: Bool { !(UserDefaults.standard.dictionary(forKey: "dnsPrevious") ?? [:]).isEmpty }
}

struct GameServerCard: View {
    @ObservedObject var g: GameLink

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Servidor de tu juego").font(.headline)
            Text("Escucha unos segundos lo que manda el iPad, sin leer el contenido. Con tu túnel solo verás la IP del túnel; las del juego salen en la pestaña Túnel.")
                .font(.callout).foregroundStyle(.secondary).lineLimit(3)
            Text(g.autoServer ? "Mientras juegas se actualiza solo. Puedes apagarlo en Tweaks." : "La detección automática está apagada en Tweaks.").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button { Task { await g.findServer() } } label: { Label(g.flowsBusy ? "Escuchando…" : "Buscar ahora", systemImage: "scope") }
                    .disabled(g.flowsBusy || g.activePeer == nil)
                    .help("Escucha el tráfico del iPad durante el tiempo elegido. Usa el ayudante de administrador: no pide contraseña si ya está activado")
                Picker("", selection: $g.flowsSeconds) {
                    Text("5 s").tag(5)
                    Text("10 s").tag(10)
                    Text("15 s").tag(15)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 130)
                .help("Cuánto escucha. Si el juego manda poco, elige más tiempo")
            }
            if g.flowsBusy { ProgressView().controlSize(.small) }
            if !g.flowsNote.isEmpty { Text(g.flowsNote).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            let likely = GameFlow.likely(g.flows)
            ForEach(g.flows) { f in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(f.proto.uppercased()).font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(f.proto == "udp" ? Color.brandTeal.opacity(0.25) : Color.secondary.opacity(0.2)))
                        Text(f.ip.contains(":") ? "[\(f.ip)]:\(f.port)" : "\(f.ip):\(f.port)").font(.callout.monospacedDigit()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        if let t = f.tunnel {
                            Text(t).font(.caption).foregroundStyle(.orange)
                                .help("Tu partida va dentro de un túnel VPN. Esta IP es el servidor de tu VPN, no el del juego: el camino hasta ella cuenta en tu ping")
                        } else if f.id == likely { Text("suele ser la partida").font(.caption).foregroundStyle(Color.brandTeal) }
                        Spacer()
                        Text(formatBytes(f.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Button("Probar") { Task { await g.probe(f) } }.controlSize(.small)
                            .help("Manda 6 pings a esta IP y, si no contesta, mide el camino hasta su red")
                        Button("Usar de destino") { _ = g.useTarget(f.ip) }.controlSize(.small)
                            .disabled(g.destino == f.ip)
                            .help("El ping en vivo pasa a medir contra esta IP. Si no contesta a ping, la app vuelve sola a Cloudflare")
                    }
                    if let r = g.probes[f.ip] { Text(r).font(.caption).foregroundStyle(.secondary).lineLimit(4) }
                }
            }
            if !g.flows.isEmpty {
                Text("La de más tráfico UDP suele ser la partida: es una regla práctica, no una garantía. El juego usa varias IP (lobby, partida, voz).")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(16)
    }
}

struct GameDNSCard: View {
    @ObservedObject var g: GameLink
    @State private var pending: DNSResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DNS: elegir y probar").font(.headline)
            Text("El DNS traduce nombres a IP al entrar al lobby o a la partida. No cambia el ping dentro de la partida; acelera conectar. Se prueban 5 nombres del juego ya guardados en caché y 3 nombres nuevos, que es lo que cuesta de verdad.")
                .font(.callout).foregroundStyle(.secondary).lineLimit(5)
            HStack(spacing: 8) {
                Button { Task { await g.testDNS() } } label: { Label(g.dnsBusy ? "Probando…" : "Probar DNS", systemImage: "speedometer") }
                    .disabled(g.dnsBusy)
                    .help("Pregunta lo mismo a cada servidor al mismo tiempo y mide cuánto tarda cada respuesta")
                if g.canRestoreDNS { Button("Volver al DNS anterior") { Task { await g.restoreDNS() } }.help("Deja el DNS de la Mac exactamente como estaba antes de cambiarlo aquí") }
            }
            if !g.dnsCurrent.isEmpty { Text("DNS actual de la Mac: \(g.dnsCurrent.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            if !g.dnsNote.isEmpty { Text(g.dnsNote).font(.caption.weight(.medium)).foregroundStyle(Color.brandTeal).lineLimit(3) }
            let best = g.dnsResults.first { !$0.router && $0.score != nil }?.ip
            ForEach(g.dnsResults) { r in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(r.name).fontWeight(.medium)
                        Text(r.ips.joined(separator: " · ")).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        if g.dnsCurrent.contains(r.ip) { Text("en uso").font(.caption).foregroundStyle(Color.brandTeal) }
                        if r.ip == best { Text("el mejor").font(.caption).foregroundStyle(.green) }
                        Spacer()
                        Button("Usar") { pending = r }.controlSize(.small).disabled(r.score == nil || g.dnsCurrent.first == r.ip)
                            .help(r.router ? "Usa el DNS de tu router (el de tu proveedor). Reemplaza los que tienes ahora" : "Pone estos \(r.ips.count) servidores como DNS de la Mac")
                    }
                    if let w = r.warm {
                        Text("En caché \(ms(w)) ms" + (r.cold.map { " · nombre nuevo \(ms($0)) ms" } ?? " · nombres nuevos sin respuesta")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } else {
                        Text("Sin respuesta").font(.caption).foregroundStyle(.red)
                    }
                    Meter(value: (r.score ?? 200) / 200, tint: r.score == nil ? .red : (r.score ?? 0) < 40 ? .green : .orange, height: 4)
                }
            }
            if !g.dnsResults.isEmpty {
                Text("Tu router parece rapidísimo porque responde desde su propia caché, a un salto de ti. Fíate de «nombre nuevo»: es lo que tarda cuando el router tiene que preguntar afuera. La Mac le reenvía sus consultas al iPad por 192.168.2.1, así que normalmente el iPad usa el mismo DNS.")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(6)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(16)
        .confirmationDialog(pending.map { "La Mac usa ahora: \(g.dnsCurrent.joined(separator: ", ")). Pasará a \($0.name): \($0.ips.joined(separator: ", ")). Puedes volver con «Volver al DNS anterior»." } ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Cambiar DNS") {
                if let r = pending { Task { await g.useDNS(r.ips) } }
                pending = nil
            }
        }
    }
}

struct GameIPsCard: View {
    @ObservedObject var g: GameLink

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mis IP del juego").font(.headline)
            Text("Aquí se guardan las IP a las que el iPad manda datos.")
                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            if g.knownIPs.isEmpty {
                Text("Todavía no hay ninguna. Aparecen solas mientras juegas.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(g.knownIPs.prefix(12)) { k in
                HStack(spacing: 8) {
                    Text(k.proto.uppercased()).font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(k.proto == "udp" ? Color.brandTeal.opacity(0.25) : Color.secondary.opacity(0.2)))
                    Text(k.ip.contains(":") ? "[\(k.ip)]:\(k.port)" : "\(k.ip):\(k.port)").font(.callout.monospacedDigit()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    if let t = GameFlow.portNames[k.port], k.proto == "udp" { Text(t).font(.caption).foregroundStyle(.orange) }
                    Spacer()
                    Text(formatBytes(k.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(k.last.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Button { copy(GameLink.ipsetText(g.knownIPs)) } label: { Label("Copiar como ipset", systemImage: "doc.on.clipboard") }
                    .disabled(g.knownIPs.isEmpty)
                    .help("Comandos ipset de Linux, uno para IPv4 y otro para IPv6, listos para pegar en tu servidor")
                Button { copy(GameLink.allowedIPsText(g.knownIPs)) } label: { Label("Copiar para WireGuard", systemImage: "network") }
                    .disabled(g.knownIPs.isEmpty)
                    .help("Lista de direcciones con /32 y /128, lista para el campo AllowedIPs de WireGuard")
                Button("Borrar lista") { g.forgetKnown() }.disabled(g.knownIPs.isEmpty)
                    .help("Olvida todas las IP guardadas")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(16)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
