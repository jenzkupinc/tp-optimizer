import Foundation

let helperVersion = "15"
let firewallTool = "/usr/libexec/ApplicationFirewall/socketfilterfw"
let launchctl = "/bin/launchctl"
let tcpdumpTool = "/usr/sbin/tcpdump"
let pfctlTool = "/sbin/pfctl"
let dnctlTool = "/usr/sbin/dnctl"
let qosAnchor = "com.apple/260.TPOptimizer"
let codesignTool = "/usr/bin/codesign"
let signingRequirement = #"=identifier "app.tpoptimizer.root" and certificate root = H"SIGNING_HASH""#
let networksetupTool = "/usr/sbin/networksetup"
let sudoUID = ProcessInfo.processInfo.environment["SUDO_UID"].flatMap { UInt32($0) }

#if TESTING
let env = ProcessInfo.processInfo.environment
let daemonsDir = env["TP_T_DAEMONS"] ?? "", agentsDir = env["TP_T_AGENTS"] ?? ""
let hostsPath = env["TP_T_HOSTS"] ?? "", logPath = env["TP_T_AUDIT"] ?? "", callLog = env["TP_T_CALLS"] ?? ""
let installedHelper = (env["TP_T_HELPERDIR"] ?? "") + "/app.tpoptimizer.root"
let qosRulesFile = env["TP_T_QOSFILE"] ?? ""

@discardableResult
func run(_ tool: String, _ args: [String]) -> Int32 {
    var line = ([tool] + args).joined(separator: " ") + "\n"
    if tool.hasSuffix("pfctl"), let i = args.firstIndex(of: "-f"), i + 1 < args.count, let rules = try? String(contentsOfFile: args[i + 1], encoding: .utf8) { line += rules }
    if let h = FileHandle(forWritingAtPath: callLog) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { FileManager.default.createFile(atPath: callLog, contents: Data(line.utf8)) }
    return env["TP_T_FAIL"].map { tool.hasSuffix($0) } == true ? 1 : 0
}

func capture(_ tool: String, _ args: [String]) -> String {
    args == ["version"] ? env["TP_T_NEWVERSION"] ?? "" : tool.hasSuffix("networksetup") ? env["TP_T_SERVICES"] ?? "" : env["TP_T_LISTAPPS"] ?? ""
}

func captureLimited(_ tool: String, _ args: [String], seconds: Double) -> String {
    run(tool, args)
    return env["TP_T_FLOWS"] ?? ""
}
func homeDirectory(_ uid: UInt32) -> String? { env["TP_T_HOME"] }
func primaryGroup(_ uid: UInt32) -> gid_t { getgid() }
let hostsAttributes: [FileAttributeKey: Any] = [.posixPermissions: 0o644]
#else
let daemonsDir = "/Library/LaunchDaemons", agentsDir = "/Library/LaunchAgents"
let hostsPath = "/private/etc/hosts", logPath = "/var/log/tp-optimizer-root.log"
let installedHelper = "/Library/PrivilegedHelperTools/app.tpoptimizer.root"
let qosRulesFile = "/private/var/tmp/tp-optimizer-qos.rules"

@discardableResult
func run(_ tool: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return 127 }
    p.waitUntilExit()
    return p.terminationStatus
}

func capture(_ tool: String, _ args: [String]) -> String {
    let p = Process()
    let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func captureLimited(_ tool: String, _ args: [String], seconds: Double) -> String {
    let p = Process()
    let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { if p.isRunning { p.interrupt() } }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func homeDirectory(_ uid: UInt32) -> String? { getpwuid(uid).map { String(cString: $0.pointee.pw_dir) } }
func primaryGroup(_ uid: UInt32) -> gid_t { getpwuid(uid)?.pointee.pw_gid ?? 20 }
let hostsAttributes: [FileAttributeKey: Any] = [.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0]
#endif

let launchDirs = [daemonsDir, agentsDir]
let launchDirsReal = launchDirs.map { ($0 as NSString).resolvingSymlinksInPath }

func audit(_ args: [String], _ ok: Bool) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) uid=\(sudoUID.map(String.init) ?? "?") \(args.joined(separator: " ")) -> \(ok ? "ok" : "fallo")\n"
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        try? h.close()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: Data(line.utf8), attributes: [.posixPermissions: 0o644])
    }
}

func validDomain(_ d: String) -> Bool {
    d.count <= 253 && d.range(of: #"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$"#, options: .regularExpression) != nil
        && d.split(separator: ".").last?.contains(where: \.isLetter) == true
}

func validLabel(_ l: String) -> Bool {
    l.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+-]{0,199}$"#, options: .regularExpression) != nil && !l.hasPrefix("com.apple.")
}

func flushDNS() {
    run("/usr/bin/dscacheutil", ["-flushcache"])
    run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
}

func deep() -> Bool {
    run("/usr/sbin/purge", []) == 0 && run("/usr/bin/dscacheutil", ["-flushcache"]) == 0 && run("/usr/bin/killall", ["-HUP", "mDNSResponder"]) == 0
}

func schedule(_ t: [String]) -> Bool {
    let kinds: Set<String> = ["wake", "poweron", "wakeorpoweron", "sleep", "shutdown", "restart"]
    guard t.count % 3 == 0, t.count <= 6 else { return false }
    for i in stride(from: 0, to: t.count, by: 3) {
        guard kinds.contains(t[i]),
              t[i + 1].range(of: #"^[MTWRFSU]{1,7}$"#, options: .regularExpression) != nil,
              t[i + 2].range(of: #"^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$"#, options: .regularExpression) != nil else { return false }
    }
    guard run("/usr/bin/pmset", ["repeat", "cancel"]) == 0 else { return false }
    return t.isEmpty || run("/usr/bin/pmset", ["repeat"] + t) == 0
}

func setHosts(_ domains: [String]) -> Bool {
    guard domains.allSatisfy(validDomain) else { return false }
    let path = hostsPath
    let start = "# TP Optimizer: inicio", end = "# TP Optimizer: fin"
    guard var text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
    if let a = text.range(of: start), let b = text.range(of: end), a.lowerBound < b.upperBound {
        text.removeSubrange(a.lowerBound..<b.upperBound)
    }
    text = text.trimmingCharacters(in: .newlines) + "\n"
    let clean = Array(Set(domains)).sorted()
    if !clean.isEmpty { text += "\n\(start)\n" + clean.map { "0.0.0.0 \($0)" }.joined(separator: "\n") + "\n\(end)\n" }
    let tmp = path + ".tp-nuevo"
    do {
        try text.write(toFile: tmp, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes(hostsAttributes, ofItemAtPath: tmp)
    } catch {
        try? FileManager.default.removeItem(atPath: tmp)
        return false
    }
    guard rename(tmp, path) == 0 else { try? FileManager.default.removeItem(atPath: tmp); return false }
    flushDNS()
    return true
}

func appPath(_ p: String, needsDisk: Bool) -> String? {
    guard p.hasPrefix("/"), p.count < 1024, !p.unicodeScalars.contains(where: { $0.value < 32 }), !p.split(separator: "/").contains("..") else { return nil }
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue ? p.hasSuffix(".app") : FileManager.default.isExecutableFile(atPath: p) { return p }
    if needsDisk { return nil }
    return capture(firewallTool, ["--listapps"]).contains(p) ? p : nil
}

func firewall(_ a: [String]) -> Bool {
    guard let op = a.first else { return false }
    switch op {
    case "stealth":
        guard a.count == 2, a[1] == "on" || a[1] == "off" else { return false }
        return run(firewallTool, ["--setstealthmode", a[1]]) == 0
    case "block", "unblock", "add":
        guard a.count == 2, let p = appPath(a[1], needsDisk: op == "add") else { return false }
        if op == "add" { return run(firewallTool, ["--add", p]) == 0 && run(firewallTool, ["--blockapp", p]) == 0 }
        return run(firewallTool, [op == "block" ? "--blockapp" : "--unblockapp", p]) == 0
    default:
        return false
    }
}

func octets(_ s: String) -> [Int]? {
    let parts = s.split(separator: ".", omittingEmptySubsequences: false)
    let nums = parts.compactMap { Int($0) }
    return parts.count == 4 && nums.count == 4 && nums.allSatisfy { (0...255).contains($0) } ? nums : nil
}

func privateIPv4(_ s: String) -> Bool {
    guard let p = octets(s) else { return false }
    return p[0] == 10 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168)
}

func validDNSAddress(_ s: String) -> Bool {
    octets(s) != nil || (s.contains(":") && s.count <= 39 && s.range(of: #"^[0-9A-Fa-f:]+$"#, options: .regularExpression) != nil)
}

func validMAC(_ s: String) -> Bool {
    s.range(of: #"^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$"#, options: .regularExpression) != nil
}

func flows(_ a: [String]) -> Bool {
    guard (1...2).contains(a.count), validMAC(a[0]) else { return false }
    let seconds = a.count == 2 ? a[1] : "5"
    guard ["5", "10", "15"].contains(seconds) else { return false }
    print(captureLimited(tcpdumpTool, ["-i", "bridge100", "-nn", "-q", "-l", "-s", "96", "-c", "6000", "ether", "host", a[0].lowercased(), "and", "not", "icmp", "and", "not", "icmp6", "and", "not", "arp"], seconds: Double(seconds) ?? 5))
    return true
}

func dns(_ a: [String]) -> Bool {
    guard a.count >= 2, a[0] == "set" || a[0] == "reset" else { return false }
    let services = capture(networksetupTool, ["-listallnetworkservices"]).components(separatedBy: "\n").dropFirst()
        .map { $0.hasPrefix("*") ? String($0.dropFirst()) : $0 }
    guard services.contains(a[1]) else { return false }
    let addresses = Array(a.dropFirst(2))
    if a[0] == "reset" {
        guard addresses.isEmpty, run(networksetupTool, ["-setdnsservers", a[1], "Empty"]) == 0 else { return false }
    } else {
        guard (1...8).contains(addresses.count), addresses.allSatisfy(validDNSAddress), run(networksetupTool, ["-setdnsservers", a[1]] + addresses) == 0 else { return false }
    }
    flushDNS()
    return true
}

func update(_ a: [String]) -> Bool {
    guard a.count == 1, a[0].hasPrefix("/"), a[0].hasSuffix("/Contents/Resources/tp-root"), a[0].count < 1024,
          !a[0].split(separator: "/").contains(".."), !a[0].unicodeScalars.contains(where: { $0.value < 32 }) else { return false }
    var st = stat()
    guard lstat(a[0], &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return false }
    let staging = installedHelper + ".new"
    try? FileManager.default.removeItem(atPath: staging)
    defer { try? FileManager.default.removeItem(atPath: staging) }
    guard (try? FileManager.default.copyItem(atPath: a[0], toPath: staging)) != nil,
          (try? FileManager.default.setAttributes(hostsAttributes.merging([.posixPermissions: 0o755]) { $1 }, ofItemAtPath: staging)) != nil,
          run(codesignTool, ["--verify", "--test-requirement=" + signingRequirement, staging]) == 0,
          let fresh = Int(capture(staging, ["version"]).trimmingCharacters(in: .whitespacesAndNewlines)),
          let current = Int(helperVersion), fresh > current else { return false }
    return rename(staging, installedHelper) == 0
}

func netinfo(_ a: [String]) -> Bool {
    guard a.isEmpty else { return false }
    let steps: [(String, String, [String])] = [
        ("pf info", pfctlTool, ["-s", "info"]), ("pf nat", pfctlTool, ["-s", "nat"]), ("pf reglas", pfctlTool, ["-s", "rules"]),
        ("pf anclas", pfctlTool, ["-vvsA"]), ("pf nat de anclas", pfctlTool, ["-a", "com.apple/*", "-s", "nat"]),
        ("pf reglas de anclas", pfctlTool, ["-a", "com.apple/*", "-s", "rules"]), ("dnctl", dnctlTool, ["list"]),
        ("pf dummynet", pfctlTool, ["-s", "dummynet", "-vv"]), ("ancla del límite", pfctlTool, ["-a", qosAnchor, "-s", "dummynet", "-vv"]),
        ("tuberías con contadores", dnctlTool, ["pipe", "show"]),
        ("v4 nat", pfctlTool, ["-a", "com.apple.internet-sharing/shared_v4", "-s", "nat"]),
        ("v4 reglas", pfctlTool, ["-a", "com.apple.internet-sharing/shared_v4", "-s", "rules"]),
        ("v4 dummynet", pfctlTool, ["-a", "com.apple.internet-sharing/shared_v4", "-s", "dummynet"]),
        ("v6 nat", pfctlTool, ["-a", "com.apple.internet-sharing/shared_v6", "-s", "nat"]),
        ("v6 reglas", pfctlTool, ["-a", "com.apple.internet-sharing/shared_v6", "-s", "rules"]),
        ("v6 dummynet", pfctlTool, ["-a", "com.apple.internet-sharing/shared_v6", "-s", "dummynet"]),
    ]
    for (title, tool, args) in steps { print("== \(title)\n" + captureLimited(tool, args, seconds: 5)) }
    let states = captureLimited(pfctlTool, ["-s", "state"], seconds: 5).components(separatedBy: "\n").filter { $0.contains("192.168.2.") || $0.contains("fdc3:") }
    print("== pf estados de los clientes del hotspot (primeros 24)\n" + states.prefix(24).joined(separator: "\n"))
    return true
}

func validULA(_ s: String) -> Bool {
    s.count <= 39 && s.range(of: #"^[fF][dD][0-9A-Fa-f]{2}(:[0-9A-Fa-f]{0,4}){3,7}$"#, options: .regularExpression) != nil
}

func globalAddress(_ s: String) -> Bool {
    if let p = octets(s) {
        if p[0] == 0 || p[0] == 10 || p[0] == 127 || p[0] >= 224 { return false }
        if p[0] == 169 && p[1] == 254 { return false }
        if p[0] == 172 && (16...31).contains(p[1]) { return false }
        if p[0] == 192 && p[1] == 168 { return false }
        return true
    }
    var v6 = in6_addr()
    guard s.contains(":"), s.count <= 45, inet_pton(AF_INET6, s, &v6) == 1 else { return false }
    let b = withUnsafeBytes(of: &v6) { Array($0) }
    if b.allSatisfy({ $0 == 0 }) || (b[0..<15].allSatisfy { $0 == 0 } && b[15] == 1) { return false }
    if b[0] & 0xFE == 0xFC || (b[0] == 0xFE && b[1] & 0xC0 == 0x80) || b[0] == 0xFF { return false }
    return true
}

func canonicalAddress(_ s: String) -> String {
    var v6 = in6_addr()
    guard s.contains(":"), inet_pton(AF_INET6, s, &v6) == 1 else { return s }
    var buf = [CChar](repeating: 0, count: 64)
    return inet_ntop(AF_INET6, &v6, &buf, 64) != nil ? String(cString: buf) : s
}

func tunnelPairs(_ state: String, clients rawClients: Set<String>) -> [(client: String, remote: String)] {
    let clients = Set(rawClients.map(canonicalAddress))
    let v4 = try! NSRegularExpression(pattern: #"^(\d{1,3}(?:\.\d{1,3}){3}):(\d{1,5})$"#)
    let v6 = try! NSRegularExpression(pattern: #"^([0-9A-Fa-f:]+)\[(\d{1,5})\]$"#)
    var out: [(client: String, remote: String)] = []
    for line in state.components(separatedBy: "\n") where line.contains(" udp ") {
        var points: [(String, Int)] = []
        for token in line.split(separator: " ").map(String.init) {
            let range = NSRange(token.startIndex..., in: token)
            for re in [v4, v6] {
                if let m = re.firstMatch(in: token, range: range), let a = Range(m.range(at: 1), in: token), let q = Range(m.range(at: 2), in: token), let port = Int(token[q]) {
                    points.append((canonicalAddress(String(token[a])), port))
                }
            }
        }
        guard let remote = points.first(where: { $0.1 == 51820 && globalAddress($0.0) && !clients.contains($0.0) }),
              let client = points.first(where: { clients.contains($0.0) }) else { continue }
        if !out.contains(where: { $0.client == client.0 && $0.remote == remote.0 }) { out.append((client.0, remote.0)) }
    }
    return out
}

func reroll(_ a: [String]) -> Bool {
    guard (1...4).contains(a.count), Set(a).count == a.count, a.allSatisfy({ privateIPv4($0) || validULA($0) }) else { return false }
    let pairs = tunnelPairs(captureLimited(pfctlTool, ["-s", "state"], seconds: 5), clients: Set(a))
    var killed = 0
    for p in pairs where run(pfctlTool, ["-k", p.client, "-k", p.remote]) == 0 { killed += 1 }
    print("pares \(pairs.count) cortados \(killed)")
    return killed == pairs.count
}

func qos(_ a: [String]) -> Bool {
    guard let verb = a.first else { return false }
    if verb == "clear" {
        guard a.count == 1 else { return false }
        let flushed = run(pfctlTool, ["-a", qosAnchor, "-F", "all"]) == 0
        run(dnctlTool, ["-q", "pipe", "delete", "61"])
        run(dnctlTool, ["-q", "pipe", "delete", "62"])
        return flushed
    }
    guard verb == "apply", (3...18).contains(a.count), let mbit = Int(a[1]), (1...1000).contains(mbit) else { return false }
    let addresses = Array(a.dropFirst(2))
    guard Set(addresses).count == addresses.count, addresses.allSatisfy({ privateIPv4($0) || validULA($0) }) else { return false }
    var rules = ""
    for x in addresses {
        let family = x.contains(":") ? "inet6" : "inet"
        rules += "dummynet in on bridge100 \(family) from \(x) to any pipe 61\n"
        rules += "dummynet out on bridge100 \(family) from any to \(x) pipe 62\n"
    }
    guard (try? rules.write(toFile: qosRulesFile, atomically: true, encoding: .utf8)) != nil else { return false }
    defer { try? FileManager.default.removeItem(atPath: qosRulesFile) }
    let rate = "\(mbit)Mbit/s"
    return run(dnctlTool, ["pipe", "61", "config", "bw", rate, "queue", "50"]) == 0
        && run(dnctlTool, ["pipe", "62", "config", "bw", rate, "queue", "50"]) == 0
        && run(pfctlTool, ["-a", qosAnchor, "-f", qosRulesFile]) == 0
}

func awdl(_ a: [String]) -> Bool {
    guard a.count == 1, a[0] == "up" || a[0] == "down" else { return false }
    return run("/sbin/ifconfig", ["awdl0", a[0]]) == 0
}

func plistLabel(_ path: String) -> String {
    (NSDictionary(contentsOfFile: path)?["Label"] as? String) ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
}

func findPlist(_ label: String) -> String? {
    for dir in launchDirs {
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".plist") {
            if plistLabel(dir + "/" + f) == label { return dir + "/" + f }
        }
    }
    return nil
}

func checkedPlist(_ path: String, _ label: String) -> String? {
    let real = (path as NSString).resolvingSymlinksInPath
    guard launchDirsReal.contains(where: { real.hasPrefix($0 + "/") }), real.hasSuffix(".plist"), plistLabel(real) == label else { return nil }
    return real
}

func launchDomain(_ plist: String) -> String? {
    if plist.hasPrefix(launchDirsReal[0] + "/") || plist.hasPrefix(daemonsDir + "/") { return "system" }
    return sudoUID.map { "gui/\($0)" }
}

func toTrash(_ path: String, uid: UInt32) -> Bool {
    guard let home = homeDirectory(uid) else { return false }
    let trash = home + "/.Trash"
    var st = stat()
    guard lstat(trash, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == uid else { return false }
    let base = (path as NSString).lastPathComponent
    let stem = (base as NSString).deletingPathExtension, ext = (base as NSString).pathExtension
    var dest = trash + "/" + base, n = 1
    while lstat(dest, &st) == 0 {
        n += 1
        dest = trash + "/" + stem + " \(n)." + ext
    }
    guard rename(path, dest) == 0 else { return false }
    lchown(dest, uid, primaryGroup(uid))
    return true
}

func launch(_ a: [String]) -> Bool {
    guard a.count >= 2, validLabel(a[1]) else { return false }
    let label = a[1]
    switch a[0] {
    case "sleep":
        guard a.count == 2, let plist = findPlist(label), let dom = launchDomain(plist) else { return false }
        run(launchctl, ["bootout", "\(dom)/\(label)"])
        return run(launchctl, ["disable", "\(dom)/\(label)"]) == 0
    case "wake":
        guard a.count == 3, let plist = checkedPlist(a[2], label), let dom = launchDomain(plist) else { return false }
        let enabled = run(launchctl, ["enable", "\(dom)/\(label)"]) == 0
        run(launchctl, ["bootstrap", dom, plist])
        return enabled
    case "remove":
        guard a.count == 3, let plist = checkedPlist(a[2], label), let dom = launchDomain(plist), let uid = sudoUID, uid != 0 else { return false }
        run(launchctl, ["bootout", "\(dom)/\(label)"])
        return toTrash(plist, uid: uid)
    default:
        return false
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let op = args.first else { exit(64) }
if op == "version" {
    print(helperVersion)
    exit(0)
}
#if !TESTING
guard geteuid() == 0 else {
    FileHandle.standardError.write(Data("necesita permisos de administrador\n".utf8))
    exit(77)
}
#endif
let rest = Array(args.dropFirst())
let ok: Bool
switch op {
case "deep": ok = rest.isEmpty && deep()
case "schedule": ok = schedule(rest)
case "hosts": ok = setHosts(rest)
case "fw": ok = firewall(rest)
case "launch": ok = launch(rest)
case "awdl": ok = awdl(rest)
case "qos": ok = qos(rest)
case "reroll": ok = reroll(rest)
case "netinfo": ok = netinfo(rest)
case "update": ok = update(rest)
case "flows": ok = flows(rest)
case "dns": ok = dns(rest)
default: ok = false
}
audit(args, ok)
exit(ok ? 0 : 65)
