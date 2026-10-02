import SwiftUI
import Foundation

struct JuegoRow: Equatable {
    let date: String
    let channel: String
    let median: Double
    let maxMs: Double
    let spikes100: Int
    let answered: Int
    let pps: Int?
}

struct JuegoChannel: Identifiable, Equatable {
    let channel: String
    let rounds: Int
    let median: Double
    let spikesPerMin: Double
    var id: String { channel }
}

struct JuegoSummary: Equatable {
    var channels: [JuegoChannel] = []
    var total = 0
    var inGame = 0
    var noTraffic = 0
}

enum JuegoLog {
    static let header = "fecha,canal,mediana_ms,max_ms,picos100,respondidos,paq_s"
    static let minPPS = 20
    static let lockPath = "/var/run/modo_juego.pid"

    static var csvPath: String { NSHomeDirectory() + "/juego_historial.csv" }

    nonisolated static func parse(_ text: String) -> [JuegoRow] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == header else { return [] }
        return lines.dropFirst().compactMap { line in
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 7, let med = Double(f[2]), let mx = Double(f[3]), let sp = Int(f[4]), let ans = Int(f[5]) else { return nil }
            return JuegoRow(date: f[0], channel: f[1], median: med, maxMs: mx, spikes100: sp, answered: ans, pps: Int(f[6]))
        }
    }

    nonisolated static func summarize(_ rows: [JuegoRow], minPPS: Int = JuegoLog.minPPS) -> JuegoSummary {
        var s = JuegoSummary()
        s.total = rows.count
        s.noTraffic = rows.filter { ($0.pps ?? 0) == 0 }.count
        let game = rows.filter { $0.answered >= 55 && ($0.pps ?? 0) >= minPPS }
        s.inGame = game.count
        s.channels = Dictionary(grouping: game, by: \.channel).map { ch, list in
            JuegoChannel(channel: ch, rounds: list.count,
                         median: list.reduce(0) { $0 + $1.median } / Double(list.count),
                         spikesPerMin: Double(list.reduce(0) { $0 + $1.spikes100 }) / Double(list.count) * 2)
        }.sorted { $0.spikesPerMin < $1.spikesPerMin }
        return s
    }

    nonisolated static func load(path: String = JuegoLog.csvPath) -> JuegoSummary? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let rows = parse(String(decoding: data, as: UTF8.self))
        return rows.isEmpty ? nil : summarize(rows)
    }

    nonisolated static func scriptPID(lock: String = JuegoLog.lockPath) -> Int? {
        guard let text = try? String(contentsOfFile: lock, encoding: .utf8),
              let pid = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return nil }
        return kill(pid_t(pid), 0) == 0 || errno == EPERM ? pid : nil
    }
}

struct GameJuegoCard: View {
    let summary: JuegoSummary?

    var body: some View {
        if let s = summary {
            VStack(alignment: .leading, spacing: 8) {
                Text("Historial de partidas").font(.headline)
                Text("\(s.total) rondas de 30 s: \(s.inGame) en partida, \(s.noTraffic) sin tráfico medido" + (s.inGame == 0 ? " (las del 30-sep midieron 0 paquetes por un error ya corregido)." : "."))
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(s.channels) { c in
                    HStack(spacing: 10) {
                        Text("Canal \(c.channel)").fontWeight(.medium).frame(width: 84, alignment: .leading)
                        Text(plural(c.rounds, "ronda", "rondas")).frame(width: 84, alignment: .leading).foregroundStyle(.secondary)
                        Text("mediana \(ms(c.median)) ms · \(ms(c.spikesPerMin)) picos de más de 100 ms por minuto").foregroundStyle(.secondary).lineLimit(1)
                    }
                    .font(.callout.monospacedDigit())
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(16)
        }
    }
}
