import SwiftUI
import AppKit

struct Assertion: Identifiable {
    let id = UUID()
    let pid: Int32
    let app: String
    let kind: String
    let reason: String
    let age: String
    var meaning: String {
        switch kind {
        case "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion": "No deja apagar la pantalla"
        case "PreventSystemSleep": "No deja dormir la Mac, ni cerrando la tapa"
        default: "No deja dormir la Mac"
        }
    }
}

func sleepBlockers() -> [Assertion] {
    let blocking: Set<String> = ["PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion", "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]
    return shell("pmset -g assertions").split(separator: "\n").compactMap { line in
        let s = String(line)
        guard let r = s.range(of: #"pid (\d+)\((.+?)\): \[0x[0-9a-f]+\] (\S+) (\S+) named: "(.*)""#, options: .regularExpression) else { return nil }
        let m = s[r]
        let pid = Int32(m.dropFirst(4).prefix { $0.isNumber }) ?? 0
        let app = String(m.split(separator: "(", maxSplits: 1)[1].split(separator: ")")[0])
        let parts = m.split(separator: "]", maxSplits: 1)[1].split(separator: " ", maxSplits: 2)
        guard parts.count == 3, blocking.contains(String(parts[1])) else { return nil }
        let reason = String(parts[2]).replacingOccurrences(of: "named: ", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        return Assertion(pid: pid, app: app, kind: String(parts[1]), reason: reason, age: String(parts[0]))
    }
}

@MainActor
final class PowerModel: ObservableObject {
    private let d = UserDefaults.standard
    @Published var wakeOn = UserDefaults.standard.bool(forKey: "wakeOn") { didSet { d.set(wakeOn, forKey: "wakeOn") } }
    @Published var wakeTime = UserDefaults.standard.object(forKey: "wakeTime") as? Double ?? 7 * 3600 { didSet { d.set(wakeTime, forKey: "wakeTime") } }
    @Published var offOn = UserDefaults.standard.object(forKey: "offOn") as? Bool ?? true { didSet { d.set(offOn, forKey: "offOn") } }
    @Published var offKind = UserDefaults.standard.string(forKey: "offKind") ?? "restart" { didSet { d.set(offKind, forKey: "offKind") } }
    @Published var offTime = UserDefaults.standard.object(forKey: "offTime") as? Double ?? 4 * 3600 { didSet { d.set(offTime, forKey: "offTime") } }
    @Published var schedule: [String] = []
    @Published var blockers: [Assertion] = []
    @Published var status = ""

    func refresh() async {
        let (sched, list) = await Task.detached { (shell("pmset -g sched"), sleepBlockers()) }.value
        schedule = sched.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasSuffix(":") }
        blockers = list
    }

    static func clock(_ seconds: Double) -> String { String(format: "%02d:%02d:00", Int(seconds) / 3600, Int(seconds) % 3600 / 60) }

    func apply() {
        var parts: [String] = [], args = ["schedule"]
        if wakeOn { parts.append("wakeorpoweron MTWRFSU \(PowerModel.clock(wakeTime))"); args += ["wakeorpoweron", "MTWRFSU", PowerModel.clock(wakeTime)] }
        if offOn { parts.append("\(offKind) MTWRFSU \(PowerModel.clock(offTime))"); args += [offKind, "MTWRFSU", PowerModel.clock(offTime)] }
        let call = args
        Task {
            if await Task.detached(operation: { Root.run(call) }).value {
                status = parts.isEmpty ? "Horario borrado." : "Horario guardado."
                record(parts.isEmpty ? "Borré el horario de encendido y apagado" : "Horario de la Mac: " + parts.joined(separator: ", "))
            } else { status = "No se guardó el horario." }
            await refresh()
        }
    }
}

struct PowerPane: View {
    @StateObject private var p = PowerModel()
    let timer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header(title: "Energía", subtitle: "El horario de tu Mac y lo que le quita el sueño.")
            VStack(alignment: .leading, spacing: 12) {
                Text("Horario automático").font(.headline)
                HStack {
                    Toggle("Encender o despertar a las", isOn: $p.wakeOn)
                    DatePicker("", selection: time($p.wakeTime), displayedComponents: .hourAndMinute).labelsHidden().disabled(!p.wakeOn)
                    Text("todos los días").foregroundStyle(.secondary)
                }
                HStack {
                    Toggle("", isOn: $p.offOn).labelsHidden()
                    Picker("", selection: $p.offKind) {
                        Text("Reiniciar").tag("restart")
                        Text("Dormir").tag("sleep")
                        Text("Apagar").tag("shutdown")
                    }
                    .labelsHidden().fixedSize().disabled(!p.offOn)
                    Text("a las")
                    DatePicker("", selection: time($p.offTime), displayedComponents: .hourAndMinute).labelsHidden().disabled(!p.offOn)
                    Text("todos los días").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Guardar horario") { p.apply() }.buttonStyle(PrimaryButton()).help("Guarda el horario en la Mac. Si aún no diste el acceso de administrador, macOS pide tu contraseña una sola vez")
                    Text(p.status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                if p.offKind == "restart" && p.offOn {
                    Text("Reiniciar de madrugada vacía el swap. Si un bot está trabajando a esa hora, se corta: elige una hora en la que descansen.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(p.schedule, id: \.self) { Label($0, systemImage: "clock").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(14)
            .card(12)
            Text("Quién no deja dormir a la Mac").font(.headline)
            if p.blockers.isEmpty {
                Placeholder(symbol: "moon.zzz", text: "Nadie. La Mac puede dormir cuando quiera")
            } else {
                List(p.blockers) { a in
                    HStack {
                        Image(nsImage: NSRunningApplication(processIdentifier: a.pid)?.icon ?? NSWorkspace.shared.icon(for: .unixExecutable)).resizable().frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(NSRunningApplication(processIdentifier: a.pid)?.localizedName ?? a.app).fontWeight(.medium)
                            Text("\(a.meaning) · hace \(humanAge(a.age))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(a.reason).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 320, alignment: .trailing)
                    }
                    .help(a.reason)
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding()
        .task { await p.refresh() }
        .onReceive(timer) { _ in Task { await p.refresh() } }
    }

    func time(_ seconds: Binding<Double>) -> Binding<Date> {
        Binding(get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(seconds.wrappedValue) },
                set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); seconds.wrappedValue = Double((c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60) })
    }
}
