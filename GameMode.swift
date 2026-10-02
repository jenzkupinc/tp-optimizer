import SwiftUI
import AppKit

struct Peer: Identifiable, Hashable {
    let id: String
    let name: String
    let mac: String
    var symbol: String { name.localizedCaseInsensitiveContains("ipad") ? "ipad" : name.localizedCaseInsensitiveContains("iphone") ? "iphone" : "laptopcomputer" }
}

struct NetHog: Identifiable {
    var id: Int32 { pid }
    let pid: Int32
    let name: String
    let rate: Double
}

struct Quality {
    let rpm: Double, baseRTT: Double, down: Double, up: Double
    var loaded: Double { rpm > 0 ? 60_000 / rpm : 0 }
}

struct Series {
    private(set) var values: [Double?] = []
    let capacity: Int
    init(capacity: Int) { self.capacity = capacity }
    mutating func add(_ v: Double?) {
        values.append(v)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }
    var got: [Double] { values.compactMap { $0 } }
    var avg: Double { let g = got; return g.isEmpty ? 0 : g.reduce(0, +) / Double(g.count) }
    var jitter: Double {
        let g = got
        guard g.count > 1 else { return 0 }
        let m = avg
        return (g.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(g.count)).squareRoot()
    }
    var peak: Double { got.max() ?? 0 }
    func percentile(_ p: Double) -> Double { Series.percentile(got, p) }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let g = values.sorted()
        return g.isEmpty ? 0 : g[min(g.count - 1, max(0, Int((Double(g.count) * p).rounded(.up)) - 1))]
    }
    var spikes: Int { got.filter { $0 > 20 }.count }
    var lossPct: Double { values.isEmpty ? 0 : Double(values.filter { $0 == nil }.count) / Double(values.count) * 100 }
    var last: Double? { values.last.flatMap { $0 } }
}

struct Acc {
    var n = 0, lost = 0, spikes = 0
    var sum = 0.0, sumSq = 0.0, peak = 0.0
    mutating func add(_ v: Double?) {
        guard let v else { lost += 1; return }
        n += 1
        sum += v
        sumSq += v * v
        peak = max(peak, v)
        if v > 20 { spikes += 1 }
    }
    var avg: Double { n > 0 ? sum / Double(n) : 0 }
    var jitter: Double { n > 1 ? max(0, sumSq / Double(n) - avg * avg).squareRoot() : 0 }
    var lossPct: Double { n + lost > 0 ? Double(lost) / Double(n + lost) * 100 : 0 }
}

enum IPadState { case waiting, awake, absent }

struct Spike: Identifiable {
    let id = UUID()
    let at: Date
    let ms: Double
    let awdl: Bool
}

struct Session {
    let start: Date
    var relieved: [String]
    var resumed: Date?
    var local = Acc()
    var play = Acc()
    var net = Acc()
}

final class PingStream {
    private let process = Process()
    private let lock = NSLock()
    private var pending: [Double?] = []
    private var carry = ""

    init?(target: String, interval: String) {
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", PingStream.script, "tp-ping", String(getpid()), interval, target]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let self else { return }
            self.lock.lock()
            self.carry += String(decoding: data, as: UTF8.self)
            var lines = self.carry.components(separatedBy: "\n")
            self.carry = lines.removeLast()
            self.pending += lines.compactMap { PingStream.parse($0) }
            if self.pending.count > 2400 { self.pending.removeFirst(self.pending.count - 2400) }
            self.lock.unlock()
        }
        do { try process.run() } catch { return nil }
    }

    static let script = "trap 'kill $P 2>/dev/null; exit 0' TERM INT HUP; case \"$3\" in *:*) C=/sbin/ping6;; *) C=/sbin/ping;; esac; $C -i \"$2\" \"$3\" & P=$!; while kill -0 \"$1\" 2>/dev/null && kill -0 $P 2>/dev/null; do sleep 1; done; kill $P 2>/dev/null"

    static func parse(_ line: String) -> Double?? {
        if line.hasPrefix("Request timeout") { return .some(nil) }
        guard let r = line.range(of: "time=") else { return nil }
        guard let v = Double(line[r.upperBound...].prefix { $0.isNumber || $0 == "." }) else { return nil }
        return .some(v)
    }

    func take() -> [Double?] {
        lock.lock()
        defer { lock.unlock() }
        let out = pending
        pending = []
        return out
    }

    func stop() {
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    deinit { stop() }
}

@MainActor
final class GameLink: ObservableObject {
    nonisolated static let defaultTarget = "1.1.1.1"
    nonisolated static let window = 1200
    nonisolated static let activeMbit = 0.15

    nonisolated static func isActive(mbit: Double) -> Bool { mbit > activeMbit }

    nonisolated static let v6Target = "2606:4700:4700::1111"

    nonisolated static func validTarget(_ s: String) -> Bool {
        if s.contains(":") { return s.count <= 39 && s.filter { $0 == ":" }.count >= 2 && s.range(of: #"^[0-9A-Fa-f:]+$"#, options: .regularExpression) != nil }
        return s.count <= 253 && s.range(of: #"^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$"#, options: .regularExpression) != nil
    }

    nonisolated static func loadHistory() -> [PastSession] {
        UserDefaults.standard.data(forKey: "gameHistory").flatMap { try? JSONDecoder().decode([PastSession].self, from: $0) } ?? []
    }

    nonisolated static func isRhythmic(_ times: [Date]) -> Bool {
        var events: [Date] = []
        for t in times.sorted() where events.last.map({ t.timeIntervalSince($0) > 1 }) ?? true { events.append(t) }
        guard events.count >= 6 else { return false }
        let gaps = zip(events, events.dropFirst()).map { $1.timeIntervalSince($0) }
        let mean = gaps.reduce(0, +) / Double(gaps.count)
        guard mean >= 0.5, mean <= 10 else { return false }
        let sd = (gaps.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(gaps.count)).squareRoot()
        return sd / mean < 0.35
    }
    nonisolated static let sessionKey = "gameSession"
    nonisolated static let resumeWithin: TimeInterval = 12 * 3600
    @Published private(set) var sharing = false
    @Published private(set) var peers: [Peer] = []
    @Published private(set) var channel = ""
    private var channelBusy = false
    @Published private(set) var ssid = ""
    @Published private(set) var awdl = false
    @Published private(set) var local = Series(capacity: GameLink.window)
    @Published private(set) var net = Series(capacity: 120)
    @Published private(set) var down = 0.0
    @Published private(set) var up = 0.0
    @Published private(set) var hogs: [NetHog] = []
    @Published private(set) var session: Session?
    @Published private(set) var silenced: Set<Int32> = []
    @Published private(set) var quality: Quality?
    @Published private(set) var loadNote = ""
    @Published private(set) var ipad = IPadState.waiting
    @Published private(set) var spikeLog: [Spike] = []
    @Published private(set) var newcomer: Peer?
    @Published var lockChecked: Bool = UserDefaults.standard.bool(forKey: "gameLockChecked") { didSet { UserDefaults.standard.set(lockChecked, forKey: "gameLockChecked") } }
    @Published private(set) var measuring = false
    @Published private(set) var note = ""
    @Published private(set) var destino = UserDefaults.standard.string(forKey: "gameTarget").flatMap { GameLink.validTarget($0) ? $0 : nil } ?? GameLink.defaultTarget
    @Published private(set) var awdlHeld = UserDefaults.standard.bool(forKey: "gameAwdlHeld")
    @Published private(set) var awdlRetakes = 0
    @Published private(set) var labRunning = false
    @Published private(set) var labPhase = 0
    @Published private(set) var labLeft = 0
    @Published private(set) var labNormal = LabArm()
    @Published private(set) var labOff = LabArm()
    @Published private(set) var labVerdict: LabVerdict?
    @Published private(set) var playSteps: [PlayStep] = []
    @Published private(set) var juegoPID: Int?
    @Published var autoPlay: Bool = UserDefaults.standard.bool(forKey: "gameAutoPlay") {
        didSet { UserDefaults.standard.set(autoPlay, forKey: "gameAutoPlay") }
    }
    @Published private(set) var autoNote = ""
    private var autoStarted = false
    private var gameStreak = 0
    private var lastGame: Date?
    static let autoEndAfter: TimeInterval = 600
    @Published private(set) var air: AirSettings?
    @Published private(set) var history = GameLink.loadHistory()
    @Published var awdlDuringGame: Bool = UserDefaults.standard.bool(forKey: "gameAwdlOff") {
        didSet {
            UserDefaults.standard.set(awdlDuringGame, forKey: "gameAwdlOff")
            guard session != nil, oldValue != awdlDuringGame else { return }
            Task { await setAwdl(down: awdlDuringGame, interactive: true) }
        }
    }
    var labSeconds = 90.0
    @Published var flows: [GameFlow] = []
    @Published var flowsBusy = false
    @Published var flowsNote = ""
    @Published var probes: [String: String] = [:]
    @Published var dnsResults: [DNSResult] = []
    @Published var dnsBusy = false
    @Published var dnsNote = ""
    @Published var dnsCurrent: [String] = []
    @Published var flowsAt: Date?
    @Published var knownIPs: [KnownIP] = GameLink.loadKnown()
    @Published var limited: [String] = []
    @Published var limitNote = ""
    @Published var exclusive: Bool = UserDefaults.standard.bool(forKey: "gameExclusive") {
        didSet {
            UserDefaults.standard.set(exclusive, forKey: "gameExclusive")
            guard session != nil, oldValue != exclusive else { return }
            Task { await refreshLimit(interactive: true) }
        }
    }
    @Published var exclusiveMbit: Int = [5, 10, 20, 50].contains(UserDefaults.standard.integer(forKey: "gameExclusiveMbit")) ? UserDefaults.standard.integer(forKey: "gameExclusiveMbit") : 20 {
        didSet {
            UserDefaults.standard.set(exclusiveMbit, forKey: "gameExclusiveMbit")
            if exclusive, session != nil { lastLimit = ""; Task { await refreshLimit(interactive: true) } }
        }
    }
    @Published var autoSilence: Bool = UserDefaults.standard.object(forKey: "gameAutoSilence") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSilence, forKey: "gameAutoSilence") }
    }
    @Published var lowerPriority: Bool = UserDefaults.standard.object(forKey: "gameLowerPriority") as? Bool ?? true {
        didSet { UserDefaults.standard.set(lowerPriority, forKey: "gameLowerPriority") }
    }
    @Published var pauseBackup: Bool = UserDefaults.standard.object(forKey: "gamePauseBackup") as? Bool ?? true {
        didSet { UserDefaults.standard.set(pauseBackup, forKey: "gamePauseBackup") }
    }
    var backupRunner: @Sendable () -> BackupOutcome = { GameLink.stopBackupIfRunning() }
    weak var monitor: Monitor?
    var qosRunner: @Sendable ([String], Bool) -> Bool = { args, interactive in
        interactive ? Root.run(["qos"] + args) : Root.runQuiet(["qos"] + args)
    }
    @Published var destinoNote = ""
    @Published var lan = Series(capacity: 120)
    @Published var net6 = Series(capacity: 120)
    @Published var uplink = ""
    @Published var autoServer: Bool = UserDefaults.standard.object(forKey: "gameAutoServer") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoServer, forKey: "gameAutoServer") }
    }
    @Published var flowsSeconds: Int = [5, 10, 15].contains(UserDefaults.standard.integer(forKey: "gameFlowsSeconds")) ? UserDefaults.standard.integer(forKey: "gameFlowsSeconds") : 5 {
        didSet { UserDefaults.standard.set(flowsSeconds, forKey: "gameFlowsSeconds") }
    }
    var flowsReader: @Sendable (String, Int, Bool) -> String? = { Root.read(["flows", $0, String($1)], prompt: $2) }
    var dnsRunner: @Sendable ([String]) -> Bool = { Root.run(["dns"] + $0) }
    var awdlRunner: @Sendable (_ down: Bool, _ interactive: Bool) -> Bool = { down, interactive in
        interactive ? Root.run(["awdl", down ? "down" : "up"]) : Root.runQuiet(["awdl", down ? "down" : "up"])
    }
    @Published var keepAwake: Bool = UserDefaults.standard.object(forKey: "gameKeepAwake") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(keepAwake, forKey: "gameKeepAwake")
            streamTarget = nil
            syncLocal()
        }
    }
    @Published var peerID: String? = UserDefaults.standard.string(forKey: "gamePeer") {
        didSet {
            UserDefaults.standard.set(peerID, forKey: "gamePeer")
            syncLocal()
        }
    }

    var pauseWhenHidden = true
    private var viewers = 0
    private var loop: Task<Void, Never>?
    private var localStream: PingStream?
    private var netStream: PingStream?
    private var streamTarget: String?
    private var lastBytes: (up: Double, down: Double, at: Date)?
    private var hogsBusy = false
    private var awake: Process?
    private var lostRun = 0
    private var okRun = 0
    private var loadLocal = Acc()
    private var loadNet = Acc()
    private var netStartedAt = Date()
    private var lanStream: PingStream?
    private var net6Stream: PingStream?
    private var lastAuto = Date.distantPast
    var lastLimit = ""
    private var labTask: Task<Void, Never>?
    private var labCounting: Bool?
    private var labSkipUntil = Date.distantPast
    private var lastRetake = Date.distantPast
    private var known: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "gameKnownMACs") ?? [])
    nonisolated static let socialChannels: Set<Int> = [6, 44, 149]

    var activePeer: Peer? {
        if let p = peers.first(where: { $0.id == peerID }) ?? peers.first(where: { $0.name.localizedCaseInsensitiveContains("ipad") }) { return p }
        // Never guess: with an iPhone or Watch connected and the iPad missing, measuring "the first one" would report the wrong device.
        return peerID == nil && peers.count == 1 ? peers.first : nil
    }

    func watch(_ on: Bool) {
        viewers = max(0, viewers + (on ? 1 : -1))
        refresh()
    }

    private func refresh() {
        if viewers > 0 || session != nil {
            if loop == nil { begin() }
        } else {
            end()
        }
    }

    private func begin() {
        local = Series(capacity: GameLink.window)
        net = Series(capacity: 120)
        spikeLog = []
        lastBytes = nil
        netStream = PingStream(target: destino, interval: "0.5")
        netStartedAt = Date()
        lan = Series(capacity: 120)
        net6 = Series(capacity: 120)
        net6Stream = PingStream(target: GameLink.v6Target, interval: "0.5")
        loop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.step(tick)
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func end() {
        loop?.cancel()
        loop = nil
        localStream?.stop()
        localStream = nil
        netStream?.stop()
        netStream = nil
        lanStream?.stop()
        lanStream = nil
        net6Stream?.stop()
        net6Stream = nil
        streamTarget = nil
    }

    func feedLocal(_ v: Double?) {
        guard keepAwake else { addLocal(v); return }
        guard let v else {
            lostRun += 1
            if lostRun >= 40, ipad != .absent {
                ipad = .absent
                okRun = 0
            }
            return
        }
        if ipad == .awake {
            for _ in 0..<lostRun { addLocal(nil) }
            lostRun = 0
            addLocal(v)
        } else {
            lostRun = 0
            okRun = v < 50 ? okRun + 1 : 0
            if okRun >= 10 {
                ipad = .awake
                okRun = 0
                local = Series(capacity: GameLink.window)
                addLocal(v)
            }
        }
    }

    private func addLocal(_ v: Double?) {
        local.add(v)
        session?.local.add(v)
        if playing { session?.play.add(v) }
        if measuring { loadLocal.add(v) }
        if let down = labCounting, Date() >= labSkipUntil {
            if down { labOff.add(v) } else { labNormal.add(v) }
        }
        if let v, v > 20 {
            spikeLog.append(Spike(at: Date(), ms: v, awdl: awdl))
            if spikeLog.count > 60 { spikeLog.removeFirst(spikeLog.count - 60) }
        }
    }

    private func syncLocal() {
        let want = loop != nil ? activePeer?.id : nil
        guard want != streamTarget else { return }
        localStream?.stop()
        localStream = nil
        streamTarget = want
        ipad = .waiting
        lostRun = 0
        okRun = 0
        local = Series(capacity: GameLink.window)
        if let want { localStream = PingStream(target: want, interval: keepAwake ? "0.05" : "0.2") }
    }

    private func step(_ tick: Int) async {
        for v in localStream?.take() ?? [] { feedLocal(v) }
        for v in netStream?.take() ?? [] {
            net.add(v)
            session?.net.add(v)
            if measuring { loadNet.add(v) }
        }
        if destino != GameLink.defaultTarget, net.got.isEmpty, net.values.count >= 30 || Date().timeIntervalSince(netStartedAt) > 15 {
            let old = destino
            _ = useTarget(GameLink.defaultTarget)
            destinoNote = "\(old) no contesta a ping, así que volví a \(GameLink.defaultTarget). Para ver el camino hasta ese servidor usa «Probar» en la pestaña Red."
        }
        for v in net6Stream?.take() ?? [] { net6.add(v) }
        for v in lanStream?.take() ?? [] { lan.add(v) }
        guard !pauseWhenHidden || NSApp.occlusionState.contains(.visible) || session != nil else { return }

        if let b = await Task.detached(operation: { GameLink.readBytes() }).value {
            let now = Date()
            if let p = lastBytes, now.timeIntervalSince(p.at) > 0.2 {
                let dt = now.timeIntervalSince(p.at)
                up = max(0, (b.up - p.up) / dt)
                down = max(0, (b.down - p.down) / dt)
            }
            lastBytes = (b.up, b.down, now)
        } else {
            up = 0
            down = 0
            lastBytes = nil
        }

        if tick % 5 == 0 { juegoPID = await Task.detached { JuegoLog.scriptPID() }.value }
        if tick % 30 == 3 { air = await Task.detached { AirSettings.read() }.value }
        if tick % 5 == 0 {
            let info = await Task.detached(operation: { GameLink.readPeers() }).value
            sharing = info.sharing
            peers = info.peers
            awdl = info.awdl
            learn()
            syncLocal()
            if exclusive, session != nil { Task { await refreshLimit(interactive: false) } }
            if autoServer, session != nil, ipad == .awake, !flowsBusy, Date().timeIntervalSince(lastAuto) > 25 {
                lastAuto = Date()
                Task { await findServer(auto: true) }
            }
            if awdlHeld, awdl, Date().timeIntervalSince(lastRetake) > 10 {
                lastRetake = Date()
                awdlRetakes += 1
                Task { await setAwdl(down: true, interactive: false) }
            }
        }
        if tick % 30 == 0, session != nil { persist() }
        if tick == 0 {
            Task {
                let gw = await Task.detached(operation: { DNSProbe.gateway() }).value
                uplink = await Task.detached(operation: { DNSProbe.activeService() ?? "" }).value
                if let gw, GameLink.validTarget(gw), loop != nil, lanStream == nil { lanStream = PingStream(target: gw, interval: "0.5") }
            }
        }
        if tick % 30 == 0 { refreshChannel() }
        if autoSilence, session != nil, tick % 4 == 2, let m = monitor { silence(m) }
        if tick % 15 == 3, !hogsBusy {
            hogsBusy = true
            Task {
                hogs = await Task.detached(operation: { GameLink.readHogs() }).value
                hogsBusy = false
            }
        }
    }

    nonisolated static func readBytes() -> (up: Double, down: Double)? {
        for line in shell("netstat -ibn -I bridge100 2>/dev/null").split(separator: "\n") where line.contains("<Link#") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            if f.count >= 10, let ib = Double(f[6]), let ob = Double(f[9]) { return (ib, ob) }
        }
        return nil
    }

    nonisolated static func readPeers() -> (sharing: Bool, peers: [Peer], awdl: Bool) {
        let sharing = shell("ifconfig bridge100 2>/dev/null").contains("inet ")
        let awdl = shell("ifconfig awdl0 2>/dev/null").contains("status: active")
        guard sharing else { return (false, [], awdl) }
        var names: [String: String] = [:]
        var name = "", ip = ""
        for raw in ((try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8)) ?? "").split(separator: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("name=") { name = String(l.dropFirst(5)) }
            else if l.hasPrefix("ip_address=") { ip = String(l.dropFirst(11)) }
            else if l == "}" {
                if !ip.isEmpty { names[ip] = name }
                name = ""
                ip = ""
            }
        }
        var found: [Peer] = []
        for line in shell("arp -an -i bridge100 2>/dev/null").split(separator: "\n") where !line.contains("permanent") && !line.contains("incomplete") {
            guard let a = line.firstIndex(of: "("), let b = line.firstIndex(of: ")"), let at = line.range(of: " at ") else { continue }
            let ip = String(line[line.index(after: a)..<b])
            let mac = line[at.upperBound...].split(separator: " ").first.map(String.init) ?? ""
            found.append(Peer(id: ip, name: names[ip].flatMap { $0.isEmpty ? nil : $0 } ?? "Dispositivo", mac: mac))
        }
        return (true, found.sorted { $0.id.count == $1.id.count ? $0.id < $1.id : $0.id.count < $1.id.count }, awdl)
    }

    nonisolated static func readChannel() -> String { readHotspot().channel }

    /// The hotspot channel changes when the user picks one in Settings: re-read every 30 s and whenever the app regains focus.
    func refreshChannel() {
        guard !channelBusy else { return }
        channelBusy = true
        Task {
            let h = await Task.detached(operation: { GameLink.readHotspot() }).value
            channelBusy = false
            if !h.channel.isEmpty { channel = h.channel; ssid = h.name }
        }
    }

    nonisolated static func readHotspot() -> (name: String, channel: String) {
        let text = shell("system_profiler SPAirPortDataType 2>/dev/null")
        guard let r = text.range(of: "ap1:") else { return ("", "") }
        let block = text[r.upperBound...]
        let channel = block.range(of: #"Channel: [^\n]+"#, options: .regularExpression).map { String(block[$0]).replacingOccurrences(of: "Channel: ", with: "") } ?? ""
        let name = block.range(of: #"Current Network Information:\s*\n\s*([^\n]+):"#, options: .regularExpression).map {
            String(block[$0]).components(separatedBy: "\n").dropFirst().first?.trimmingCharacters(in: .whitespaces).dropLast() ?? ""
        } ?? ""
        return (String(name), channel)
    }

    nonisolated static func readHogs() -> [NetHog] {
        let out = shell("nettop -P -d -L 2 -s 1 -x -J bytes_in,bytes_out 2>/dev/null")
        guard let last = out.components(separatedBy: ",bytes_in,bytes_out,").last else { return [] }
        var list: [NetHog] = []
        for line in last.split(separator: "\n") {
            let f = line.split(separator: ",")
            guard f.count >= 3, let i = Double(f[1]), let o = Double(f[2]), i + o > 0,
                  let dot = f[0].lastIndex(of: "."), let pid = Int32(f[0][f[0].index(after: dot)...]), pid != getpid() else { continue }
            list.append(NetHog(pid: pid, name: String(f[0][..<dot]), rate: i + o))
        }
        return Array(list.sorted { $0.rate > $1.rate }.prefix(6))
    }

    func owner(_ hog: NetHog, _ m: Monitor) -> Item? {
        m.items.first { $0.procs.contains { $0.pid == hog.pid } }
    }

    func candidates(_ m: Monitor) -> [(Item, Double)] {
        hogs.compactMap { h in
            guard h.rate >= 50_000, !silenced.contains(h.pid), let item = owner(h, m), !item.protected, item.kind != .loose, !NightMode.keep.contains(item.name) else { return nil }
            return (item, h.rate)
        }
    }

    func silence(_ m: Monitor) {
        for (item, _) in candidates(m) {
            m.setPaused(item, true)
            silenced.formUnion(item.procs.map(\.pid))
        }
    }

    func resumeSilenced(_ m: Monitor) {
        m.items.filter { $0.procs.contains { silenced.contains($0.pid) } && $0.paused }.forEach { m.setPaused($0, false) }
        silenced = []
    }

    func toggleSession(_ m: Monitor) async {
        if session == nil { await beginSession(m) } else { endSession(m) }
    }

    func gameSignal(_ on: Bool, now: Date = Date()) async {
        guard autoPlay, let m = monitor else { return }
        if on {
            lastGame = now
            gameStreak += 1
            if session == nil, gameStreak >= 2, playSteps.isEmpty {
                autoStarted = true
                autoNote = "Empezó solo a las \(now.formatted(date: .omitted, time: .shortened)): la VM vio una partida."
                await play(m)
            }
        } else {
            gameStreak = 0
            if autoStarted, session != nil, let last = lastGame, now.timeIntervalSince(last) >= GameLink.autoEndAfter {
                autoNote = "Terminó sola a las \(now.formatted(date: .omitted, time: .shortened)): \(Int(GameLink.autoEndAfter / 60)) minutos sin partida."
                await toggleSession(m)
            }
        }
    }

    private func startAwake() {
        awake?.terminate()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-i", "-m", "-s", "-w", "\(ProcessInfo.processInfo.processIdentifier)"]
        try? p.run()
        awake = p
    }

    private func persist() {
        guard let s = session else {
            UserDefaults.standard.removeObject(forKey: GameLink.sessionKey)
            return
        }
        UserDefaults.standard.set(["start": s.start.timeIntervalSince1970, "seen": Date().timeIntervalSince1970, "relieved": s.relieved] as [String: Any], forKey: GameLink.sessionKey)
    }

    private func beginSession(_ m: Monitor, mark: (String, PlayStep.State, String) -> Void = { _, _, _ in }) async {
        mark("mac", .running, "")
        startAwake()
        await m.reload()
        let relieved = lowerPriority ? m.breathe(loose: false).map(\.name) : []
        session = Session(start: Date(), relieved: relieved)
        note = ""
        persist()
        mark("mac", .done, relieved.isEmpty ? (lowerPriority ? "Nada pesado que bajar" : "") : relieved.joined(separator: ", "))
        if autoSilence {
            mark("silence", .running, "")
            let names = candidates(m).map { $0.0.name }
            silence(m)
            mark("silence", names.isEmpty ? .skipped : .done, names.isEmpty ? "Ninguna app usa la red ahora" : names.joined(separator: ", "))
        }
        if awdlDuringGame {
            mark("awdl", .running, "")
            await setAwdl(down: true, interactive: true)
            mark("awdl", awdlHeld ? .done : .skipped, awdlHeld ? "" : "No se pudo: falta el permiso del ayudante")
        }
        if pauseBackup {
            mark("backup", .running, "")
            let out = await Task.detached { [backupRunner] in backupRunner() }.value
            switch out {
            case .idle: mark("backup", .skipped, "No hay copia en curso")
            case .stopped: mark("backup", .done, "Copia pausada; se reanuda sola en su próximo horario")
            case .failed: mark("backup", .skipped, "No se pudo pausar la copia")
            }
        }
        if exclusive {
            mark("limit", .running, "")
            await refreshLimit(interactive: true)
            mark("limit", limited.isEmpty ? .skipped : .done, limited.isEmpty ? "Sin otros equipos conectados" : "\(plural(limited.count, "dirección", "direcciones")) a \(exclusiveMbit) Mbit/s")
        }
        record("Empecé el modo juego")
        refresh()
    }

    func resume(_ m: Monitor) async {
        guard session == nil else { return }
        guard let d = UserDefaults.standard.dictionary(forKey: GameLink.sessionKey),
              let start = d["start"] as? Double, let seen = d["seen"] as? Double else {
            await settleAwdl(sessionAlive: false)
            await dropLimit(force: true)
            return
        }
        guard Date().timeIntervalSince1970 - seen < GameLink.resumeWithin else {
            UserDefaults.standard.removeObject(forKey: GameLink.sessionKey)
            note = "El modo juego anterior llevaba más de 12 horas sin actividad y no se retomó."
            record("No retomé el modo juego anterior: pasaron más de 12 horas")
            await settleAwdl(sessionAlive: false)
            await dropLimit(force: true)
            return
        }
        startAwake()
        await m.reload()
        session = Session(start: Date(timeIntervalSince1970: start), relieved: m.breathe(loose: false).map(\.name), resumed: Date())
        note = ""
        persist()
        record("Retomé el modo juego que estaba activo al cerrar la app")
        refresh()
        await settleAwdl(sessionAlive: true)
        if exclusive { await refreshLimit(interactive: false) }
    }

    private func settleAwdl(sessionAlive: Bool) async {
        let want = sessionAlive && awdlDuringGame
        if want != awdlHeld { await setAwdl(down: want, interactive: false) }
    }

    @discardableResult
    func setAwdl(down: Bool, interactive: Bool) async -> Bool {
        let run = awdlRunner
        let ok = await Task.detached { run(down, interactive) }.value
        if ok {
            awdlHeld = down
            lastRetake = Date()
            UserDefaults.standard.set(down, forKey: "gameAwdlHeld")
        } else if interactive {
            note = "No pude \(down ? "apagar" : "encender") AirDrop: el ayudante no recibió permiso."
        }
        return ok
    }

    func suspendForQuit() {
        if let s = session {
            persist()
            Journal.shared.add("Cerré TP Optimizer con el modo juego activo (\(elapsedText(Date().timeIntervalSince(s.start)))). Se retoma al abrirla")
        }
        awake?.terminate()
        awake = nil
        labTask?.cancel()
        labCounting = nil
        if awdlHeld, awdlRunner(false, false) {
            awdlHeld = false
            UserDefaults.standard.set(false, forKey: "gameAwdlHeld")
        }
        if UserDefaults.standard.bool(forKey: "gameQosHeld"), qosRunner(["clear"], false) {
            UserDefaults.standard.set(false, forKey: "gameQosHeld")
            limited = []
            lastLimit = ""
        }
        viewers = 0
        end()
    }

    private func endSession(_ m: Monitor) {
        guard let s = session else { return }
        autoStarted = false
        awake?.terminate()
        awake = nil
        for item in m.items where s.relieved.contains(item.name) { m.relieve(item, false) }
        resumeSilenced(m)
        let mins = max(1, Int(Date().timeIntervalSince(s.start) / 60))
        let stats = s.play.n > 0 ? s.play : s.local
        let kind = s.play.n > 0 ? "en juego" : "en reposo"
        remember(s)
        labTask?.cancel()
        if awdlHeld { Task { await setAwdl(down: false, interactive: false) } }
        Task { await dropLimit() }
        record("Modo juego: \(plural(mins, "minuto", "minutos")), iPad ↔ Mac \(kind) \(ms(stats.avg)) ms (pico \(ms(stats.peak)) ms, \(plural(stats.lost, "pérdida", "pérdidas"))), internet \(ms(s.net.avg)) ms")
        note = "Sesión terminada: \(plural(mins, "minuto", "minutos")), iPad ↔ Mac \(kind) \(ms(stats.avg)) ms de promedio y pico de \(ms(stats.peak)) ms."
        session = nil
        persist()
        refresh()
    }

    var ipadDead: Bool { local.values.count >= 20 && local.lossPct > 50 }
    var hasLocal: Bool { !local.got.isEmpty && !ipadDead && (ipad == .awake || !keepAwake) }
    var totalMs: Double { (hasLocal ? local.avg : 0) + net.avg }
    var menuText: String { session == nil || net.got.isEmpty ? "" : ms(totalMs) + " ms" }

    func useTarget(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GameLink.validTarget(t) else { return false }
        destinoNote = ""
        destino = t
        UserDefaults.standard.set(t, forKey: "gameTarget")
        netStream?.stop()
        netStream = loop == nil ? nil : PingStream(target: t, interval: "0.5")
        netStartedAt = Date()
        net = Series(capacity: 120)
        session?.net = Acc()
        return true
    }

    private func remember(_ s: Session) {
        let stats = s.play.n > 0 ? s.play : s.local
        guard stats.n > 100 else { return }
        history.insert(PastSession(start: s.start, seconds: Date().timeIntervalSince(s.start), avg: stats.avg, peak: stats.peak, lost: stats.lost, spikes: stats.spikes, playing: s.play.n > 0, airdropOff: awdlHeld, channel: GameLink.channelNumber(channel), jitter: stats.jitter, lossPct: stats.lossPct), at: 0)
        if history.count > 30 { history.removeLast(history.count - 30) }
        if let d = try? JSONEncoder().encode(history) { UserDefaults.standard.set(d, forKey: "gameHistory") }
    }

    func startLab() {
        guard !labRunning else { return }
        guard ipad == .awake, keepAwake else {
            note = "La prueba necesita al iPad despierto: enciende su pantalla y espera a que se mida."
            return
        }
        labRunning = true
        labTask = Task { await runLab() }
    }

    func cancelLab() { labTask?.cancel() }

    private func runLab() async {
        labNormal = LabArm()
        labOff = LabArm()
        labVerdict = nil
        let back = session != nil && awdlDuringGame
        var complete = true
        for (i, down) in [false, true, false, true].enumerated() {
            labCounting = nil
            if awdlHeld != down, !(await setAwdl(down: down, interactive: true)) {
                complete = false
                break
            }
            labPhase = i + 1
            labSkipUntil = Date().addingTimeInterval(min(5, labSeconds / 4))
            labCounting = down
            for left in stride(from: Int(labSeconds), to: 0, by: -1) {
                labLeft = left
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled || ipad != .awake {
                    complete = false
                    break
                }
            }
            if !complete { break }
        }
        labCounting = nil
        if awdlHeld != back { await setAwdl(down: back, interactive: false) }
        labRunning = false
        labPhase = 0
        labLeft = 0
        if complete {
            labVerdict = Lab.judge(normal: labNormal, off: labOff)
            record("Laboratorio de AirDrop: p99 normal \(ms(labNormal.p99)) ms, apagado \(ms(labOff.p99)) ms")
        } else {
            note = "La prueba se canceló o el iPad se durmió. Los números son parciales y no se comparan."
        }
    }

    var plan: [PlanItem] {
        var out = [PlanItem(id: "mac", title: "Mac despierta", step: lowerPriority ? "Mantener la Mac despierta y bajar la prioridad de lo pesado" : "Mantener la Mac despierta", symbol: "desktopcomputer")]
        if autoSilence { out.append(PlanItem(id: "silence", title: "Apps de red dormidas", step: "Dormir las apps que usan la red", symbol: "moon.zzz")) }
        if awdlDuringGame { out.append(PlanItem(id: "awdl", title: "AirDrop apagado", step: "Apagar AirDrop y Handoff", symbol: "antenna.radiowaves.left.and.right.slash")) }
        if pauseBackup { out.append(PlanItem(id: "backup", title: "Time Machine en pausa", step: "Pausar la copia de Time Machine", symbol: "externaldrive")) }
        if exclusive { out.append(PlanItem(id: "limit", title: "Los demás a \(exclusiveMbit) Mbit/s", step: "Limitar a los demás equipos", symbol: "person.2.slash")) }
        if keepAwake { out.append(PlanItem(id: "ipad", title: "iPad despierto", step: "Mantener despierto al iPad", symbol: "ipad")) }
        return out
    }

    @Published private(set) var fixing = false
    @Published private(set) var fixNote = ""

    /// One tap, no dialogs: game mode on, AirDrop off, then a before/after ping measures whether the Wi-Fi hop improved.
    func fixNow(_ m: Monitor) async {
        guard !fixing else { return }
        fixing = true
        defer { fixing = false }
        let ip = activePeer?.id
        fixNote = "Midiendo antes…"
        let before = await GameLink.stalls(ip)
        fixNote = "Aplicando…"
        awdlDuringGame = true
        if session == nil { await play(m) } else if !awdlHeld { await setAwdl(down: true, interactive: false) }
        try? await Task.sleep(for: .seconds(2))
        fixNote = "Midiendo después…"
        let after = await GameLink.stalls(ip)
        var parts: [String] = [awdlHeld ? "AirDrop apagado" : "No pude apagar AirDrop: falta el permiso del ayudante"]
        if let b = before, let a = after {
            parts.append("saltos de más de 20 ms en 12 s: antes \(b.over20), después \(a.over20) (pico \(Int(b.max)) → \(Int(a.max)) ms)")
            if a.over20 >= max(2, b.over20 * 3 / 4) { parts.append("No bajaron: el freno está en el aire del Wi-Fi, prueba otro canal") }
        } else {
            parts.append("no pude medir el tramo del iPad")
        }
        fixNote = parts.joined(separator: " · ")
    }

    nonisolated static func stalls(_ ip: String?) async -> (over20: Int, max: Double)? {
        guard let ip, ip.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        let out = await Task.detached { shell("ping -c 48 -i 0.25 -W 800 \(ip) 2>/dev/null") }.value
        let ms = out.split(separator: "\n").compactMap { l -> Double? in
            guard let r = l.range(of: "time=") else { return nil }
            return Double(l[r.upperBound...].prefix { $0.isNumber || $0 == "." })
        }
        return ms.count >= 24 ? (ms.filter { $0 > 20 }.count, ms.max() ?? 0) : nil
    }

    func play(_ m: Monitor) async {
        guard session == nil, playSteps.isEmpty else { return }
        playSteps = plan.map { PlayStep(id: $0.id, title: $0.step) }
        func mark(_ id: String, _ state: PlayStep.State, _ detail: String) {
            guard let i = playSteps.firstIndex(where: { $0.id == id }) else { return }
            playSteps[i].state = state
            playSteps[i].detail = detail
        }
        await beginSession(m, mark: mark)
        if keepAwake {
            mark("ipad", .running, "")
            for _ in 0..<12 where ipad != .awake { try? await Task.sleep(for: .milliseconds(500)) }
            mark("ipad", ipad == .awake ? .done : .skipped, ipad == .awake ? "" : "El iPad está dormido: enciende su pantalla")
        }
        try? await Task.sleep(for: .seconds(4))
        playSteps = []
    }

    func measureLoad() async {
        guard !measuring else { return }
        loadLocal = Acc()
        loadNet = Acc()
        loadNote = ""
        measuring = true
        defer { measuring = false }
        let base = net.avg
        let out = await Task.detached { shell("networkQuality -c -M 25 2>/dev/null") }.value
        guard let j = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any], let rpm = j["responsiveness"] as? Double else {
            note = "La prueba de saturación no terminó."
            return
        }
        quality = Quality(rpm: rpm, baseRTT: j["base_rtt"] as? Double ?? 0, down: (j["dl_throughput"] as? Double ?? 0) / 1e6, up: (j["ul_throughput"] as? Double ?? 0) / 1e6)
        loadNote = loadNet.n > 5
            ? "Con la línea llena, tu latencia a internet pasó de \(ms(base)) a \(ms(loadNet.avg)) ms (pico \(ms(loadNet.peak)) ms)." + (loadLocal.n > 100 ? " El tramo del iPad quedó en \(ms(loadLocal.avg)) ms" + (loadLocal.lossPct >= 1 ? " con \(ms(loadLocal.lossPct))% de pérdida." : ".") : "")
            : ""
        record("Prueba de saturación: \(Int(rpm)) RPM" + (loadNet.n > 5 ? ", internet \(ms(base)) → \(ms(loadNet.avg)) ms" : ""))
    }

    var channelNumber: Int? { Int(channel.split(separator: " ").first ?? "") }
    var aligned: Bool? { channelNumber.map { GameLink.socialChannels.contains($0) } }
    var spikesWithAWDL: Int { spikeLog.filter(\.awdl).count }
    var rhythmic: Bool { GameLink.isRhythmic(spikeLog.map(\.at)) }
    var playing: Bool { GameLink.isActive(mbit: (down + up) * 8 / 1e6) }

    private func learn() {
        if known.isEmpty && !peers.isEmpty { known = Set(peers.map(\.mac)) }
        newcomer = peers.first { !known.contains($0.mac) }
        UserDefaults.standard.set(Array(known), forKey: "gameKnownMACs")
    }

    func trust(_ p: Peer) {
        known.insert(p.mac)
        UserDefaults.standard.set(Array(known), forKey: "gameKnownMACs")
        newcomer = peers.first { !known.contains($0.mac) }
    }

    var report: String {
        var t = "Informe de red · \(Date().formatted(date: .abbreviated, time: .standard))\n"
        t += "Hotspot de la Mac: \(channel.isEmpty ? "sin datos" : channel)\(aligned == true ? " (igual que AirDrop)" : aligned == false ? " (distinto del canal de AirDrop)" : "")\n"
        if let p = activePeer { t += "iPad ↔ Mac (\(p.name), \(p.id)): \(ms(local.avg)) ms, jitter \(ms(local.jitter)) ms, pico \(ms(local.peak)) ms, pérdida \(ms(local.lossPct))% (últimos 60 s)\n" }
        t += "Mac ↔ \(destino): \(ms(net.avg)) ms, jitter \(ms(net.jitter)) ms, pico \(ms(net.peak)) ms, pérdida \(ms(net.lossPct))% (últimos 60 s)\n"
        if let q = quality { t += "Saturación: \(Int(q.rpm)) RPM, unos \(ms(q.loaded)) ms bajo carga, bajada \(Int(q.down)) Mbit/s, subida \(Int(q.up)) Mbit/s\n" }
        return t
    }

    func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        note = "Informe copiado."
    }
}

func elapsedText(_ s: TimeInterval) -> String {
    s >= 3600 ? String(format: "%d:%02d:%02d", Int(s) / 3600, Int(s) % 3600 / 60, Int(s) % 60) : String(format: "%02d:%02d", Int(s) / 60, Int(s) % 60)
}

func ms(_ v: Double) -> String { String(format: v >= 100 ? "%.0f" : "%.1f", v).replacingOccurrences(of: ".", with: ",") }

func rateText(_ bytesPerSecond: Double) -> String { bytesPerSecond < 1 ? "0 B/s" : formatBytes(Int64(bytesPerSecond)) + "/s" }

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
            why = "Los saltos se repiten a ritmo regular, típico de AirDrop. Pon el canal del Wi-Fi compartido en 44 (o 149 si tu lista lo trae)."
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
                        .help("Sin preguntas: modo juego, AirDrop apagado, VM al día y medición antes/después")
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
