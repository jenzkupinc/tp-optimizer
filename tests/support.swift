import Foundation

nonisolated(unsafe) var failures = 0

func check(_ ok: Bool, _ what: String, _ detail: String = "") {
    print((ok ? "PASS " : "FAIL ") + what + (detail.isEmpty ? "" : "  [\(detail)]"))
    if !ok { failures += 1 }
}

@MainActor
func waitFor(_ seconds: Double = 4, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(40)) }
    return condition()
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    func reset() { lock.lock(); items = []; lock.unlock() }
}

let fixtureRoot = URL(fileURLWithPath: homePath())

@discardableResult
func makeFile(_ rel: String, mb: Int = 0, bytes: Int? = nil, daysOld: Double = 0, text: String? = nil) -> URL {
    let url = fixtureRoot.appendingPathComponent(rel)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = text.map { Data($0.utf8) } ?? Data(repeating: 7, count: bytes ?? (mb << 20))
    FileManager.default.createFile(atPath: url.path, contents: data)
    if daysOld > 0 {
        let d = Date().addingTimeInterval(-daysOld * 86400)
        try? FileManager.default.setAttributes([.modificationDate: d, .creationDate: d], ofItemAtPath: url.path)
    }
    return url
}

func wipeFixture() {
    for n in (try? FileManager.default.contentsOfDirectory(atPath: fixtureRoot.path)) ?? [] {
        try? FileManager.default.removeItem(at: fixtureRoot.appendingPathComponent(n))
    }
}
