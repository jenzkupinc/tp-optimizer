import Foundation
import SwiftUI

var failures = 0
func check(_ ok: Bool, _ what: String, _ detail: String = "") {
    print((ok ? "PASS " : "FAIL ") + what + (detail.isEmpty ? "" : "  [\(detail)]"))
    if !ok { failures += 1 }
}

func peer(_ id: String, _ name: String) -> Peer { Peer(id: id, name: name, mac: "aa:bb:cc:dd:ee:" + id.suffix(2)) }

let ipad = peer("192.168.2.3", "iPad de Ana"), iphone = peer("192.168.2.4", "iPhone"), watch = peer("192.168.2.5", "Watch")
check(GameLink.pickPeer([iphone, ipad, watch], chosen: nil)?.id == ipad.id, "elige al iPad por su nombre aunque no sea el primero")
check(GameLink.pickPeer([iphone, watch], chosen: nil) == nil, "con iPhone y Watch pero sin iPad no adivina: no hay iPad")
check(GameLink.pickPeer([iphone, watch], chosen: "192.168.2.9") == nil, "si el equipo elegido ya no está y no hay iPad, no mide otro")
check(GameLink.pickPeer([iphone, ipad], chosen: iphone.id)?.id == iphone.id, "respeta el equipo que el usuario eligió a mano")
check(GameLink.pickPeer([peer("192.168.2.7", "Dispositivo")], chosen: nil)?.id == "192.168.2.7", "con un solo equipo y sin nombre, usa ese")
check(GameLink.pickPeer([], chosen: nil) == nil, "sin equipos conectados devuelve nada")

let now = Date()
check(GameLink.rebootedSince(now.timeIntervalSince1970 - 7200, now: now, uptime: 3600), "si la Mac arrancó después de la última vez que se vio la sesión, hubo reinicio")
check(!GameLink.rebootedSince(now.timeIntervalSince1970 - 600, now: now, uptime: 3600), "si la Mac lleva encendida desde antes, no hubo reinicio")

check(GameLink.validTarget("1.1.1.1") && GameLink.validTarget("example.com"), "acepta una IP y un dominio como destino del ping")
check(!GameLink.validTarget("1.1.1.1; rm -rf ~") && !GameLink.validTarget("$(whoami)") && !GameLink.validTarget(""), "rechaza destinos con comandos o vacíos")

let even = (0..<12).map { Date(timeIntervalSince1970: 1_000 + Double($0) * 7.5) }
let jumpy: [Date] = [0, 1.2, 9.9, 10.4, 31, 31.5, 47, 60, 61, 80, 83, 99].map { Date(timeIntervalSince1970: 1_000 + $0) }
check(GameLink.isRhythmic(even), "detecta saltos a ritmo regular")
check(!GameLink.isRhythmic(jumpy), "no llama regular a saltos desparejos")

func dup(_ n: String, _ selected: Bool) -> DupFile { var f = DupFile(url: URL(fileURLWithPath: "/tmp/\(n)"), size: 10, date: Date()); f.selected = selected; return f }
check(DupGroup(files: [dup("a", false), dup("b", true)]).keepsOne, "un grupo con una copia sin marcar conserva una")
check(!DupGroup(files: [dup("a", true), dup("b", true)]).keepsOne, "un grupo con todas las copias marcadas NO conserva ninguna")

await MainActor.run {
    let d = Duplicates()
    d.groups = [DupGroup(files: [dup("a", true), dup("b", true)])]
    check(!d.everyGroupKeepsOne, "Duplicados detecta que perdería el archivo")
}
await MainActor.run {
    let d = Duplicates()
    d.groups = [DupGroup(files: [dup("a", true), dup("b", true)])]
    let before = d.groups.count
    Task { @MainActor in
        await d.removeSelected()
        check(d.groups.count == before && d.status.contains("desmarca"), "removeSelected se niega y explica por qué", d.status)
    }
}
try? await Task.sleep(for: .milliseconds(300))

await MainActor.run {
    let g = GameLink()
    g.apply(.competitive)
    check(g.profile == .competitive && !g.awdlDuringGame, "Competitivo se reconoce y deja AirDrop como está")
    g.apply(.balanced)
    check(g.profile == .balanced, "Equilibrado se reconoce")
    g.apply(.saver)
    check(g.profile == .saver, "Solo medir se reconoce")
    g.apply(.competitive); g.awdlDuringGame = true
    check(g.profile == nil, "si el usuario enciende AirDrop aparte, deja de ser un perfil puro")
    g.apply(.saver)
}

var a = Vitals(); a.freePct = 60; a.freeBytes = 120_000_000
var b = Vitals(); b.freePct = 60; b.freeBytes = 3_020_000_000
let jump = Boost.summaryText(before: a, after: b, trashed: 0, emptied: nil, relieved: [], admin: true)
check(jump.contains("se mantuvo en 60%") && jump.contains("Memoria libre al instante"), "Boost profundo muestra la memoria libre al instante aunque el porcentaje no se mueva", jump)
b.freeBytes = 150_000_000
check(!Boost.summaryText(before: a, after: b, trashed: 0, emptied: nil, relieved: [], admin: nil).contains("al instante"), "sin cambio real de memoria no inventa una mejora")
check(Boost.summaryText(before: nil, after: nil, trashed: 0, emptied: nil, relieved: [], admin: false).contains("Sin permiso de administrador"), "sin permiso lo dice")
check(Boost.summaryText(before: nil, after: nil, trashed: 5_000_000, emptied: false, relieved: ["X"], admin: nil).contains("esperan en la Papelera"), "lo movido a la Papelera no se cuenta como liberado")

check(Item.protectedNames.contains("Claude") && Item.protectedNames.contains("claude"), "Claude no recibe respiro")
check(!formatBytes(1_500_000).isEmpty && plural(1, "app", "apps") == "1 app" && plural(3, "app", "apps") == "3 apps", "formatos básicos de bytes y plurales")

print("\n" + (failures == 0 ? "TODO OK" : "FALLAS: \(failures)"))
exit(failures == 0 ? 0 : 1)
