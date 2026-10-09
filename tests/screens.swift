import Foundation
import AppKit

private func mkApp(_ dir: String, _ file: String, id: String?, name: String? = nil) -> URL {
    var plist = ""
    if let id { plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>\(id)</string>" + (name.map { "<key>CFBundleName</key><string>\($0)</string>" } ?? "") + "</dict></plist>" }
    let app = fixtureRoot.appendingPathComponent(dir + "/" + file + ".app")
    try? FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    if id != nil { FileManager.default.createFile(atPath: app.appendingPathComponent("Contents/Info.plist").path, contents: Data(plist.utf8)) }
    FileManager.default.createFile(atPath: app.appendingPathComponent("Contents/MacOS/" + file).path, contents: Data("x".utf8))
    return app
}

private func installed(_ app: URL, id: String, name: String, leftovers: [URL] = []) -> InstalledApp {
    InstalledApp(id: app, name: name, bundleID: id, icon: NSImage(), size: 1, leftovers: leftovers, leftoverSize: 0, lastUsed: nil)
}

@MainActor
func screenTests() async {
    await cleaningTests()
    await uninstallTests()
    await startupTests()
}

@MainActor
private func cleaningTests() async {
    wipeFixture()
    makeFile("Library/Caches/com.fake.big/data", mb: 21)
    makeFile("Library/Caches/com.fake.small/data", mb: 1)
    makeFile("Library/Caches/com.apple.thing/data", mb: 21)
    makeFile("Library/Caches/ms-playwright/data", mb: 21)
    makeFile("Library/Logs/vieja.log", bytes: 100, daysOld: 20)
    makeFile("Library/Logs/reciente.log", bytes: 100)
    makeFile("Library/Logs/optimizer.log", bytes: 100, daysOld: 40)
    makeFile("Downloads/vieja.bin", mb: 6, daysOld: 70)
    makeFile("Downloads/vieja.dmg", mb: 6, daysOld: 70)
    makeFile("Downloads/chica.bin", mb: 1, daysOld: 70)
    makeFile("Downloads/reciente.bin", mb: 6)
    makeFile("Documents/importante.bin", mb: 30, daysOld: 400)
    makeFile("Desktop/foto.bin", mb: 30, daysOld: 400)

    let found = Cleaner.find(running: [])
    let titles = found.map(\.title)
    check(titles.contains { $0.contains("com.fake.big") }, "Limpieza encuentra una caché grande de una app")
    check(!titles.contains { $0.contains("com.fake.small") }, "Limpieza ignora una caché chica")
    check(!titles.contains { $0.contains("com.apple.thing") || $0.contains("ms-playwright") }, "Limpieza no toca cachés de Apple ni las de Playwright")
    check(found.first { $0.title.contains("com.fake.big") }?.selected == true, "la caché de una app cerrada viene marcada")
    let busy = Cleaner.find(running: ["com.fake.big"]).first { $0.title.contains("com.fake.big") }
    check(busy?.selected == false && busy?.detail.contains("abierta") == true, "si la app está abierta, la caché no viene marcada y avisa", busy?.detail ?? "")
    let logs = found.first { $0.title == "Logs viejos" }
    check(logs?.urls.map(\.lastPathComponent) == ["vieja.log"], "solo cuenta logs de más de 14 días y nunca optimizer.log", logs?.urls.map(\.lastPathComponent).joined(separator: ",") ?? "sin logs")
    check(found.first { $0.title.contains("vieja.dmg") }?.selected == false, "un instalador viejo viene SIN marcar")
    check(!titles.contains { $0.contains("chica.bin") || $0.contains("reciente.bin") }, "no propone descargas chicas ni recientes")
    check(!found.flatMap(\.urls).contains { $0.path.contains("/Documents/") || $0.path.contains("/Desktop/") }, "Limpieza jamás propone nada de Documentos ni del Escritorio")

    let c = Cleaner()
    let moves = Counter()
    Hooks.recycle = { urls in moves.add("\(urls.count)"); return urls.count }
    c.items = []
    await c.clean()
    check(moves.all.isEmpty, "sin nada marcado, Limpieza no mueve nada")
    c.items = [Junk(title: "A", detail: "", urls: [fixtureRoot.appendingPathComponent("a"), fixtureRoot.appendingPathComponent("b")], size: 10, selected: true),
               Junk(title: "B", detail: "", urls: [fixtureRoot.appendingPathComponent("c")], size: 10, selected: false)]
    await c.clean()
    check(moves.all == ["2"], "Limpieza solo manda lo marcado", moves.all.joined(separator: ","))
    _ = await waitFor { !c.scanning }
    check(c.status.hasPrefix("Listo: 2 elementos"), "y el aviso «Listo: 2 elementos» no se pisa con el nuevo escaneo", c.status)
    Hooks.recycle = { urls in max(0, urls.count - 1) }
    c.items = [Junk(title: "A", detail: "", urls: [fixtureRoot.appendingPathComponent("a"), fixtureRoot.appendingPathComponent("b")], size: 10, selected: true)]
    await c.clean()
    _ = await waitFor { !c.scanning }
    check(c.status.hasPrefix("Pude mover 1 de 2"), "si macOS mueve menos de lo pedido, dice «1 de 2» y no «listo»", c.status)
    Hooks.recycle = nil

    Hooks.emptyTrash = { false }
    c.emptyTrashNow()
    check(c.status.contains("No pude vaciar"), "si Finder no deja vaciar la Papelera, lo dice", c.status)
    Hooks.emptyTrash = { true }
    c.emptyTrashNow()
    check(c.status == "Papelera vacía.", "si se vació, lo dice", c.status)
    Hooks.emptyTrash = nil

    let t1 = makeFile(".Trash/vieja1.bin", bytes: 10), t2 = makeFile(".Trash/vieja2.bin", bytes: 10)
    c.oldTrash = [t1, t2]
    c.emptyOldTrash()
    check(!FileManager.default.fileExists(atPath: t1.path) && !FileManager.default.fileExists(atPath: t2.path) && c.status.contains("2 elementos"), "borrar lo viejo de la Papelera borra y cuenta lo que borró", c.status)
}

@MainActor
private func uninstallTests() async {
    wipeFixture()
    let foo = mkApp("Apps", "Foo", id: "com.fake.foo", name: "Foo")
    let fooBar = mkApp("Apps", "FooBar", id: "com.fake.foobar", name: "FooBar")
    _ = mkApp("Apps", "Bar", id: "com.apple.bar")
    _ = mkApp("Apps", "SinPlist", id: nil)
    let l1 = makeFile("Library/Application Support/com.fake.foo/datos", bytes: 10)
    let l2 = makeFile("Library/Preferences/com.fake.foo.plist", bytes: 10)
    let l3 = makeFile("Library/Caches/Foo/x", bytes: 10)
    let other = makeFile("Library/Application Support/com.fake.foobar/datos", bytes: 10)

    let apps = AppsModel.find(dirs: [fixtureRoot.appendingPathComponent("Apps").path])
    check(Set(apps.map(\.bundleID)) == ["com.fake.foo", "com.fake.foobar"], "Desinstalar lista las apps normales y no las de Apple ni las que no tienen Info.plist", apps.map(\.bundleID).sorted().joined(separator: ","))
    let fooLeft = Set(apps.first { $0.bundleID == "com.fake.foo" }?.leftovers.map(\.path) ?? [])
    check(fooLeft == [l1.deletingLastPathComponent().path, l2.path, l3.deletingLastPathComponent().path], "encuentra los restos de la app por su identificador y por su nombre", fooLeft.map { ($0 as NSString).lastPathComponent }.sorted().joined(separator: ","))
    check(!fooLeft.contains(other.deletingLastPathComponent().path), "NO confunde los datos de «com.fake.foobar» con los de «com.fake.foo»")

    let model = AppsModel()
    let moves = Counter()
    Hooks.deletable = { _ in true }
    Hooks.recycle = { urls in moves.add("recycle \(urls.count)"); for u in urls { try? FileManager.default.removeItem(at: u) }; return urls.count }
    await model.uninstall(installed(URL(fileURLWithPath: "/Applications/Claude.app"), id: "com.anthropic.claudefordesktop", name: "Claude"))
    check(moves.all.isEmpty && model.status.contains("no se desinstala"), "Claude, la app de esta sesión, no se desinstala desde aquí", model.status)

    model.apps = apps
    let fooApp = apps.first { $0.bundleID == "com.fake.foo" }!
    await model.uninstall(fooApp)
    check(model.status.contains("desinstalada: 4 elementos") && !FileManager.default.fileExists(atPath: foo.path) && !model.apps.contains { $0.bundleID == "com.fake.foo" }, "desinstalar una app normal la manda a la Papelera con sus restos y la quita de la lista", model.status)
    check(FileManager.default.fileExists(atPath: other.path) && FileManager.default.fileExists(atPath: fooBar.path), "y no toca los datos ni la app de otra con nombre parecido")

    let foo2 = mkApp("Apps2", "Foo2", id: "com.fake.foo2", name: "Foo2")
    let r1 = makeFile("Library/Preferences/com.fake.foo2.plist", bytes: 10)
    Hooks.recycle = { urls in for u in urls where u == foo2 { try? FileManager.default.removeItem(at: u) }; return 1 }
    await model.uninstall(installed(foo2, id: "com.fake.foo2", name: "Foo2", leftovers: [r1, r1, r1]))
    check(model.status.contains("quedan restos") && model.status.contains("1 de 4"), "si la app salió pero faltaron restos, lo dice con la cuenta", model.status)

    let foo3 = mkApp("Apps3", "Foo3", id: "com.fake.foo3", name: "Foo3")
    Hooks.recycle = { _ in 0 }
    let before = model.apps.count
    model.apps.append(installed(foo3, id: "com.fake.foo3", name: "Foo3"))
    await model.uninstall(installed(foo3, id: "com.fake.foo3", name: "Foo3"))
    check(model.status.contains("No pude mover") && model.apps.count == before + 1, "si la app sigue ahí, dice que no pudo y la deja en la lista", model.status)

    let root = mkApp("Apps4", "Root", id: "com.fake.root", name: "Root")
    let shellLog = Counter()
    Hooks.deletable = { _ in false }
    Hooks.recycle = { urls in moves.add("recycle \(urls.count)"); return urls.count }
    Hooks.shell = { cmd in
        shellLog.add(cmd)
        if cmd.hasSuffix("version 2>/dev/null") { return ("\(Root.version)\n", 0) }
        if cmd.contains("'uninstall'") { try? FileManager.default.removeItem(at: root); return ("", 0) }
        return ("", 0)
    }
    moves.reset()
    await model.uninstall(installed(root, id: "com.fake.root", name: "Root"))
    let helperCmd = shellLog.all.first { $0.contains("'uninstall'") } ?? ""
    check(helperCmd.contains("/usr/bin/sudo -n") && helperCmd.contains(Root.helper) && helperCmd.contains("'\(root.path)'"), "una app de root se desinstala con el ayudante, sin pedir contraseña (sudo -n)", helperCmd)
    check(model.status.contains("desinstalada"), "y lo cuenta cuando salió bien", model.status)

    let stuck = mkApp("Apps5", "Stuck", id: "com.fake.stuck", name: "Stuck")
    Hooks.shell = { cmd in
        if cmd.hasSuffix("version 2>/dev/null") { return ("\(Root.version)\n", 0) }
        return ("", cmd.contains("'uninstall'") ? 1 : 0)
    }
    await model.uninstall(installed(stuck, id: "com.fake.stuck", name: "Stuck"))
    check(model.status.contains("No pude mover") && FileManager.default.fileExists(atPath: stuck.path), "si el ayudante falla, lo dice y la app sigue ahí", model.status)
    Hooks.shell = nil; Hooks.recycle = nil; Hooks.deletable = nil
}

@MainActor
private func startupTests() async {
    wipeFixture()
    let dir = fixtureRoot.appendingPathComponent("Library/LaunchAgents")
    func plist(_ file: String, label: String?, args: [String] = ["/bin/echo", "hola"]) {
        let body = (label.map { "<key>Label</key><string>\($0)</string>" } ?? "") + "<key>ProgramArguments</key><array>" + args.map { "<string>\($0)</string>" }.joined() + "</array><key>StandardOutPath</key><string>/tmp/x.log</string>"
        makeFile("Library/LaunchAgents/\(file)", text: "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict>\(body)</dict></plist>")
    }
    let mine = StartupModel.minePrefixes[0] + "agente"
    plist("a.plist", label: "com.fake.alpha")
    plist("m.plist", label: mine)
    plist("apple.plist", label: "com.apple.skip")
    plist("sin-label.plist", label: nil)
    makeFile("Library/LaunchAgents/roto.plist", text: "esto no es un plist")
    Hooks.shell = { cmd in
        if cmd.contains("print-disabled gui") { return ("disabled services = {\n\t\"com.fake.alpha\" => disabled\n\t\"\(mine)\" => enabled\n}\n", 0) }
        if cmd.hasPrefix("launchctl list") { return ("PID\tStatus\tLabel\n321\t0\t\(mine)\n-\t0\tcom.fake.alpha\n", 0) }
        return ("", 0)
    }
    let items = StartupModel.find(dirs: [(dir.path, false)])
    let by = Dictionary(uniqueKeysWithValues: items.map { ($0.label, $0) })
    check(by["com.apple.skip"] == nil, "Arranque ignora los elementos de Apple")
    check(by["com.fake.alpha"]?.disabled == true && by["com.fake.alpha"]?.running == false, "reconoce un arranque dormido que no está corriendo")
    check(by[mine]?.running == true && by[mine]?.disabled == false && by[mine]?.mine == true, "reconoce uno propio que está corriendo y despierto")
    check(by["sin-label"] != nil, "si el plist no trae Label, usa el nombre del archivo")
    check(by["roto"]?.readable == false, "un plist ilegible se marca como ilegible")
    check(items.first?.mine == true, "los propios salen primero")

    let alpha = by["com.fake.alpha"]!
    let log = Counter()
    Hooks.shell = { cmd in log.add(cmd); return ("", 0) }
    check(StartupModel.wake(domain: alpha.domain, label: alpha.label, plist: alpha.plist.path, system: false), "despertar un arranque de usuario sale bien si launchctl lo confirma")
    let wakeCmd = log.all.last ?? ""
    check(wakeCmd.contains("launchctl enable '\(alpha.domain)/com.fake.alpha'") && wakeCmd.hasSuffix("launchctl print '\(alpha.domain)/com.fake.alpha' >/dev/null 2>&1"), "despertar usa la etiqueta entre comillas y termina comprobando con launchctl print", wakeCmd)
    Hooks.shell = { _ in ("", 1) }
    check(!StartupModel.wake(domain: alpha.domain, label: alpha.label, plist: alpha.plist.path, system: false), "si launchctl no lo ve cargado, despertar devuelve fallo")

    let model = StartupModel()
    log.reset()
    Hooks.shell = { cmd in log.add(cmd); return ("", 0) }
    model.setAsleep(alpha, true)
    _ = await waitFor { model.status.contains("dormido") }
    check(model.status.contains("dormido") && log.all.contains { $0.contains("launchctl bootout '\(alpha.domain)/com.fake.alpha'") && $0.contains("launchctl disable '\(alpha.domain)/com.fake.alpha'") }, "dormir un arranque hace bootout y disable con la etiqueta entre comillas", model.status)
    Hooks.shell = { _ in ("", 1) }
    model.status = ""
    model.setAsleep(alpha, true)
    _ = await waitFor { !model.status.isEmpty }
    check(model.status.contains("No se pudo cambiar"), "si falla, no dice que quedó dormido", model.status)

    Hooks.shell = { _ in ("", 0) }
    model.status = ""
    model.remove(alpha)
    _ = await waitFor { model.status.contains("eliminado") }
    let backup = URL(fileURLWithPath: StartupModel.backupDir + "/a.plist")
    check(model.status.contains("eliminado") && FileManager.default.fileExists(atPath: backup.path), "eliminar un arranque de usuario guarda antes una copia de su plist", model.status)
    _ = await waitFor { Journal.shared.entries.first?.text.contains("Eliminé el arranque com.fake.alpha") == true }
    check(Journal.shared.entries.first?.text.contains("Su respaldo está") == true, "y el registro dice que hay respaldo, porque lo hay", Journal.shared.entries.first?.text ?? "")

    let sys = LaunchItem(label: "com.fake.sistema", plist: URL(fileURLWithPath: "/Library/LaunchDaemons/com.fake.sistema.plist"), args: [], workdir: nil, logs: [], modified: nil, readable: true, system: true, mine: false, running: false, disabled: false)
    log.reset()
    Hooks.shell = { cmd in log.add(cmd); return (cmd.hasSuffix("version 2>/dev/null") ? "\(Root.version)\n" : "", 0) }
    model.status = ""
    model.remove(sys)
    _ = await waitFor { model.status.contains("eliminado") }
    check(log.all.contains { $0.contains("/usr/bin/sudo -n") && $0.contains("'launch' 'remove' 'com.fake.sistema'") }, "un arranque del sistema se elimina con el ayudante, sin pedir contraseña")
    _ = await waitFor { Journal.shared.entries.first?.text.contains("Sin respaldo") == true }
    check(Journal.shared.entries.first?.text.contains("Sin respaldo") == true, "y el registro dice «sin respaldo» porque no se pudo guardar uno", Journal.shared.entries.first?.text ?? "")
    Hooks.shell = { _ in ("", 1) }
    model.status = ""
    model.remove(alpha)
    _ = await waitFor { model.status.contains("No se pudo eliminar") }
    check(model.status.contains("No se pudo eliminar"), "si falla al eliminar, no dice que se eliminó", model.status)
    Hooks.shell = nil
}
