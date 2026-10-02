import SwiftUI
import AppKit
import ServiceManagement

struct Script: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var command: String
}

@MainActor
final class Scripts: ObservableObject {
    @Published var list: [Script] { didSet { UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: "scripts") } }
    @Published var running: UUID?
    @Published var output = ""

    init() {
        list = (UserDefaults.standard.data(forKey: "scripts").flatMap { try? JSONDecoder().decode([Script].self, from: $0) })
            ?? []
    }

    func run(_ s: Script) async {
        running = s.id
        output = "$ \(s.command)\n"
        let out = await shellAsync("cd ~ && \(s.command) 2>&1")
        output += out.isEmpty ? "(sin salida)" : out
        running = nil
        record("Corrí el script \(s.name)")
    }
}

struct TelegramConfig: Codable {
    var token: String
    var chatID: Int64?
    var botName: String?
    var alerts = true
}

@MainActor
final class TelegramBot: ObservableObject {
    static let shared = TelegramBot()
    @Published var config: TelegramConfig?
    @Published var status = ""
    @Published var linking = false
    weak var hub: Hub?
    private var offset: Int64 = 0
    private var loop: Task<Void, Never>?
    private var lastHealthAlert = Date.distantPast
    private let file = URL(fileURLWithPath: appSupport + "/telegram.json")

    init() {
        config = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(TelegramConfig.self, from: $0) }
    }

    private func save() {
        guard let config, let data = try? JSONEncoder().encode(config) else { try? FileManager.default.removeItem(at: file); return }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func call(_ method: String, _ params: [String: Any] = [:], timeout: Double = 15) async -> (Int, [String: Any]?) {
        guard let token = config?.token, let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else { return (0, nil) }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: params)
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (0, nil) }
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, try? JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func link(token: String) async {
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.range(of: #"^\d+:[A-Za-z0-9_-]{30,}$"#, options: .regularExpression) != nil else { status = "Esa clave no tiene el formato de un bot de Telegram."; return }
        loop?.cancel()
        config = TelegramConfig(token: clean)
        let (code, me) = await call("getMe")
        guard code == 200, let user = (me?["result"] as? [String: Any])?["username"] as? String else {
            status = "Telegram no reconoce esa clave."; config = nil; return
        }
        config?.botName = user
        linking = true
        status = "Abre Telegram y mándale /start a @\(user). Te espero 2 minutos."
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline, linking {
            let (code, r) = await call("getUpdates", ["timeout": 20, "offset": offset], timeout: 30)
            if code == 409 { status = "Otro programa ya usa este bot. Crea uno nuevo con @BotFather solo para la Mac."; linking = false; config = nil; return }
            for u in (r?["result"] as? [[String: Any]]) ?? [] {
                offset = ((u["update_id"] as? NSNumber)?.int64Value ?? offset) + 1
                if let chat = ((u["message"] as? [String: Any])?["chat"] as? [String: Any])?["id"] as? NSNumber {
                    config?.chatID = chat.int64Value
                    linking = false
                    save()
                    record("Vinculé Telegram con @\(user)")
                    await send("TP Optimizer quedó vinculado. Escribe /ayuda para ver los comandos.")
                    status = "Vinculado con @\(user)."
                    startLoop()
                    return
                }
            }
        }
        if linking { status = "No llegó ningún mensaje. Vuelve a intentarlo."; linking = false; config = nil }
    }

    func unlink() {
        loop?.cancel()
        config = nil
        save()
        status = "Telegram desvinculado."
        record("Desvinculé Telegram")
    }

    func setAlerts(_ on: Bool) { config?.alerts = on; save() }

    func send(_ text: String) async {
        guard let id = config?.chatID else { return }
        _ = await call("sendMessage", ["chat_id": id, "text": text])
    }

    func alert(_ text: String) {
        guard config?.alerts == true else { return }
        Task { await send("⚠️ " + text) }
    }

    func startIfConfigured() { if config?.chatID != nil { startLoop() } }

    private func startLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let (code, r) = await self.call("getUpdates", ["timeout": 25, "offset": self.offset], timeout: 35)
                if code == 409 { self.status = "Otro programa está leyendo este mismo bot. Usa un bot solo para la Mac."; try? await Task.sleep(for: .seconds(60)); continue }
                if code != 200 { try? await Task.sleep(for: .seconds(15)); continue }
                for u in (r?["result"] as? [[String: Any]]) ?? [] {
                    self.offset = ((u["update_id"] as? NSNumber)?.int64Value ?? self.offset) + 1
                    guard let msg = u["message"] as? [String: Any], let text = msg["text"] as? String,
                          let chat = (msg["chat"] as? [String: Any])?["id"] as? NSNumber else { continue }
                    guard chat.int64Value == self.config?.chatID else { record("Telegram: ignoré un mensaje de un chat que no es el tuyo"); continue }
                    await self.handle(text.trimmingCharacters(in: .whitespaces).lowercased())
                }
            }
        }
    }

    func watchHealth() {
        guard let hub, config?.alerts == true else { return }
        let r = healthReport(hub.monitor, hub.watch, hub.ssd)
        if r.score < 55, Date().timeIntervalSince(lastHealthAlert) > 3600 {
            lastHealthAlert = Date()
            alert("La salud de la Mac bajó a \(r.score)/100. \(r.tips.prefix(2).joined(separator: ". "))")
        }
    }

    private func handle(_ text: String) async {
        guard let hub else { return }
        let m = hub.monitor
        switch text.split(separator: "@").first.map(String.init) ?? text {
        case "/estado", "/start":
            await m.reload()
            let r = healthReport(m, hub.watch, hub.ssd)
            await send("""
            Salud \(r.score)/100
            RAM disponible \(m.ramFree) · swap \(m.swap)
            CPU \(m.cpuLoad) · temperatura \(m.thermal)
            Disco libre \(m.disk) · SSD \(hub.ssd.connected ? hub.ssd.free + " libres" : "desconectado")
            Modo noche \(hub.night.on ? "encendido" : "apagado")
            \(r.tips.joined(separator: "\n"))
            """)
        case "/respiro":
            await m.reload(); m.breathe(); await send(m.status)
        case "/normal":
            m.restoreAll(); await send(m.status)
        case "/noche":
            if !hub.night.on { await hub.night.start(m) }; await send(m.status)
        case "/dia":
            if hub.night.on { await hub.night.stop(m) }; await send(m.status)
        case "/limpiar":
            await send("Esto manda a la Papelera la basura segura y da respiro. Para confirmar escribe: /limpiar si")
        case "/limpiar si":
            await send(await optimizeAll(m, hub.cleaner))
        case "/reiniciar":
            await send("Para reiniciar la Mac escribe: /reiniciar si. Las apps con algo sin guardar pueden frenarlo.")
        case "/reiniciar si":
            record("Reinicio pedido desde Telegram")
            await send("Reiniciando la Mac.")
            NSAppleScript(source: "tell application \"System Events\" to restart")?.executeAndReturnError(nil)
        default:
            await send("""
            Comandos:
            /estado · salud, RAM, CPU, disco y SSD
            /respiro · baja la prioridad de lo pesado en segundo plano
            /normal · quita el respiro
            /noche · modo noche
            /dia · apaga el modo noche
            /limpiar · basura segura a la Papelera
            /reiniciar · reinicia la Mac
            """)
        }
        record("Telegram: \(text)")
    }
}

struct AutomationPane: View {
    @StateObject private var s = Scripts()
    @ObservedObject var bot = TelegramBot.shared
    @State private var token = ""
    @State private var newName = ""
    @State private var newCommand = ""
    @State private var loginItem = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header(title: "Scripts y Telegram", subtitle: "Tus comandos favoritos a un toque, y tu Mac en el bolsillo desde Telegram.")
            Toggle("Abrir TP Optimizer al encender la Mac", isOn: Binding(get: { loginItem }, set: { on in
                do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
                loginItem = SMAppService.mainApp.status == .enabled
                record(loginItem ? "TP Optimizer abre al encender la Mac" : "TP Optimizer ya no abre al encender la Mac")
            }))
            .help("El respaldo nocturno, los avisos y Telegram solo funcionan con la app abierta")
            HStack(alignment: .top, spacing: 14) {
                scripts
                telegram
            }
        }
        .padding()
    }

    var scripts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scripts").font(.headline)
            ForEach(s.list) { sc in
                HStack {
                    Image(systemName: "terminal").foregroundStyle(Color.brandTeal)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(sc.name).fontWeight(.medium)
                        Text(sc.command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if s.running == sc.id { ProgressView().controlSize(.small) }
                    Button("Correr") { Task { await s.run(sc) } }.disabled(s.running != nil)
                    Button { s.list.removeAll { $0.id == sc.id } } label: { Image(systemName: "trash") }.buttonStyle(.plain).help("Quitar este script")
                }
            }
            HStack {
                TextField("Nombre", text: $newName).textFieldStyle(.roundedBorder).frame(width: 130)
                TextField("Comando, por ejemplo bash ~/mi-script.sh", text: $newCommand).textFieldStyle(.roundedBorder)
                Button("Agregar") { s.list.append(Script(name: newName, command: newCommand)); newName = ""; newCommand = "" }
                    .disabled(newName.isEmpty || newCommand.isEmpty)
            }
            ScrollView {
                Text(s.output.isEmpty ? "La salida aparece aquí" : s.output).font(.caption.monospaced()).foregroundStyle(s.output.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(12)
    }

    var telegram: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Telegram").font(.headline)
            if let c = bot.config, c.chatID != nil {
                Label("Vinculado con @\(c.botName ?? "tu bot")", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Toggle("Avisarme si la Mac está mal, el SSD se desconecta o algo nuevo arranca solo", isOn: Binding(get: { c.alerts }, set: { bot.setAlerts($0) }))
                Text("Escríbele /ayuda a tu bot para ver los comandos. Solo responde a tu chat.").font(.caption).foregroundStyle(.secondary)
                Button("Desvincular", role: .destructive) { bot.unlink() }
            } else {
                Text("1. En Telegram, abre @BotFather y crea un bot nuevo solo para la Mac.\n2. Copia la clave que te da y pégala aquí.\n3. Toca Vincular y mándale /start a tu bot.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                SecureField("Clave del bot", text: $token).textFieldStyle(.roundedBorder)
                Button(bot.linking ? "Esperando tu mensaje…" : "Vincular") { Task { await bot.link(token: token); token = "" } }
                    .buttonStyle(PrimaryButton()).disabled(token.isEmpty || bot.linking)
                Text("La clave se guarda solo en esta Mac.").font(.caption).foregroundStyle(.secondary)
            }
            if !bot.status.isEmpty { Text(bot.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 340)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .card(12)
    }
}
