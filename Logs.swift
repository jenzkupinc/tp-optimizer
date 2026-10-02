import SwiftUI
import AppKit

enum Undo: Codable, Equatable {
    case wakeStartup(domain: String, label: String, plist: String, system: Bool)
    case unblockDomain(String)
    case unblockApp(String)

    var title: String {
        switch self {
        case .wakeStartup: "Despertar"
        case .unblockDomain: "Desbloquear"
        case .unblockApp: "Permitir"
        }
    }
}

struct LogEntry: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let text: String
    var undo: Undo?
    var undone = false
}

@MainActor
final class Journal: ObservableObject {
    static let shared = Journal()
    @Published var entries: [LogEntry] = []
    private let url = URL(fileURLWithPath: appSupport + "/bitacora.json")

    init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([LogEntry].self, from: data) { entries = saved }
    }

    func add(_ text: String, undo: Undo? = nil) {
        entries.insert(LogEntry(date: Date(), text: text, undo: undo), at: 0)
        if entries.count > 3000 { entries.removeLast(entries.count - 3000) }
        save()
    }

    func revert(_ entry: LogEntry) async {
        guard let undo = entry.undo else { return }
        let ok: Bool
        switch undo {
        case let .wakeStartup(domain, label, plist, system): ok = await Task.detached { StartupModel.wake(domain: domain, label: label, plist: plist, system: system) }.value
        case let .unblockDomain(d): ok = await Hosts.write(Hosts.read().filter { $0 != d })
        case let .unblockApp(path): ok = await Task.detached { Root.run(["fw", "unblock", path]) }.value
        }
        guard ok, let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[i].undone = true
        add("Deshice: \(entry.text)")
    }

    private func save() { try? JSONEncoder().encode(entries).write(to: url) }
}

func record(_ text: String, undo: Undo? = nil) {
    Task { @MainActor in Journal.shared.add(text, undo: undo) }
}

struct CrashGroup: Identifiable {
    var id: String { app }
    let app: String
    let files: [URL]
    let last: Date
    let panic: Bool
}

func findCrashes() -> [CrashGroup] {
    let fm = FileManager.default
    let exts: Set<String> = ["ips", "crash", "hang", "spin", "panic"]
    var byApp: [String: [(URL, Date, Bool)]] = [:]
    for dir in [NSHomeDirectory() + "/Library/Logs/DiagnosticReports", "/Library/Logs/DiagnosticReports"] {
        for url in (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
        where exts.contains(url.pathExtension) {
            var name = url.deletingPathExtension().lastPathComponent
            if let r = name.range(of: #"[-_]\d{4}-\d{2}-\d{2}"#, options: .regularExpression) { name = String(name[..<r.lowerBound]) }
            if url.pathExtension == "ips", let h = try? FileHandle(forReadingFrom: url) {
                let head = String(decoding: (try? h.read(upToCount: 2048)) ?? Data(), as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
                try? h.close()
                guard let json = try? JSONSerialization.jsonObject(with: Data(head.utf8)) as? [String: Any], let app = json["app_name"] as? String else { continue }
                name = app
            }
            let panic = url.pathExtension == "panic" || name.lowercased().hasPrefix("kernel")
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            byApp[panic ? "Reinicio por fallo de macOS" : name, default: []].append((url, date, panic))
        }
    }
    return byApp.map { app, list in
        let sorted = list.sorted { $0.1 > $1.1 }
        return CrashGroup(app: app, files: sorted.map(\.0), last: sorted.first?.1 ?? .distantPast, panic: sorted.first?.2 ?? false)
    }
    .sorted { $0.last > $1.last }
}

@MainActor
final class LiveLog: ObservableObject {
    @Published var lines: [String] = []
    @Published var running = false
    @Published var onlyErrors = true
    @Published var process = ""
    private var task: Process?

    func start() {
        stop()
        var predicate = onlyErrors ? "(messageType == error OR messageType == fault)" : "messageType >= default"
        let name = process.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
        if !name.isEmpty { predicate += " AND process CONTAINS[c] \"\(name)\"" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--style", "compact", "--predicate", predicate]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            let new = text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("Filtering") && !$0.hasPrefix("Timestamp") }
            guard !new.isEmpty else { return }
            Task { @MainActor in
                guard let self else { return }
                self.lines.append(contentsOf: new)
                if self.lines.count > 500 { self.lines.removeFirst(self.lines.count - 500) }
            }
        }
        lines = []
        try? p.run()
        task = p
        running = p.isRunning
    }

    func stop() {
        (task?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        task?.terminate()
        task = nil
        running = false
    }
}

struct JournalPane: View {
    @ObservedObject var j = Journal.shared
    @StateObject private var live = LiveLog()
    @State private var tab = 0
    @State private var crashes: [CrashGroup] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header(title: "Registro", subtitle: "La memoria de la app: cada acción, cada cierre inesperado y lo que macOS cuenta en vivo.")
            Picker("", selection: $tab) {
                Text("Bitácora").tag(0)
                Text("Cuelgues").tag(1)
                Text("En vivo").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            switch tab {
            case 0: journal
            case 1: crashList
            default: liveView
            }
        }
        .padding()
        .task { crashes = await Task.detached { findCrashes() }.value }
        .onDisappear { live.stop() }
    }

    var journal: some View {
        Group {
            if j.entries.isEmpty {
                Placeholder(symbol: "list.bullet.rectangle", text: "Aquí aparecerá cada cosa que haga la app")
            } else {
                List(j.entries) { e in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.text).strikethrough(e.undone)
                            Text(e.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let u = e.undo, !e.undone {
                            Button(u.title) { Task { await j.revert(e) } }.help("Deshace esta acción")
                        }
                    }
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    var crashList: some View {
        Group {
            if crashes.isEmpty {
                Placeholder(symbol: "checkmark.seal", text: "No hay reportes de cuelgues")
            } else {
                List(crashes) { c in
                    HStack {
                        Image(systemName: c.panic ? "exclamationmark.octagon.fill" : "bolt.trianglebadge.exclamationmark")
                            .foregroundStyle(c.panic ? Color.red : .orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.app).fontWeight(.medium)
                            Text("\(plural(c.files.count, "vez", "veces")) · la última \(c.last.formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Ver el último") { if let f = c.files.first { NSWorkspace.shared.open(f) } }.help("Abre el reporte en la app Consola")
                    }
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    var liveView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Solo errores", isOn: $live.onlyErrors).toggleStyle(.checkbox)
                TextField("Filtrar por app o proceso", text: $live.process).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    .onSubmit { live.start() }
                Spacer()
                if live.running {
                    Button("Detener") { live.stop() }
                } else {
                    Button { live.start() } label: { Label("Escuchar", systemImage: "play.fill") }.buttonStyle(PrimaryButton())
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(live.lines.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.caption.monospaced()).textSelection(.enabled).id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                .onChange(of: live.lines.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
            }
        }
    }
}
