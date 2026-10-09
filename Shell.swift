import AppKit

#if TESTING
enum Hooks {
    nonisolated(unsafe) static var shell: (@Sendable (String) -> (out: String, status: Int32))?
    nonisolated(unsafe) static var recycle: (@Sendable ([URL]) -> Int)?
    nonisolated(unsafe) static var emptyTrash: (@Sendable () -> Bool)?
    nonisolated(unsafe) static var deletable: (@Sendable (String) -> Bool)?
}
func homePath() -> String { ProcessInfo.processInfo.environment["TP_HOME"] ?? NSHomeDirectory() }
#else
func homePath() -> String { NSHomeDirectory() }
#endif

@discardableResult
func shell(_ cmd: String) -> String {
    #if TESTING
    if let h = Hooks.shell { return h(cmd).out }
    #endif
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", cmd]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    try? p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func shellStatus(_ cmd: String) -> Int32 {
    #if TESTING
    if let h = Hooks.shell { return h(cmd).status }
    #endif
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", cmd]
    p.standardOutput = Pipe()
    p.standardError = Pipe()
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

func shellAsync(_ cmd: String) async -> String { await Task.detached { shell(cmd) }.value }

// macOS shows its own password prompt; the app never sees the password.
func adminShell(_ cmd: String) -> Bool {
    let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    var error: NSDictionary?
    NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
    return error == nil
}

func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

private let byteFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowsNonnumericFormatting = false
    return f
}()

func formatBytes(_ b: Int64) -> String { byteFormatter.string(fromByteCount: b) }

func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

func humanAge(_ etime: String) -> String {
    let dayParts = etime.split(separator: "-")
    let days = dayParts.count == 2 ? Int(dayParts[0]) ?? 0 : 0
    let clock = (dayParts.last ?? "").split(separator: ":").compactMap { Int($0) }
    if days > 0 { return plural(days, "día", "días") }
    if clock.count == 3, clock[0] >= 24 { return plural(clock[0] / 24, "día", "días") }
    if clock.count == 3 { return clock[0] > 0 ? plural(clock[0], "hora", "horas") : plural(clock[1], "minuto", "minutos") }
    if clock.count == 2 { return clock[0] > 0 ? plural(clock[0], "minuto", "minutos") : "segundos" }
    return etime
}

let appSupport: String = {
    let dir = homePath() + "/Library/Application Support/TP Optimizer"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}()

func openSettings(_ anchor: String) {
    if let url = URL(string: "x-apple.systempreferences:" + anchor) { NSWorkspace.shared.open(url) }
}

func folderSize(_ url: URL) -> Int64 {
    guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: []) else { return 0 }
    var total: Int64 = 0
    for case let f as URL in e {
        total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
    }
    return total
}

func recycle(_ urls: [URL]) async -> Int {
    #if TESTING
    if let h = Hooks.recycle { return h(urls) }
    #endif
    return await withCheckedContinuation { c in
        NSWorkspace.shared.recycle(urls) { moved, _ in c.resume(returning: moved.count) }
    }
}

@discardableResult
func emptyTrash() -> Bool {
    #if TESTING
    if let h = Hooks.emptyTrash { return h() }
    #endif
    var error: NSDictionary?
    NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
    return error == nil
}
