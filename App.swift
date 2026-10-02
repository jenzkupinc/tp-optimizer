import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/Library/Saved Application State/app.tpoptimizer.savedState")
    }
    func applicationDidFinishLaunching(_ notification: Notification) { Monitor.restorePersisted(); Monitor.wakePersisted() }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Hub.current?.game.suspendForQuit() }
        Monitor.restorePersisted()
        Monitor.wakePersisted()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct OptimizerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var hub = Hub()
    var body: some Scene {
        Window("TP Optimizer", id: "main") { RootView(hub: hub).frame(minWidth: 1240, minHeight: 640) }
            .windowToolbarStyle(.unified)
            .defaultSize(width: 1400, height: 840)
        MenuBarExtra { MenuBarContent(m: hub.monitor, watch: hub.watch, ssd: hub.ssd, night: hub.night, game: hub.game) } label: { MenuBarLabel(m: hub.monitor, watch: hub.watch, game: hub.game) }
            .menuBarExtraStyle(.window)
    }
}

