import SwiftUI
import AppKit
import Combine

extension Color {
    static let brandNavy = Color(red: 0x1F/255, green: 0x28/255, blue: 0x51/255)
    static let brandTeal = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0, green: 0.784, blue: 0.784, alpha: 1) : NSColor(red: 0.05, green: 0.55, blue: 0.62, alpha: 1)
    })
}

struct Brand: View {
    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let url = Bundle.main.url(forResource: "tp-logo", withExtension: "png"), let img = NSImage(contentsOf: url) {
                    Image(nsImage: img).resizable().scaledToFit().padding(5)
                } else {
                    Text("TP").font(.headline.bold()).foregroundStyle(Color.brandNavy)
                }
            }
            .frame(width: 38, height: 38)
            .background(RoundedRectangle(cornerRadius: 9).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.08)))
            VStack(alignment: .leading, spacing: 0) {
                Text("TP Optimizer").font(.headline)
                Text("by TRIPLAN").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case boost = "Boost", game = "Modo juego", monitor = "Monitor", security = "Seguridad", journal = "Registro"
    case clean = "Limpieza profunda", big = "Archivos grandes", dups = "Duplicados", disks = "Discos y respaldo"
    case profiles = "Perfiles", power = "Energía", network = "Red y router", startup = "Arranque automático", apps = "Desinstalar apps"
    case automation = "Scripts y Telegram"
    var id: String { rawValue }
    static let groups: [(String, [Pane])] = [
        ("Estado", [.boost, .monitor, .security, .journal]),
        ("Gaming", [.game]),
        ("Espacio", [.clean, .big, .dups, .disks]),
        ("Control", [.profiles, .power, .network, .startup, .apps]),
        ("Automatización", [.automation]),
    ]
    var tip: String {
        switch self {
        case .boost: "Un toque: barre la basura segura y le quita peso a lo de fondo"
        case .game: "Latencia en vivo del iPad que usa el Wi-Fi de tu Mac, y lo que puedes hacer para bajarla"
        case .monitor: "Qué está usando tu Mac ahora: apps, procesos, RAM, CPU y temperatura"
        case .security: "Protecciones de macOS, programas sin firma, instalaciones nuevas y accesos a tu Mac"
        case .journal: "Todo lo que hizo TP Optimizer, las apps que se cayeron y el registro de macOS en vivo"
        case .clean: "Cachés, logs viejos e instaladores que se pueden borrar sin perder nada tuyo"
        case .big: "Lo que más pesa y hace tiempo no abres, con opción de mandarlo al SSD"
        case .dups: "Archivos repetidos, comparados por su contenido real"
        case .disks: "Salud de los discos y respaldo nocturno al SSD"
        case .profiles: "Un clic duerme las apps que no necesitas para trabajar o para ver una película"
        case .power: "Horario de encendido y reinicio, y qué no deja dormir a la Mac"
        case .network: "Tu router, los equipos conectados, sitios bloqueados y el firewall"
        case .startup: "Programas que se encienden solos al prender la Mac"
        case .apps: "Quitar apps junto con los restos que dejan"
        case .automation: "Tus scripts a un clic y la Mac manejada desde Telegram"
        }
    }
    var symbol: String {
        switch self {
        case .boost: "wand.and.sparkles"
        case .game: "gamecontroller.fill"
        case .monitor: "gauge.with.dots.needle.67percent"
        case .security: "lock.shield"
        case .journal: "list.bullet.rectangle"
        case .clean: "sparkles"
        case .big: "externaldrive.badge.questionmark"
        case .dups: "doc.on.doc"
        case .disks: "internaldrive"
        case .profiles: "square.stack.3d.up"
        case .power: "powersleep"
        case .network: "wifi.router"
        case .startup: "moon.zzz"
        case .apps: "square.grid.2x2"
        case .automation: "terminal"
        }
    }
}

@MainActor
final class Hub: ObservableObject {
    let monitor = Monitor()
    let watch = StartupWatch()
    let ssd = SSDWatch()
    let night = NightMode()
    let cleaner = Cleaner()
    let backup = BackupModel()
    let installs = InstallWatch()
    let boost = Boost()
    let live = LiveStats()
    let game = GameLink()
    static weak var current: Hub?

    init() {
        Hub.current = self
        game.monitor = monitor
        Task {
            try? await Task.sleep(for: .seconds(2))
            await game.resume(monitor)
        }
        Task.detached {
            guard Root.installed, !Root.ready() else { return }
            let asked = UserDefaults.standard.double(forKey: "rootAskedAt")
            let mayAsk = Date().timeIntervalSince1970 - asked > 3600
            if mayAsk { UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "rootAskedAt") }
            _ = Root.refresh(canPrompt: mayAsk)
        }
        TelegramBot.shared.hub = self
        TelegramBot.shared.startIfConfigured()
        backup.start()
    }
}

struct Header: View {
    let title: String, subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(.largeTitle, design: .default, weight: .bold)).tracking(-0.6)
            Text(subtitle).font(.callout).foregroundStyle(.secondary).tracking(-0.1).lineLimit(2)
        }
        .padding(.bottom, 2)
    }
}

struct StatCard: View {
    let title: String, value: String, symbol: String
    var tip = ""
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.brandTeal).frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(value).font(.title3.bold().monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .card(12)
        .help(tip)
    }
}

struct StatChip: View {
    let title: String, value: String, symbol: String
    var tint: Color = .brandTeal
    var tip = ""
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text(value).font(.callout.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(tip)
    }
}

struct Placeholder: View {
    let symbol: String, text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(Color.brandTeal.opacity(0.7))
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RootView: View {
    let hub: Hub
    @StateObject private var profiles = Profiles()
    @StateObject private var big = BigFiles()
    @StateObject private var dups = Duplicates()
    @StateObject private var apps = AppsModel()
    @StateObject private var startup = StartupModel()
    @State private var pane: Pane? = .boost
    @AppStorage("appearance") private var appearance = 0

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                ForEach(Pane.groups, id: \.0) { group in
                    Text(group.0.uppercased())
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .tracking(0.4)
                        .padding(.top, 10).padding(.leading, 4)
                        .selectionDisabled()
                    ForEach(group.1) { p in Label(p.rawValue, systemImage: p.symbol).tag(p).help(p.tip) }
                }
            }
            .safeAreaInset(edge: .top) { Brand() }
            .navigationSplitViewColumnWidth(min: 210, ideal: 220, max: 260)
        } detail: {
            switch pane ?? .boost {
            case .boost: BoostPane(b: hub.boost, m: hub.monitor, live: hub.live)
            case .game: GamePane(g: hub.game, m: hub.monitor)
            case .monitor: MonitorView(m: hub.monitor, watch: hub.watch, ssd: hub.ssd, night: hub.night, cleaner: hub.cleaner)
            case .security: SecurityPane(installs: hub.installs)
            case .journal: JournalPane()
            case .clean: CleanerView(c: hub.cleaner)
            case .big: BigFilesView(b: big)
            case .dups: DuplicatesView(d: dups)
            case .disks: DisksPane(backup: hub.backup)
            case .profiles: ProfilesView(p: profiles, m: hub.monitor)
            case .power: PowerPane()
            case .network: NetworkPane()
            case .startup: StartupView(s: startup, watch: hub.watch)
            case .apps: AppsView(a: apps)
            case .automation: AutomationPane()
            }
        }
        .modifier(HideTitle())
        .toolbar {
            Picker("Apariencia", selection: $appearance) {
                Image(systemName: "circle.lefthalf.filled").tag(0)
                Image(systemName: "sun.max").tag(1)
                Image(systemName: "moon").tag(2)
            }
            .pickerStyle(.segmented)
            .help("Sistema · Claro · Oscuro")
        }
        .preferredColorScheme(appearance == 1 ? .light : appearance == 2 ? .dark : nil)
        .tint(Color.brandTeal)
    }
}

struct Card: ViewModifier {
    var radius: CGFloat = 14
    var tint: Color?
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(tint.map { .regular.tint($0.opacity(0.28)) } ?? .regular, in: .rect(cornerRadius: radius))
        } else {
            content
                .background(RoundedRectangle(cornerRadius: radius).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: radius).stroke(Color.primary.opacity(0.08)))
        }
    }
}

extension View {
    func card(_ radius: CGFloat = 14, tint: Color? = nil) -> some View { modifier(Card(radius: radius, tint: tint)) }
}

struct HideTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.toolbar(removing: .title) } else { content }
    }
}

struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration, enabled: enabled, dark: scheme == .dark)
    }
}

private struct PrimaryButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let enabled: Bool
    let dark: Bool
    @State private var hover = false
    var body: some View {
        let base = dark ? Color.brandTeal : Color.brandNavy
        let fill = base.opacity(enabled ? (configuration.isPressed ? 0.82 : hover ? 0.92 : 1) : 0.4)
        return configuration.label
            .fontWeight(.semibold)
            .foregroundStyle(dark ? Color.brandNavy : .white)
            .padding(.horizontal, 13).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(hover ? 0.3 : (dark ? 0.12 : 0.18))))
            .scaleEffect(configuration.isPressed ? 0.97 : hover ? 1.02 : 1)
            .onHover { if enabled { hover = $0 } }
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: hover)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
