import Foundation

enum Root {
    nonisolated static let helper = "/Library/PrivilegedHelperTools/app.tpoptimizer.root"
    nonisolated static let sudoFile = "/etc/sudoers.d/tp-optimizer"
    nonisolated static let version = "17"
    nonisolated static let requirement = "=identifier \"app.tpoptimizer.root\" and certificate root = H\"SIGNING_HASH\""

    nonisolated static var installed: Bool { FileManager.default.fileExists(atPath: helper) && FileManager.default.fileExists(atPath: sudoFile) }

    nonisolated static func ready() -> Bool {
        shell("/usr/bin/sudo -n \(q(helper)) version 2>/dev/null").trimmingCharacters(in: .whitespacesAndNewlines) == version
    }

    nonisolated static func exec(_ args: [String]) -> Bool {
        shellStatus("/usr/bin/sudo -n \(q(helper)) \(args.map(q).joined(separator: " ")) >/dev/null 2>&1") == 0
    }

    nonisolated static func upgrade() -> Bool {
        guard installed, let source = Bundle.main.path(forResource: "tp-root", ofType: nil) else { return false }
        return exec(["update", source]) && ready()
    }

    nonisolated static func refresh(canPrompt: Bool) -> Bool { ready() || upgrade() || (canPrompt && install()) }

    nonisolated static func runQuiet(_ args: [String]) -> Bool { (ready() || upgrade()) && exec(args) }

    nonisolated static func read(_ args: [String], prompt: Bool = true) -> String? {
        guard ready() || upgrade() || (prompt && install()) else { return nil }
        return shell("/usr/bin/sudo -n \(q(helper)) \(args.map(q).joined(separator: " ")) 2>/dev/null")
    }

    nonisolated static func run(_ args: [String]) -> Bool { (ready() || upgrade() || install()) && exec(args) }

    nonisolated static func script(source: String, user: String) -> String {
        let rule = "\(user) ALL=(root) NOPASSWD: \(helper)"
        return "t=$(/usr/bin/mktemp) && f=$(/usr/bin/mktemp) && /bin/cp \(q(source)) \"$t\" && /usr/bin/codesign --verify --test-requirement=\(q(requirement)) \"$t\""
            + " && /bin/mkdir -p /Library/PrivilegedHelperTools && /usr/bin/install -m 755 -o root -g wheel \"$t\" \(helper)"
            + " && /usr/bin/printf '%s\\n' \(q(rule)) > \"$f\" && /usr/sbin/visudo -cf \"$f\" >/dev/null && /bin/mkdir -p /etc/sudoers.d"
            + " && /usr/bin/install -m 440 -o root -g wheel \"$f\" \(sudoFile); s=$?; /bin/rm -f \"$t\" \"$f\"; exit $s"
    }

    nonisolated static func install() -> Bool {
        let user = NSUserName()
        guard let source = Bundle.main.path(forResource: "tp-root", ofType: nil),
              user.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else { return false }
        return adminShell(script(source: source, user: user)) && ready()
    }

    nonisolated static func revoke() -> Bool {
        adminShell("/bin/rm -f \(sudoFile) \(helper)")
    }
}
