// Tend: a menu bar app for the `tend` CLI. It lists tracked tmux sessions,
// shows which app runs in each one (Claude, or any app you add) and its
// status, and starts, stops, restarts, and opens them. All the work happens in `tend`; this app only
// calls it.
//
// Source: https://github.com/schaffernation/tend
// Build and install with app/build.sh. The build copies bin/tend into the
// app's Resources folder, and the app runs that copy.

import Combine
import ServiceManagement
import SwiftUI
import UserNotifications

/// The app tend recognized in a session.
struct AppInfo: Decodable, Hashable {
    /// A prompt the app stopped on, like Claude asking to trust a folder.
    struct Question: Decodable, Hashable {
        struct Answer: Decodable, Hashable {
            let id: String
            let label: String
        }
        let id: String
        let text: String
        let answers: [Answer]
        /// Lines the app printed above a prompt tend doesn't know.
        let context: [String]?
        /// Whether you can type a reply instead of choosing an answer.
        let free_text: Bool?
    }
    let id: String
    let name: String
    let icon: String?
    let status: String?
    let question: Question?
}

/// A saved setup that `tend new --recipe` runs in a new session's folder.
struct Recipe: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let setup: String
    let input: String?
    var title: String { name ?? id }
    var needsInput: Bool { setup.contains("{input}") }
}

/// Pictures for apps, from a profile's `icon`: a bundle ID, or the path to a
/// .app or an image file. An icon that's found is kept; one that isn't is
/// looked up again a minute later, in case you install the app meanwhile.
@MainActor
enum AppIcons {
    private static var found: [String: NSImage] = [:]
    private static var missing: [String: Date] = [:]
    private static let retryAfter: TimeInterval = 60

    static func image(_ spec: String?, size: CGFloat = 16) -> NSImage? {
        guard let spec, !spec.isEmpty else { return nil }
        let key = "\(spec)@\(size)"
        if let hit = found[key] { return hit }
        if let since = missing[key], Date().timeIntervalSince(since) < retryAfter { return nil }
        guard let image = load(spec)?.copy() as? NSImage else {
            missing[key] = Date()
            return nil
        }
        image.size = NSSize(width: size, height: size)
        found[key] = image
        missing[key] = nil
        return image
    }

    private static func load(_ spec: String) -> NSImage? {
        let path = (spec as NSString).expandingTildeInPath
        if path.hasPrefix("/") {
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            if path.hasSuffix(".app") { return NSWorkspace.shared.icon(forFile: path) }
            return NSImage(contentsOfFile: path)
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: spec) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// An app's icon, or nothing if it has none or it can't be found.
struct AppIconView: View {
    let spec: String?
    var size: CGFloat = 16

    var body: some View {
        if let image = AppIcons.image(spec, size: size) {
            Image(nsImage: image).resizable().frame(width: size, height: size)
        }
    }
}

/// An app tend knows how to recognize.
struct AppProfile: Decodable, Identifiable, Hashable {
    struct Match: Decodable, Hashable {
        let names: [String]?
        let paths: [String]?
    }
    let id: String
    let name: String?
    let enabled: Bool
    let builtin: Bool
    let match: Match?
    let launch: String?
    let icon: String?
    var title: String { name ?? id }
    var rules: String { ((match?.names ?? []) + (match?.paths ?? [])).joined(separator: ", ") }
}

/// How `tend open` opens a session: the terminal app and the attach command.
struct TerminalSettings: Decodable, Hashable {
    let app: String
    let attach: String
    let mode: String
    let apps: [String]
    let presets: [String: String]
}

/// Another account on this Mac that should run its own Tend. Decoded from
/// `tend accounts --json` with snake-case keys converted.
struct AccountStatus: Decodable, Identifiable, Hashable {
    let user: String
    let name: String
    let loggedIn: Bool
    let tendRunning: Bool
    let ok: Bool
    let problem: String?
    var id: String { user }
}

struct Accounts: Decodable {
    struct Available: Decodable, Hashable {
        let user: String
        let name: String
    }
    let watched: [AccountStatus]
    let available: [Available]
}

/// A conversation that was dropped when its session restarted, from
/// `tend dropped --json` with snake-case keys converted.
struct DroppedChat: Decodable, Identifiable, Hashable {
    let session: String
    let id: String
    let label: String?
    let droppedAt: Int
}

/// Folders to suggest for a new session, from `tend folders --json`.
struct Folders: Decodable {
    let recent: [String]
    let nearby: [String]
    let parents: [String]
}

/// Where tend keeps its files, from `tend config --json`.
struct ConfigPaths: Decodable {
    let config: String
    let state: String
}

/// A session's state: running, its command exited (the tmux session is
/// still open at a shell prompt), or stopped (no tmux session).
enum SessionState: String, Decodable {
    case running, exited, stopped
}

/// A tracked session, or a tmux session tend doesn't track, from
/// `tend ls --json`.
struct Session: Decodable, Identifiable, Hashable {
    let name: String
    let dir: String
    /// Whether the session is named after its folder.
    let namedAfterDir: Bool
    let command: String?
    let resume: String?
    let autostart: Bool
    /// Whether Tend brings back the session's conversation when it restarts.
    /// When it doesn't, the session starts its plain command every time.
    let restoreConversation: Bool
    let managed: Bool
    let state: SessionState
    let attached: Bool
    let app: AppInfo?
    /// The command that attaches a terminal to the session, or nil if tmux
    /// isn't installed.
    let attach: String?
    var id: String { name }
}

/// The last lines a session's pane shows, from `tend peek --json`.
struct PeekOutput: Decodable, Hashable {
    let name: String
    let lines: [String]
}

/// What a run of `tend` printed, and whether it worked.
struct TendResult {
    /// Standard output, if tend exited with status 0.
    let output: Data?
    /// Standard error, if tend failed.
    let error: String?
}

/// Decode tend's JSON, which uses snake_case keys.
func decodeTend<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(type, from: data)
}

@MainActor
final class Model: ObservableObject {
    @Published var sessions: [Session] = []
    /// Why the last action failed, like a start or a new session. It stays
    /// until you close it or take another action.
    @Published var error: String?
    /// Why Tend can't read its sessions. It clears once a refresh works.
    @Published var refreshError: String?
    @Published var apps: [AppProfile] = []
    @Published var recipes: [Recipe] = []
    @Published var terminal: TerminalSettings?
    @Published var accounts: Accounts?
    @Published var dropped: [DroppedChat] = []
    /// Suggestions for the new-session form, loaded when the form opens.
    @Published var folders: Folders?
    @Published var configPaths: ConfigPaths?

    /// When each watched account's problem started, and which problems Tend
    /// has already posted a notification for.
    private var problemSince: [String: Date] = [:]
    private var notified: Set<String> = []
    /// How long a problem lasts before Tend posts a notification. It gives
    /// someone time to log in after a restart before Tend nags.
    static let notifyAfter: TimeInterval = 60
    @Published var busy = false
    /// The new-session form. Kept here, not in the view, so it survives the
    /// panel closing while a folder picker is open.
    @Published var draft: Draft?

    /// The selected session's name. The arrow keys move it, and Return,
    /// Space, Delete, and Command-C act on it.
    @Published var selection: String?
    /// The session whose row asks you to confirm an action.
    @Published var confirming: Confirming?
    /// The session whose name the row is editing.
    @Published var renaming: String?
    /// The session whose recent output shows under its row, and that output
    /// once it's loaded.
    @Published var peek: Peek?
    /// Goes up each time the panel opens, so the panel can focus its list.
    @Published var panelOpens = 0
    /// Goes up each time something asks for the new-session form, so the
    /// panel can scroll it into view.
    @Published var formShown = 0
    /// The tallest the panel can be, so it stops above the bottom of the
    /// screen. Set by the status item's controller.
    @Published var panelMaxHeight: CGFloat = .infinity
    /// Closes the menu bar panel. Set by the status item's controller.
    var closePanel: (() -> Void)?

    struct Confirming: Equatable {
        enum Kind { case restart, fresh, untrack }
        let name: String
        let kind: Kind
    }

    struct Peek: Equatable {
        let name: String
        var lines: [String]?
    }

    struct Draft {
        var appID: String?  // nil means a custom command
        var dir = ""
        var name = ""
        var command = ""
        var autostart = true
        var restoreConversation = true
        /// "" for no setup, "custom" for setupText as a command, or a recipe ID.
        var setupID = ""
        /// The custom setup command, or the recipe's input, like a URL.
        var setupText = ""
        /// Whether the form shows Name, Command, Setup, and the restore toggles.
        var showOptions = false
    }

    /// The "Restore sessions after the Mac starts" setting. GeneralPane
    /// changes it with @AppStorage, which only updates views, so the model
    /// reads it from UserDefaults when it needs it.
    static let restoreOnLaunchKey = "restoreOnLaunch"
    var restoreOnLaunch: Bool {
        UserDefaults.standard.object(forKey: Model.restoreOnLaunchKey) as? Bool ?? true
    }

    nonisolated static let tend = Bundle.main.url(forResource: "tend", withExtension: nil)?.path
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/tend").path

    /// Where "Install command-line tool" links `tend`.
    nonisolated static let cliLink = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin/tend")

    /// The PATH tend runs with: Homebrew's folders, so `/usr/bin/env python3`
    /// finds Homebrew's Python first, then the app's own PATH. tend adds
    /// the other folders it needs itself.
    nonisolated static let path = (["/opt/homebrew/bin", "/usr/local/bin"]
        + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init))
        .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        .joined(separator: ":")

    /// Why tend can't run on this Mac, or nil if it can. tend is a Python
    /// script, and macOS only ships Python with the developer tools.
    static let setupProblem: String? = {
        let fm = FileManager.default
        if ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"].contains(where: fm.isExecutableFile) {
            return nil
        }
        // /usr/bin/python3 is a stub until the developer tools are installed.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            p.waitUntilExit()
            if p.terminationStatus == 0 { return nil }
        }
        return "Tend needs Python 3. Install the Command Line Tools with xcode-select --install, or install Python with Homebrew: brew install python"
    }()

    init() {
        if let problem = Model.setupProblem {
            refreshError = problem
            return
        }
        Task {
            // Restore only on the first launch since the Mac started. A
            // relaunch, like after a crash, checks in and changes nothing.
            if restoreOnLaunch { await run(["restore", "--once"]) }
            await loadSettings()
            while true {
                await refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    var tracked: [Session] { sessions.filter(\.managed) }
    var untracked: [Session] { sessions.filter { !$0.managed } }
    var runningCount: Int { sessions.filter { $0.state == .running }.count }
    /// Tracked sessions that `tend restore` would start.
    var restorable: [Session] { tracked.filter { $0.autostart && $0.state == .stopped } }
    var waitingCount: Int { sessions.filter { $0.app?.question != nil }.count }
    var anyBusy: Bool { sessions.contains { $0.app?.status == "busy" } }
    var anyQuestion: Bool { waitingCount > 0 }
    var accountProblems: [AccountStatus] { accounts?.watched.filter { !$0.ok } ?? [] }

    /// Where `tend` is on your PATH, or nil if it isn't installed: the link
    /// the Install button makes in ~/.local/bin, or the one a Homebrew cask
    /// makes, when it points at this app's copy.
    var cliPath: String? {
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: Model.cliLink.path)) != nil
            || fm.fileExists(atPath: Model.cliLink.path) {
            return Model.cliLink.path
        }
        let bundled = URL(fileURLWithPath: Model.tend).resolvingSymlinksInPath().path
        return ["/opt/homebrew/bin/tend", "/usr/local/bin/tend"].first {
            fm.fileExists(atPath: $0) && URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == bundled
        }
    }

    /// Run tend. Returns its output, or the error it printed.
    func call(_ args: [String]) async -> TendResult {
        await Task.detached { () -> TendResult in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: Model.tend)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = Model.path
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            // Wait for the exit with terminationHandler, not waitUntilExit:
            // on macOS 27, waitUntilExit sometimes never returns after tend
            // exits, and then the panel stops refreshing. The stream keeps
            // the status if tend exits before anything waits for it.
            let (exits, exited) = AsyncStream.makeStream(of: Int32.self)
            p.terminationHandler = { process in
                exited.yield(process.terminationStatus)
                exited.finish()
            }
            do { try p.run() } catch {
                return TendResult(output: nil, error: "Couldn't run \(Model.tend): \(error.localizedDescription)")
            }
            // Read standard error on another thread, so a full stderr pipe
            // can't block tend while this thread waits for stdout to end.
            let errReader = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = await errReader.value
            var status: Int32 = -1
            for await s in exits { status = s }
            guard status == 0 else {
                let message = String(decoding: errData, as: UTF8.self)
                return TendResult(output: nil, error: message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return TendResult(output: data, error: nil)
        }.value
    }

    /// Run tend for an action. If it fails, show its error until you close
    /// it or take another action.
    @discardableResult
    func run(_ args: [String]) async -> Data? {
        let result = await call(args)
        if let message = result.error { error = message }
        return result.output
    }

    /// Read what changes on its own: the sessions, other accounts, and
    /// dropped conversations. Tend runs this every 5 seconds.
    func refresh() async {
        var outputs: [Data] = []
        for args in [["ls", "--json"], ["accounts", "--json"], ["dropped", "--json"]] {
            let result = await call(args)
            guard let data = result.output else {
                refreshError = result.error
                return
            }
            outputs.append(data)
        }
        do {
            sessions = try decodeTend([Session].self, from: outputs[0])
            accounts = try decodeTend(Accounts.self, from: outputs[1])
            dropped = try decodeTend([DroppedChat].self, from: outputs[2])
            checkAccounts()
            refreshError = nil
        } catch {
            refreshError = "Couldn't read tend's output: \(error.localizedDescription)"
        }
        // Forget what refers to sessions that are gone.
        let names = Set(sessions.map(\.name))
        if let s = selection, !names.contains(s) { selection = nil }
        if let r = renaming, !names.contains(r) { renaming = nil }
        if let c = confirming, !names.contains(c.name) { confirming = nil }
        if let p = peek {
            if names.contains(p.name) { await loadPeek() } else { peek = nil }
        }
    }

    /// Sessions in the order the panel lists them: tracked, then untracked.
    var listed: [Session] { tracked + untracked }
    var selected: Session? { sessions.first { $0.name == selection } }

    /// Move the selection up or down the list. With nothing selected, Down
    /// selects the first row and Up the last, as in a menu.
    func moveSelection(by delta: Int) {
        let names = listed.map(\.name)
        guard !names.isEmpty else { return }
        if let s = selection, let i = names.firstIndex(of: s) {
            selection = names[max(0, min(names.count - 1, i + delta))]
        } else {
            selection = delta > 0 ? names.first : names.last
        }
    }

    /// Delete and Command-Delete: ask, in the row, to stop tracking the
    /// selected session, the way Restart asks.
    func confirmUntrack() {
        guard let s = selected else { return }
        if s.managed {
            confirming = .init(name: s.name, kind: .untrack)
        } else {
            NSSound.beep()
        }
    }

    /// A row's main action: start a stopped session, or open a running one.
    func primaryAction(_ session: Session) {
        act(session.state == .stopped ? ["start", session.name] : ["open", session.name])
    }

    /// Show or hide a session's recent output under its row.
    func togglePeek(_ name: String) {
        if peek?.name == name {
            peek = nil
            return
        }
        peek = Peek(name: name, lines: nil)
        Task { await loadPeek() }
    }

    func loadPeek() async {
        guard let name = peek?.name else { return }
        let result = await call(["peek", name, "--lines", "20", "--json"])
        guard peek?.name == name else { return }
        if let data = result.output, let out = try? decodeTend(PeekOutput.self, from: data) {
            peek?.lines = out.lines
        } else {
            peek?.lines = [result.error ?? "Couldn't read \(name)'s output."]
        }
    }

    /// Rename a session with `tend rename`, and keep it selected.
    func rename(_ old: String, to new: String) {
        renaming = nil
        let new = new.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != old else { return }
        Task {
            busy = true
            error = nil
            if await run(["rename", old, new]) != nil, selection == old {
                // tend replaces . and : the way tmux needs.
                selection = new.replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: ":", with: "-")
            }
            await refresh()
            busy = false
        }
    }

    /// Put text on the clipboard.
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// What dragging a row out provides: the folder as a file, for Finder or
    /// a terminal's Dock icon, and the attach command as text, for a
    /// terminal window or a note.
    static func dragItem(for session: Session) -> NSItemProvider {
        let provider = NSItemProvider(object: URL(fileURLWithPath: session.dir) as NSURL)
        if let attach = session.attach { provider.registerObject(attach as NSString, visibility: .all) }
        provider.suggestedName = session.name
        return provider
    }

    /// The folders among dropped file URLs. Packages, like apps, don't count.
    static func folders(in urls: [URL]) -> [URL] {
        urls.filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return url.isFileURL && values?.isDirectory == true && values?.isPackage != true
        }
    }

    /// Start a new session in a folder dropped on the menu bar icon or the
    /// panel: open the form, or point an open form at the folder.
    @discardableResult
    func newSession(in urls: [URL]) -> Bool {
        guard let folder = Model.folders(in: urls).first else { return false }
        if draft == nil { newDraft() }
        draft?.dir = folder.path
        formShown += 1
        return true
    }

    /// Handle Esc: back out of the innermost thing in progress. Returns
    /// false when there's nothing left, and the panel should close.
    func escape() -> Bool {
        if renaming != nil { renaming = nil; return true }
        if confirming != nil { confirming = nil; return true }
        if peek != nil { peek = nil; return true }
        if draft != nil { draft = nil; return true }
        if selection != nil { selection = nil; return true }
        return false
    }

    /// Choose a folder for the new session with the standard open panel.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for the new session"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: draft?.dir ?? NSHomeDirectory())
        let response = StatusPanelController.runModal { panel.runModal() }
        if response == .OK, let url = panel.url { draft?.dir = url.path }
    }

    /// Read what changes only when you change it: the apps, recipes,
    /// terminal settings, and where the config is. Tend runs this when it
    /// opens and after each action.
    func loadSettings() async {
        if let data = await run(["apps", "--json"]) { apps = (try? decodeTend([AppProfile].self, from: data)) ?? apps }
        if let data = await run(["recipes", "--json"]) { recipes = (try? decodeTend([Recipe].self, from: data)) ?? recipes }
        if let data = await run(["config", "--json"]) { configPaths = try? decodeTend(ConfigPaths.self, from: data) }
        await loadTerminal()
    }

    /// Load the new-session form's folder suggestions.
    func loadFolders() async {
        guard let data = await run(["folders", "--json"]) else { return }
        folders = try? decodeTend(Folders.self, from: data)
    }

    /// Post one notification for each account problem that lasts longer
    /// than `notifyAfter`. Once the account is fine again, a new problem
    /// notifies again.
    func checkAccounts() {
        let now = Date()
        for account in accounts?.watched ?? [] {
            guard !account.ok, let problem = account.problem else {
                problemSince[account.user] = nil
                notified.remove(account.user)
                continue
            }
            let since = problemSince[account.user] ?? now
            problemSince[account.user] = since
            if now.timeIntervalSince(since) >= Model.notifyAfter && !notified.contains(account.user) {
                notified.insert(account.user)
                Model.notify(id: "account-\(account.user)", title: "Log in \(account.name)", body: problem
                    + " To log in, choose their account from the user menu in the menu bar or Control Center.")
            }
        }
    }

    static func notify(id: String, title: String, body: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    func watchAccount(_ user: String, _ on: Bool) {
        act(["accounts", on ? "add" : "rm", user])
    }

    func loadTerminal() async {
        guard let data = await run(["terminal", "--json"]) else { return }
        terminal = try? decodeTend(TerminalSettings.self, from: data)
    }

    /// Change the terminal app or the attach command (a preset name or a command).
    func setTerminal(app: String? = nil, attach: String? = nil) {
        var args = ["terminal"]
        if let app { args += ["--app", app] }
        if let attach { args += ["--attach", attach] }
        Task {
            busy = true
            error = nil
            await run(args)
            await loadTerminal()
            busy = false
        }
    }

    /// Link `tend` into ~/.local/bin, so you can run it in a terminal.
    func installCLI() {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: Model.cliLink.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: Model.cliLink.path, withDestinationPath: Model.tend)
            error = nil
        } catch {
            self.error = "Couldn't link \(Model.cliLink.path): \(error.localizedDescription)"
        }
    }

    /// Start a new session from the draft. Closes the form if it worked.
    func create() {
        guard let d = draft else { return }
        var args = ["new"]
        if let id = d.appID { args.append(id) }
        args += ["--dir", d.dir]
        if !d.name.trimmingCharacters(in: .whitespaces).isEmpty { args += ["--name", d.name] }
        if !d.autostart { args.append("--no-autostart") }
        if d.appID != nil && !d.restoreConversation { args.append("--no-restore-conversation") }
        let launch = apps.first { $0.id == d.appID }?.launch
        if d.command != launch { args += ["--command", d.command] }
        let text = d.setupText.trimmingCharacters(in: .whitespaces)
        switch d.setupID {
        case "": break
        case "custom": if !text.isEmpty { args += ["--setup", text] }
        default:
            args += ["--recipe", d.setupID]
            if !text.isEmpty { args += ["--input", text] }
        }
        Task {
            busy = true
            error = nil
            if await run(args) != nil {
                draft = nil
                UserDefaults.standard.set(d.dir, forKey: "lastDir")
                UserDefaults.standard.set(d.appID ?? "", forKey: "lastApp")
            }
            await refresh()
            busy = false
        }
    }

    func act(_ args: [String]) {
        Task {
            busy = true
            error = nil
            await run(args)
            await refresh()
            // Actions on apps and recipes change the settings.
            if ["apps", "recipes"].contains(args.first) { await loadSettings() }
            busy = false
        }
    }

    /// Start the new-session form with the app and folder you used last.
    func newDraft() {
        let defaults = UserDefaults.standard
        let launchable = apps.filter { $0.enabled && $0.launch != nil }
        let lastApp = defaults.string(forKey: "lastApp")
        let app = launchable.first { $0.id == lastApp } ?? (lastApp == "" ? nil : launchable.first)
        draft = Draft(
            appID: app?.id,
            dir: defaults.string(forKey: "lastDir")
                ?? FileManager.default.homeDirectoryForCurrentUser.path,
            command: app?.launch ?? "",
            showOptions: app == nil)
        formShown += 1
        Task { await loadFolders() }
    }
}

/// A path with the home folder shown as ~.
func shortPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == home { return "~" }
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

@main
struct TendApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let updates = Updates.shared  // Starts Sparkle at launch. See Updates.swift.

    var body: some Scene {
        // The menu bar item and its panel are AppKit (see StatusPanelController).
        // SwiftUI still builds the main menu, with its standard Edit menu, so
        // Cut, Copy, Paste, Select All, and Undo work in every text field.
        Settings {
            SettingsView().environmentObject(delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    private var statusPanel: StatusPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // For testing, without changing the Mac's appearance:
        // open -n Tend.app --args -TendAppearance Dark (or Light)
        if let name = UserDefaults.standard.string(forKey: "TendAppearance") {
            NSApp.appearance = NSAppearance(named: name == "Dark" ? .darkAqua : .aqua)
        }
        statusPanel = StatusPanelController(model: model)
        // For testing, on a Mac whose full menu bar hides the item:
        // open -n Tend.app --args -TendShowPanelAtLaunch YES
        if UserDefaults.standard.bool(forKey: "TendShowPanelAtLaunch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.statusPanel?.show() }
        }
    }
}

// MARK: - Menu bar item

/// The menu bar item and the panel it opens. `MenuBarExtra` can't take
/// drops on its icon, highlight it while the panel is open, or keep the panel
/// open while a folder picker runs, so this small controller does it with
/// `NSStatusItem` and an `NSPanel`. The panel's contents are SwiftUI.
@MainActor
final class StatusPanelController: NSObject, NSWindowDelegate, NSDraggingDestination {
    private static weak var current: StatusPanelController?

    private let model: Model
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: TendPanel
    private var monitors: [Any] = []
    private var observers: [AnyCancellable] = []
    /// While a modal window, like the folder picker, is open, the panel stays.
    private var modalDepth = 0
    private let host: NSHostingController<AnyView>
    private var sizeObservation: NSKeyValueObservation?

    init(model: Model) {
        self.model = model
        panel = TendPanel()
        host = NSHostingController(rootView: AnyView(ContentView().environmentObject(model)))
        super.init()
        StatusPanelController.current = self

        host.sizingOptions = .preferredContentSize
        panel.setContent(host.view)
        // Grow and shrink with the content, keeping the top under the menu bar.
        sizeObservation = host.observe(\.preferredContentSize) { [weak self] _, _ in
            DispatchQueue.main.async { self?.fitToContent() }
        }
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.escape() }
        panel.onCommandDelete = { [weak model] in model?.confirmUntrack() }
        model.closePanel = { [weak self] in self?.close() }

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel("Tend")
            // The button's own window takes drags for it: AppKit hands a drag
            // over a window to its delegate when no view under it takes it.
            if let window = button.window, window.delegate == nil {
                window.registerForDraggedTypes([.fileURL])
                window.delegate = self
            }
        }
        updateButton()
        // Redraw the icon after each change, once the change has happened.
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
            .store(in: &observers)
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in self?.close() }
            .store(in: &observers)
        // A display added, removed, or rearranged, or the Dock moved, changes
        // how tall the panel can be.
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.fitToContent() }
            .store(in: &observers)
    }

    // The icon: a terminal, filled while an app is busy, with a badge for a
    // question and one for an account problem, then the running count.
    private func updateButton() {
        guard let button = statusItem.button else { return }
        var symbols = [model.anyBusy ? "terminal.fill" : "terminal"]
        if model.anyQuestion { symbols.append("questionmark.bubble") }
        if !model.accountProblems.isEmpty { symbols.append("person.crop.circle.badge.exclamationmark") }
        let key = symbols.joined(separator: " ")
        if button.identifier?.rawValue != key {
            button.image = StatusPanelController.icon(symbols)
            button.identifier = NSUserInterfaceItemIdentifier(key)
        }
        let count = model.runningCount
        let title = count > 0 ? "\(count)" : ""
        if button.title != title { button.title = title }
        var parts = ["\(count) running"]
        if model.waitingCount > 0 { parts.append("\(model.waitingCount) waiting for you") }
        if !model.accountProblems.isEmpty { parts.append("an account needs attention") }
        button.setAccessibilityValue(parts.joined(separator: ", "))
    }

    /// SF Symbols side by side, as one template image, so the menu bar tints
    /// it for light, dark, and the highlighted state.
    static func icon(_ names: [String]) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        let images = names.compactMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        }
        let spacing: CGFloat = 3
        let width = images.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max(0, images.count - 1))
        let height = images.map(\.size.height).max() ?? 16
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for i in images {
                i.draw(in: NSRect(x: x, y: (height - i.size.height) / 2, width: i.size.width, height: i.size.height))
                x += i.size.width + spacing
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: Showing and closing

    @objc private func togglePanel(_ sender: Any?) {
        panel.isVisible ? close() : show()
    }

    func show() {
        guard !panel.isVisible else { return }
        fitToContent()
        panel.makeKeyAndOrderFront(nil)
        model.panelOpens += 1
        // The button unhighlights itself when the click ends, so highlight
        // it after that.
        DispatchQueue.main.async { [weak self] in
            guard let self, panel.isVisible else { return }
            statusItem.button?.highlight(true)
        }
        // A click in another app closes the panel. Clicks in this app's
        // other windows, like Settings, take the key window, which closes it too.
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.closeUnlessModal() }
        }) {
            monitors.append(m)
        }
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        model.renaming = nil
        model.confirming = nil
        // A selection belongs to one visit to the panel, as in a menu.
        model.selection = nil
    }

    private func closeUnlessModal() {
        guard modalDepth == 0, NSApp.modalWindow == nil, panel.attachedSheet == nil else { return }
        close()
    }

    private func escape() {
        if !model.escape() { close() }
    }

    /// Size the panel to its content, and hang it under the menu bar item.
    /// It stops 8 points above the bottom of the screen's visible frame, as
    /// a menu does, and tells the content how tall it can be, so the middle
    /// scrolls instead.
    private func fitToContent() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let size = host.preferredContentSize
        var item = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let hidden = buttonWindow.frame.height == 0 || item.maxY <= 0
        // A hidden item has no screen of its own: use the one with the menu bar.
        let screen = hidden ? NSScreen.screens.first : buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        if hidden {
            // The menu bar hides the item, as when it's full: open at the
            // right end of the menu bar, where menu bar items are.
            item = NSRect(x: visible.maxX - size.width, y: visible.maxY, width: 0, height: 0)
        }
        let top = item.minY - 4
        let maxHeight = max(100, top - visible.minY - 8)
        if abs(model.panelMaxHeight - maxHeight) > 0.5 { model.panelMaxHeight = maxHeight }
        guard size.width > 0, size.height > 0 else { return }
        var x = item.minX
        x = min(x, visible.maxX - size.width - 6)
        x = max(x, visible.minX + 6)
        let height = min(size.height, maxHeight)
        panel.setFrame(NSRect(x: x, y: top - height, width: size.width, height: height), display: true)
    }

    /// Run a modal window, like the folder picker, over the panel. The panel
    /// stays open, below it, and takes the keyboard back afterward.
    static func runModal<T>(_ body: () -> T) -> T {
        guard let c = current, c.panel.isVisible else {
            NSApp.activate(ignoringOtherApps: true)
            return body()
        }
        c.modalDepth += 1
        let level = c.panel.level
        c.panel.level = .normal
        NSApp.activate(ignoringOtherApps: true)
        defer {
            c.modalDepth -= 1
            c.panel.level = level
            c.panel.makeKeyAndOrderFront(nil)
        }
        return body()
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else { return }
        // Wait a moment: a modal window that's about to open, or a sheet,
        // takes the key window first.
        DispatchQueue.main.async { [weak self] in
            guard let self, !panel.isKeyWindow else { return }
            closeUnlessModal()
        }
    }

    // MARK: Drops on the menu bar icon

    private func folders(in info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return Model.folders(in: urls)
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !folders(in: sender).isEmpty else { return [] }
        statusItem.button?.highlight(true)
        return .generic
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        folders(in: sender).isEmpty ? [] : .generic
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        statusItem.button?.highlight(panel.isVisible)
    }

    func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !folders(in: sender).isEmpty
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard model.newSession(in: folders(in: sender)) else { return false }
        show()
        statusItem.button?.highlight(true)
        return true
    }
}

/// The menu bar panel's window: borderless, with a rounded background
/// (`PanelBackground`: glass, or the menu material), above other windows and
/// full-screen apps, and on every Space. It takes the keyboard without making Tend the active app, the way
/// a menu does, so the app you were in keeps its menu bar.
final class TendPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onCommandDelete: (() -> Void)?
    private let background = PanelBackground.make()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = PanelBackground.windowShadow
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        contentView = background
        setAccessibilityLabel("Tend")
    }

    func setContent(_ view: NSView) {
        PanelBackground.setContent(view, in: background)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc, when no view inside uses it.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// The panel takes the keyboard without making Tend the active app, and
    /// then the main menu may not see key equivalents like Command-C. Pass
    /// them to it after the panel's own views have had their turn.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        // Command-Delete stops tracking the selected session, unless you're
        // typing, where it deletes to the start of the line.
        if event.keyCode == 51, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           !(firstResponder is NSText), let onCommandDelete {
            onCommandDelete()
            return true
        }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }
}

// MARK: - Panel

/// The menu bar panel: messages, the new-session form, and the sessions.
/// Settings live in their own window.
struct ContentView: View {
    @EnvironmentObject var model: Model
    @Environment(\.openSettings) private var openSettings
    @State private var spins = 0.0
    /// Whether the session list has the keyboard. The selection is drawn in
    /// the accent color while it does, and in gray while it doesn't, like a
    /// source list.
    @FocusState private var listFocused: Bool
    /// Whether a folder is being dragged over the panel.
    @State private var dropTargeted = false

    /// The Restore button's tooltip, which names the sessions it starts.
    var restoreHelp: String {
        let names = model.restorable.map(\.name).joined(separator: ", ")
        let which = model.restorable.count == 1
            ? "the tracked session that's set to restore and isn't running"
            : "the \(model.restorable.count) tracked sessions that are set to restore and aren't running"
        return "Start \(which): \(names). Sessions that can resume, like Claude, reattach to their last conversation."
    }

    /// What the panel scrolls to, by `ScrollViewReader`.
    enum ScrollTarget: Hashable {
        case top, form
        case row(String)
    }

    var body: some View {
        ScrollViewReader { proxy in
            // The header and footer stay put; the middle scrolls when the
            // panel would run off the screen (see PanelLayout).
            PanelLayout(maxHeight: model.panelMaxHeight) {
                header
            } content: {
                middle
            } footer: {
                VStack(alignment: .leading, spacing: Design.sectionSpacing) {
                    Divider()
                    footer
                }
            }
            // Keep the selected row in view as the arrow keys move it.
            .onChange(of: model.selection) { _, name in
                if let name { proxy.scrollTo(ScrollTarget.row(name)) }
            }
            // Show a row's recent output when it opens, and again once it loads.
            .onChange(of: model.peek.map { "\($0.name) \($0.lines != nil)" }) { _, _ in
                if let name = model.peek?.name { proxy.scrollTo(ScrollTarget.row(name)) }
            }
            // Command-N, the + button, or a folder dropped on the icon.
            .onChange(of: model.formShown) { _, _ in
                // Wait for the form to be laid out.
                DispatchQueue.main.async { proxy.scrollTo(ScrollTarget.form, anchor: .top) }
            }
            // Each visit to the panel starts at the top, as a menu does.
            .onChange(of: model.panelOpens) { _, _ in proxy.scrollTo(ScrollTarget.top, anchor: .top) }
        }
        .frame(width: 400)
        .panelShape()
        .dropHighlight(dropTargeted)
        // Drop a folder anywhere on the panel to start a session there.
        .dropDestination(for: URL.self) { urls, _ in
            model.newSession(in: urls)
        } isTargeted: { dropTargeted = $0 }
        .onExitCommand { if !model.escape() { model.closePanel?() } }
        .onChange(of: model.panelOpens) { _, _ in listFocused = true }
        // After a rename, the list takes the keyboard back.
        .onChange(of: model.renaming) { _, name in if name == nil { listFocused = true } }
        .onAppear { listFocused = true }
    }

    /// Everything between the header and the footer: messages, the
    /// new-session form, the sessions, and other accounts.
    var middle: some View {
        VStack(alignment: .leading, spacing: Design.sectionSpacing) {
            messages

            if model.draft != nil { NewSessionForm().id(ScrollTarget.form) }

            if model.sessions.isEmpty && model.draft == nil && model.refreshError == nil {
                emptyState
            }

            if !model.sessions.isEmpty { sessionList }

            if let watched = model.accounts?.watched, !watched.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    SectionHeader("Other accounts") { EmptyView() }
                    ForEach(watched) { AccountRow(account: $0) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(ScrollTarget.top)
    }

    /// The tracked sessions, then the tmux sessions tend doesn't track. One
    /// focusable list: the arrow keys move the selection, and the keys below
    /// act on the selected session.
    var sessionList: some View {
        VStack(alignment: .leading, spacing: Design.sectionSpacing) {
            if !model.tracked.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    SectionHeader("Sessions") {
                        if !model.restorable.isEmpty {
                            Button("Restore \(model.restorable.count)") { model.act(["restore"]) }
                                .help(restoreHelp)
                        }
                    }
                    ForEach(model.tracked) { row($0) }
                }
            }
            if !model.untracked.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    SectionHeader("Not tracked") {
                        Button("Track all") { model.act(["snapshot"]) }
                            .help("Add every untracked tmux session to the list, so Tend restores it.")
                    }
                    ForEach(model.untracked) { row($0) }
                }
            }
        }
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down, action: handleKey)
        .onDeleteCommand(perform: confirmUntrack)
        // Command-C copies the selected session's attach command, ready to
        // paste in a terminal. Copy Path is in the row's context menu.
        .onCopyCommand {
            guard let attach = model.selected?.attach else { return [] }
            return [NSItemProvider(object: attach as NSString)]
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sessions")
    }

    func row(_ session: Session) -> some View {
        SessionRow(session: session, listFocused: listFocused) {
            model.selection = session.name
            listFocused = true
        }
        .id(ScrollTarget.row(session.name))
    }

    /// The session list's keys. Rename, the reply field, and the form's
    /// fields have the keyboard while you type in them, so these don't
    /// interfere.
    func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // Keys typed in a text field inside the list, like the rename field,
        // reach this handler too. Leave them to the field.
        if model.renaming != nil || NSApp.keyWindow?.firstResponder is NSText { return .ignored }
        let selected = model.selected
        let command = press.modifiers.contains(.command)
        switch press.key {
        case .upArrow: model.moveSelection(by: -1)
        case .downArrow: model.moveSelection(by: 1)
        case .return:
            guard let s = selected else { return .ignored }
            model.primaryAction(s)
        case .space:
            guard let s = selected, s.state != .stopped else { return .ignored }
            model.togglePeek(s.name)
        case .delete, .deleteForward:
            guard selected != nil else { return .ignored }
            confirmUntrack()
        case .escape:
            if !model.escape() { model.closePanel?() }
        default:
            // Option-Command-C copies the folder's path, as in Finder.
            if press.characters.lowercased() == "c", command, press.modifiers.contains(.option),
               let s = selected {
                Model.copy(s.dir)
                return .handled
            }
            return .ignored
        }
        return .handled
    }

    func confirmUntrack() { model.confirmUntrack() }

    var header: some View {
        HStack(spacing: 8) {
            Text("Tend").font(.headline)
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            HeaderButtons {
                Button {
                    withAnimation(.easeInOut(duration: 0.6)) { spins += 1 }
                    model.act(["ls"])
                } label: {
                    Image(systemName: "arrow.clockwise").rotationEffect(.degrees(spins * 360))
                }
                .accessibilityLabel("Refresh")
                .keyboardShortcut("r")
                .help("Check every session now, and save the latest session ID of apps that can resume, like Claude. Tend also does this every 5 seconds.")
                Button { model.draft == nil ? model.newDraft() : (model.draft = nil) } label: {
                    Image(systemName: model.draft == nil ? "plus" : "xmark")
                }
                .accessibilityLabel(model.draft == nil ? "New Session" : "Cancel New Session")
                .keyboardShortcut("n")
                .help(model.draft == nil
                      ? "Start a new session: pick an app and a folder."
                      : "Cancel the new session.")
            }
        }
    }

    @ViewBuilder var messages: some View {
        let any = model.refreshError != nil || model.error != nil || !model.accountProblems.isEmpty
            || !model.dropped.isEmpty
        if any {
            VStack(alignment: .leading, spacing: 6) {
                if let problem = model.refreshError {
                    Banner(text: problem, systemImage: "exclamationmark.triangle.fill", tint: .red,
                           help: "Tend can't read its sessions. It tries again every 5 seconds.")
                }
                if let error = model.error {
                    Banner(text: error, systemImage: "xmark.octagon.fill", tint: .red,
                           help: "The last action failed.") { model.error = nil }
                }
                if !model.dropped.isEmpty { DroppedBanner(chats: model.dropped) }
                ForEach(model.accountProblems) { account in
                    Banner(text: account.problem ?? "\(account.name) needs attention.",
                           systemImage: "person.crop.circle.badge.exclamationmark", tint: .orange,
                           help: "To log \(account.name) in, choose their account from the user menu in the menu bar or Control Center. Their Tend then restarts their sessions.")
                }
            }
        }
    }

    var emptyState: some View {
        VStack(spacing: 6) {
            Text("No sessions yet").font(.callout).fontWeight(.medium)
            Text("Start an app in a folder. Tend also lists tmux sessions you start yourself.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("New session") { model.newDraft() }
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    var footer: some View {
        HStack {
            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",")
            .help("The apps Tend recognizes, the terminal it opens sessions in, startup, and other accounts")
            Spacer()
            Button("Quit Tend") { NSApp.terminate(nil) }
                .help("Quit the menu bar app. Your tmux sessions keep running.")
        }
        .buttonStyle(.borderless)
    }
}

/// A message across the top of the panel, with an optional close button.
struct Banner: View {
    let text: String
    let systemImage: String
    let tint: Color
    var help: String = ""
    var onClose: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Close Message")
                    .help("Close this message.")
            }
        }
        .surface(.banner(tint))
        .help(help)
    }
}

/// Conversations that lost their connection when their session restarted,
/// as Claude Remote Control chats do after a reboot, with a way back.
struct DroppedBanner: View {
    @EnvironmentObject var model: Model
    let chats: [DroppedChat]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "bubble.left.and.exclamationmark.bubble.right.fill")
                    .foregroundStyle(.orange)
                Text(chats.count == 1
                     ? "A chat lost its connection when its session restarted."
                     : "\(chats.count) chats lost their connection when their sessions restarted.")
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if chats.count > 1 {
                    Button("Dismiss all") { model.act(["dismiss", "--all"]) }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .foregroundStyle(.secondary)
                        .help("Take every chat off this list. Their conversations stay on this Mac.")
                }
            }
            ForEach(chats) { chat in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(chat.label ?? chat.id).lineLimit(1)
                        Text("\(chat.session) · \(ago(chat.droppedAt))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .help(chat.id)
                    Spacer(minLength: 8)
                    Button("Recover") { model.act(["recover", chat.session, chat.id]) }
                        .controlSize(.small)
                        .help("Reopen this conversation in a new session in the same folder, connected to the Claude app. Tasks it was running in the background don't come back, so ask it to start them again.")
                    Button { model.act(["dismiss", chat.session, chat.id]) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Dismiss \(chat.label ?? chat.id)")
                        .help("Take this chat off the list. Its conversation stays on this Mac.")
                }
                .padding(.leading, 24)
            }
        }
        .surface(.banner(.orange))
    }

    func ago(_ t: Int) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(t)), relativeTo: Date())
    }
}

/// A small heading over a group of rows, with room for a button.
/// A quiet line for a watched account in the panel: whether it's logged in,
/// and a light that's green while its Tend runs. Problems also show as
/// banners at the top of the panel.
struct AccountRow: View {
    let account: AccountStatus

    var body: some View {
        HStack(spacing: 6) {
            Text(account.name)
            Text(account.loggedIn ? "logged in" : "not logged in")
            Spacer()
            if account.loggedIn {
                Circle().fill(account.tendRunning ? Color.green : Color.orange).frame(width: 6, height: 6)
                Text(account.tendRunning ? "Tend running" : "Tend not running")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .help(account.problem ?? "\(account.name) is logged in and their Tend is running, so their sessions restart if they stop.")
    }
}

/// The Restore conversation icon: a speech bubble, slashed when the setting is
/// off. It's drawn at 90% and one weight heavier, so it matches the
/// `autostartstop` icon beside it in size and stroke.
struct ConversationIcon: View {
    let off: Bool

    var body: some View {
        Group {
            if off {
                SlashedSymbol(name: "bubble.left", label: "Doesn't restore conversation", strokeScale: 1 / 0.9)
            } else {
                Image(systemName: "bubble.left").accessibilityLabel("Restores conversation")
            }
        }
        .fontWeight(.medium)
        .scaleEffect(0.9)
    }
}

/// An SF Symbol with a slash drawn like Apple's `.slash` variants, for
/// symbols that have none, like `bubble.left`. The geometry was measured from
/// `flag.slash`, `bell.slash`, and `autostartstop.slash`: a round-capped
/// stroke at 45 degrees, 0.072 of the point size wide, with a gap of 0.07 cut
/// on each side. It starts a little above the symbol's top edge and runs
/// into the bottom-right corner.
struct SlashedSymbol: View {
    let name: String
    /// What VoiceOver reads, like "Doesn't restore conversation".
    let label: String
    /// Multiplies the slash's stroke width, to match a symbol drawn heavier.
    var strokeScale: CGFloat = 1

    /// The point size the symbol was drawn at, from its rendered height.
    static func pointSize(of name: String, height: CGFloat) -> CGFloat {
        let probe: CGFloat = 100
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: probe, weight: .regular)),
              image.size.height > 0 else { return height }
        return height / (image.size.height / probe)
    }

    /// The slash's center line, stroke width, and gap, for a symbol of this size.
    func slash(_ size: CGSize) -> (line: Path, stroke: CGFloat, gap: CGFloat) {
        let pt = SlashedSymbol.pointSize(of: name, height: size.height)
        let half = pt * 0.6 / 2.squareRoot()
        let extra = pt * 0.1 / 2.squareRoot()
        let center = CGPoint(x: size.width / 2, y: size.height / 2 - pt * 0.13)
        let line = Path { p in
            p.move(to: CGPoint(x: center.x - half, y: center.y - half))
            p.addLine(to: CGPoint(x: center.x + half + extra, y: center.y + half + extra))
        }
        return (line, pt * 0.072 * strokeScale, pt * 0.07)
    }

    var body: some View {
        Image(systemName: name)
            .mask {
                Canvas { context, size in
                    let s = slash(size)
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
                    context.blendMode = .destinationOut
                    context.stroke(s.line, with: .color(.black),
                                   style: StrokeStyle(lineWidth: s.stroke + 2 * s.gap, lineCap: .round))
                }
            }
            .overlay {
                GeometryReader { g in
                    let s = slash(g.size)
                    s.line.stroke(style: StrokeStyle(lineWidth: s.stroke, lineCap: .round))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Text(title).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            Spacer()
            trailing.font(.caption).buttonStyle(.borderless)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
    }
}

/// The form behind the plus button. It runs `tend new`, which tracks the
/// session and starts it.
struct NewSessionForm: View {
    @EnvironmentObject var model: Model

    /// The width of the form's label column, so the fields line up.
    static let labelWidth: CGFloat = 64

    var launchable: [AppProfile] { model.apps.filter { $0.enabled && $0.launch != nil } }

    /// The 5 folders you used last, and the 5 most recently changed folders
    /// next to them (your other projects), from `tend folders`. The menu
    /// leaves out the chosen folder and repeats nothing. Choose… reaches
    /// every other folder.
    var suggestions: (recent: [String], nearby: [String]) {
        let current = model.draft?.dir
        let recent = (model.folders?.recent ?? []).filter { $0 != current }.prefix(5)
        let nearby = (model.folders?.nearby ?? []).filter { $0 != current && !recent.contains($0) }.prefix(5)
        return (Array(recent), Array(nearby))
    }

    var body: some View {
        if let draft = model.draft {
            let binding = Binding { model.draft ?? draft } set: { model.draft = $0 }
            VStack(alignment: .leading, spacing: 10) {
                Text("New session").font(.subheadline).fontWeight(.semibold)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        label("App")
                        Picker("App", selection: binding.appID) {
                            ForEach(launchable) { app in
                                if let image = AppIcons.image(app.icon) {
                                    Label { Text(app.title) } icon: { Image(nsImage: image) }.tag(Optional(app.id))
                                } else {
                                    Text(app.title).tag(Optional(app.id))
                                }
                            }
                            Text("Other command").tag(String?.none)
                        }
                        .labelsHidden()
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: draft.appID) { _, id in
                            model.draft?.command = launchable.first { $0.id == id }?.launch ?? ""
                            if id == nil { model.draft?.showOptions = true }
                        }
                        .help("The app to run. Add apps, and their launch commands, in Settings.")
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        label("Folder")
                        let s = suggestions
                        FolderPicker(
                            url: Binding { URL(fileURLWithPath: model.draft?.dir ?? draft.dir) }
                                set: { model.draft?.dir = $0.path },
                            recent: s.recent.map { URL(fileURLWithPath: $0) },
                            nearby: s.nearby.map { URL(fileURLWithPath: $0) },
                            choose: model.chooseFolder)
                            .fixedSize()
                            .help("\(shortPath(draft.dir)). Click for recent folders and the folders next to them. You can also drop a folder here.")
                        Button("Choose…", action: model.chooseFolder)
                            .help("Choose any folder with the open panel.")
                        Spacer(minLength: 0)
                    }

                    // The disclosure sits with the fields it reveals, so the
                    // bottom row holds only Cancel and Start, as in a dialog.
                    HStack(spacing: 8) {
                        Color.clear.frame(width: NewSessionForm.labelWidth, height: 0)
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { model.draft?.showOptions.toggle() }
                        } label: {
                            Label("Options", systemImage: "chevron.right")
                                .labelStyle(DisclosureLabelStyle(expanded: draft.showOptions))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityValue(draft.showOptions ? "Expanded" : "Collapsed")
                        .help("Name, command, setup, and what to restore")
                        Spacer(minLength: 0)
                    }

                    if draft.showOptions {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            label("Name")
                            TextField("Name", text: binding.name,
                                      prompt: Text((draft.dir as NSString).lastPathComponent))
                                .labelsHidden()
                                .help("The tmux session name. If you leave it empty, Tend uses the folder name, plus a number if that name is taken.")
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            label("Command")
                            TextField("Command", text: binding.command)
                                .labelsHidden()
                                .font(.system(.body, design: .monospaced))
                                .help("The command Tend types into the new session's shell")
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            label("Setup")
                            Picker("Setup", selection: binding.setupID) {
                                Text("None").tag("")
                                ForEach(model.recipes) { Text($0.title).tag($0.id) }
                                Text("Custom command").tag("custom")
                            }
                            .labelsHidden()
                            .fixedSize()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .onChange(of: draft.setupID) { _, _ in model.draft?.setupText = "" }
                            .help("Something to run once in the folder before the app starts, like cloning a repository. Restarts don't run it again.")
                        }
                        if let field = setupField {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                label(field.label)
                                TextField(field.label, text: binding.setupText, prompt: Text(field.prompt))
                                    .labelsHidden()
                                    .font(.system(.body, design: .monospaced))
                                    .help(field.help)
                            }
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Color.clear.frame(width: NewSessionForm.labelWidth, height: 0)
                            Toggle(isOn: binding.autostart) { Label("Restore at login", systemImage: "autostartstop") }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help("Start this session again when Tend restores sessions")
                        }
                        if draft.appID != nil {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Color.clear.frame(width: NewSessionForm.labelWidth, height: 0)
                                Toggle(isOn: binding.restoreConversation) { Label("Restore conversation", systemImage: "bubble.left") }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .help("Bring back the conversation when the session restarts. Turn this off to start the plain command every time, with nothing to recover if a conversation is lost.")
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()
                    .padding(.top, 2)

                // Cancel and Start, apart from the fields and at the bottom
                // right, where a Mac dialog puts its buttons.
                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel") { model.draft = nil }
                        .secondaryActionStyle()
                        .keyboardShortcut(.cancelAction)
                    Button("Start") { model.create() }
                        .primaryActionStyle()
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft.dir.isEmpty || draft.command.trimmingCharacters(in: .whitespaces).isEmpty
                                  || (setupField != nil && draft.setupText.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
            .surface(.card)
        }
    }

    func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
            .frame(width: NewSessionForm.labelWidth, alignment: .trailing)
    }

    /// A disclosure label: the chevron turns down when the section is open,
    /// like the disclosure triangles in a Mac dialog.
    struct DisclosureLabelStyle: LabelStyle {
        let expanded: Bool

        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 4) {
                configuration.icon
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                configuration.title
            }
        }
    }

    /// The text field the chosen setup needs, if any.
    var setupField: (label: String, prompt: String, help: String)? {
        guard let id = model.draft?.setupID, !id.isEmpty else { return nil }
        if id == "custom" {
            return ("Setup", "git init", "A shell command Tend runs in the folder before the app starts")
        }
        guard let r = model.recipes.first(where: { $0.id == id }), r.needsInput else { return nil }
        let label = r.input ?? "Input"
        return (label, label, "Fills in {input} in: \(r.setup)")
    }
}

/// A folder chooser: a pop-up `NSPathControl` that shows the folder with its
/// icon. Its menu lists the folder's parents, the recent and nearby folders
/// tend suggests, and Choose…, which opens the standard open panel. You can
/// also drop a folder on it.
struct FolderPicker: NSViewRepresentable {
    @Binding var url: URL
    var recent: [URL] = []
    var nearby: [URL] = []
    /// Runs the open panel for Choose….
    var choose: () -> Void

    /// NSPathControl tells VoiceOver it's static text with a URL. In pop-up
    /// style it's a pop-up button, so say that, and let VoiceOver open it.
    final class PopUpPathControl: NSPathControl {
        override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }
        override func accessibilityValue() -> Any? { url.map { shortPath($0.path) } }
        override func accessibilityPerformPress() -> Bool {
            performClick(nil)
            return true
        }
    }

    func makeNSView(context: Context) -> NSPathControl {
        let control = PopUpPathControl()
        control.pathStyle = .popUp
        control.isEditable = true  // Takes drops.
        control.allowedTypes = ["public.folder"]
        control.url = url
        control.delegate = context.coordinator
        control.target = context.coordinator
        control.action = #selector(Coordinator.pathChosen(_:))
        control.setAccessibilityLabel("Folder")
        return control
    }

    func updateNSView(_ control: NSPathControl, context: Context) {
        context.coordinator.parent = self
        if control.url != url { control.url = url }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSPathControlDelegate {
        var parent: FolderPicker

        init(_ parent: FolderPicker) { self.parent = parent }

        /// A parent folder chosen from the menu, or a folder dropped on it.
        @objc func pathChosen(_ control: NSPathControl) {
            if let url = control.clickedPathItem?.url ?? control.url { parent.url = url }
        }

        @objc func folderChosen(_ item: NSMenuItem) {
            if let url = item.representedObject as? URL { parent.url = url }
        }

        @objc func chooseOther(_ item: NSMenuItem) {
            // Let the menu close before the open panel runs.
            DispatchQueue.main.async { self.parent.choose() }
        }

        func pathControl(_ pathControl: NSPathControl, willPopUp menu: NSMenu) {
            menu.removeAllItems()
            var parents: [URL] = []
            var u = parent.url.standardizedFileURL
            while true {
                parents.append(u)
                let up = u.deletingLastPathComponent()
                if up.path == u.path { break }
                u = up
            }
            parents.forEach { menu.addItem(item($0, title: FileManager.default.displayName(atPath: $0.path))) }
            for (title, urls) in [("Recent", parent.recent), ("Nearby", parent.nearby)] where !urls.isEmpty {
                menu.addItem(.separator())
                menu.addItem(.sectionHeader(title: title))
                urls.forEach { menu.addItem(item($0, title: shortPath($0.path))) }
            }
            menu.addItem(.separator())
            let other = NSMenuItem(title: "Choose…", action: #selector(chooseOther(_:)), keyEquivalent: "")
            other.target = self
            menu.addItem(other)
        }

        private func item(_ url: URL, title: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(folderChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            item.toolTip = url.path
            return item
        }

        func pathControl(_ pathControl: NSPathControl, validateDrop info: NSDraggingInfo) -> NSDragOperation {
            Model.folders(in: urls(info)).isEmpty ? [] : .generic
        }

        func pathControl(_ pathControl: NSPathControl, acceptDrop info: NSDraggingInfo) -> Bool {
            guard let folder = Model.folders(in: urls(info)).first else { return false }
            parent.url = folder
            return true
        }

        private func urls(_ info: NSDraggingInfo) -> [URL] {
            info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        }
    }
}

/// One session. The leading icon shows the app and, in its badge, the
/// state. The main action always shows; the others show on hover, on the
/// selected row, or always if you turn that on in Settings. Restart, Start
/// fresh, and Stop tracking ask first.
struct SessionRow: View {
    @EnvironmentObject var model: Model
    @AppStorage("alwaysShowRowButtons") private var alwaysShowButtons = false
    @State private var hovering = false
    @State private var reply = ""
    @State private var newName = ""
    @FocusState private var nameFocused: Bool
    let session: Session
    /// Whether the session list has the keyboard, which draws the selection
    /// in the accent color.
    var listFocused = false
    /// Selects the row, when you click it.
    var select: () -> Void = {}

    var question: AppInfo.Question? { session.app?.question }
    var selected: Bool { model.selection == session.name }
    /// White text on the accent color, as in a menu or a focused source list.
    var prominent: Bool { selected && listFocused && !renaming }
    var confirming: Model.Confirming.Kind? {
        model.confirming?.name == session.name ? model.confirming?.kind : nil
    }
    var renaming: Bool { model.renaming == session.name }
    var peekLines: [String]?? {
        model.peek?.name == session.name ? .some(model.peek?.lines) : .none
    }

    /// Orange means the session needs you. Nothing else uses it.
    var badge: Color {
        if question != nil { return .orange }
        switch session.state {
        case .running: return .green
        case .exited: return .yellow
        default: return .gray
        }
    }

    var status: (text: String, color: Color) {
        switch session.state {
        case .running:
            if let s = session.app?.status { return (s, s == "busy" && !prominent ? .blue : .secondary) }
            return ("running", .secondary)
        case .exited: return ("exited", .secondary)
        default: return ("stopped", .secondary)
        }
    }

    var stateHint: String {
        var hint: String
        switch session.state {
        case .running: hint = "\(session.name) is running."
        case .exited: hint = "\(session.name)'s command exited. The tmux session is still open at a shell prompt."
        default: hint = "\(session.name) isn't running."
        }
        if let app = session.app {
            hint += " It runs \(app.name)" + (app.status.map { ", which is \($0)." } ?? ".")
        }
        if question != nil { hint += " It's waiting for your answer." }
        return hint
    }

    /// The folder, or its parent when the folder's name is the session's name.
    var folder: String {
        if session.namedAfterDir {
            return shortPath((session.dir as NSString).deletingLastPathComponent) + "/"
        }
        return shortPath(session.dir)
    }

    var details: String {
        "Folder: \(shortPath(session.dir))\nCommand: \(session.command ?? "shell")"
            + (!session.restoreConversation
                ? "\nStarts its command every time. Tend doesn't bring back its conversation."
                : session.resume.map { "\nResumes with: \($0)" } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            mainLine
            if let q = question { questionCard(q) }
            if let lines = peekLines { peekCard(lines) }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Design.rowCornerRadius)
            .fill(hovering && !selected ? Color.primary.opacity(0.06) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .task(id: model.confirming) {
            // A confirmation you don't act on goes away by itself.
            guard confirming != nil, (try? await Task.sleep(for: .seconds(6))) != nil,
                  model.confirming?.name == session.name else { return }
            model.confirming = nil
        }
    }

    /// The icon, name, folder, status, and buttons. The selection highlights
    /// this line, and VoiceOver reads it as one element with actions.
    var mainLine: some View {
        HStack(spacing: 8) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if renaming {
                        renameField
                    } else {
                        Text(session.name).fontWeight(.medium).lineLimit(1)
                    }
                    settingIcons
                }
                Text(folder).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
                    .help(details)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: Design.rowCornerRadius).fill(Color(nsColor: listFocused && !renaming
                    ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor))
            }
        }
        .environment(\.backgroundProminence, prominent ? .increased : .standard)
        .foregroundStyle(prominent ? Color.white : Color.primary)
        .padding(.horizontal, -6)
        .padding(.vertical, -4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.primaryAction(session) }
        .simultaneousGesture(TapGesture().onEnded(select))
        .onDrag { Model.dragItem(for: session) }
        // While you rename it, the field is its own element.
        .accessibilityElement(children: renaming ? .contain : .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(session.state == .stopped ? "Starts the session." : "Opens the session in a terminal window.")
        .accessibilityAction { model.primaryAction(session) }
        .accessibilityActions { accessibilityActions }
    }

    var accessibilityText: String {
        var parts = [session.name, status.text, "in \(shortPath(session.dir))"]
        if !session.managed { parts.append("not tracked") }
        if question != nil { parts.append("waiting for your answer") }
        if session.managed && !session.autostart { parts.append("doesn't restore at login") }
        if session.managed && !session.restoreConversation { parts.append("doesn't restore conversation") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder var accessibilityActions: some View {
        if session.state != .stopped {
            Button(model.peek?.name == session.name ? "Hide Recent Output" : "Show Recent Output") {
                model.togglePeek(session.name)
            }
            Button("Stop") { model.act(["stop", session.name]) }
        }
        if session.managed {
            if session.state != .stopped { Button("Restart") { model.confirming = .init(name: session.name, kind: .restart) } }
            Button("Stop Tracking") { model.confirming = .init(name: session.name, kind: .untrack) }
        } else {
            Button("Track") { model.act(["snapshot", session.name]) }
        }
        Button("Rename") { startRename() }
        if let attach = session.attach { Button("Copy Attach Command") { Model.copy(attach) } }
        Button("Copy Path") { Model.copy(session.dir) }
        Button("Show in Finder") { showInFinder() }
    }

    var renameField: some View {
        TextField("Name", text: $newName)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .labelsHidden()
            .focused($nameFocused)
            .onSubmit { model.rename(session.name, to: newName) }
            .onExitCommand { model.renaming = nil }
            .onKeyPress(.escape) {
                model.renaming = nil
                return .handled
            }
            .onAppear {
                newName = session.name
                // After the field is in the window, or the list keeps the keyboard.
                DispatchQueue.main.async { nameFocused = true }
            }
            .onChange(of: nameFocused) { _, focused in
                // Clicking elsewhere keeps the new name, as in Finder.
                if !focused && model.renaming == session.name { model.rename(session.name, to: newName) }
            }
            .help("Press Return to rename \(session.name), or Esc to keep its name.")
    }

    var leading: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image = AppIcons.image(session.app?.icon, size: 18) {
                    Image(nsImage: image)
                } else {
                    Image(systemName: "terminal").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)
            .opacity(session.state == .stopped ? 0.45 : 1)
            // Cut a gap around the dot out of the icon, rather than drawing a
            // ring, so the panel's material shows through.
            .mask {
                ZStack(alignment: .bottomTrailing) {
                    Rectangle()
                    Circle().frame(width: 10, height: 10)
                        .offset(x: 3.5, y: 3.5)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            Circle().fill(badge)
                .frame(width: 7, height: 7)
                .offset(x: 2, y: 2)
        }
        .help(stateHint)
    }

    @ViewBuilder var trailing: some View {
        if let c = confirming {
            HStack(spacing: 6) {
                Button("Cancel") { model.confirming = nil }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                Button(confirmTitle(c), role: .destructive) {
                    model.confirming = nil
                    switch c {
                    case .fresh: model.act(["restart", session.name, "--fresh"])
                    case .restart: model.act(["restart", session.name])
                    case .untrack: model.act(["rm", session.name])
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
                .help(confirmHelp(c))
            }
        } else {
            HStack(spacing: 4) {
                // Hidden, not removed, so the row doesn't shift on hover.
                let show = hovering || selected || alwaysShowButtons
                HStack(spacing: 4) { secondaryButtons }
                    .opacity(show ? 1 : 0)
                    .allowsHitTesting(show)
                Text(status.text).font(.caption).foregroundStyle(status.color)
                    .padding(.horizontal, 2)
                primaryButton
            }
        }
    }

    func confirmTitle(_ c: Model.Confirming.Kind) -> String {
        switch c {
        case .fresh: "Start fresh"
        case .restart: "Restart"
        case .untrack: "Stop tracking"
        }
    }

    func confirmHelp(_ c: Model.Confirming.Kind) -> String {
        switch c {
        case .fresh: "Stop \(session.name) and start its command again, without reattaching to its last session."
        case .restart: restartHelp
        case .untrack: "Take \(session.name) off the list. Its tmux session keeps running, and Tend no longer restores it."
        }
    }

    var restartHelp: String {
        session.resume != nil
            ? "Stop \(session.name) and start it again, reattached to the same session."
            : "Stop \(session.name) and start it again."
    }

    @ViewBuilder var primaryButton: some View {
        if session.state == .stopped {
            icon("play.fill", "Start", session.resume != nil
                 ? "Start \(session.name) and reattach to its last session: \(session.resume!)"
                 : "Start \(session.name).") { model.act(["start", session.name]) }
        } else {
            icon("macwindow", "Open", "Open \(session.name) in a new terminal window.") { model.act(["open", session.name]) }
        }
    }

    @ViewBuilder var secondaryButtons: some View {
        if session.state != .stopped {
            if session.managed {
                icon("arrow.triangle.2.circlepath", "Restart", restartHelp + " Tend asks first.") {
                    model.confirming = .init(name: session.name, kind: .restart)
                }
            } else {
                icon("plus.circle", "Track", "Track \(session.name), so Tend restores it.") { model.act(["snapshot", session.name]) }
            }
            icon("stop.fill", "Stop", "Stop \(session.name) by closing its tmux session." + (session.managed ? " It stays on the list." : "")) { model.act(["stop", session.name]) }
        }
    }

    func questionCard(_ q: AppInfo.Question) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(q.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            } icon: {
                Image(systemName: "questionmark.bubble").foregroundStyle(.orange)
            }
            .font(.callout)
            if let context = q.context, !context.isEmpty {
                Text(context.joined(separator: "\n"))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(12)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                if q.free_text == true {
                    TextField("Reply", text: $reply)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .onSubmit(sendReply)
                        .help("Type a reply to \(session.name). Press Return to send it. An empty reply takes the default.")
                    Button("Send", action: sendReply)
                        .controlSize(.small)
                        .help("Type your reply in \(session.name) and press Return.")
                }
                Spacer()
                ForEach(q.answers, id: \.id) { a in
                    Button(a.label) { model.act(["answer", session.name, a.id]) }
                        .controlSize(.small)
                        .help("Answer \(session.name)'s question: \(a.label)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(.question)
    }

    /// The last lines the session's pane shows, from `tend peek`. It
    /// updates with every refresh while it's open.
    func peekCard(_ lines: [String]?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Recent output").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                Spacer()
                Button { model.peek = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .controlSize(.small)
                    .accessibilityLabel("Hide Recent Output")
                    .help("Hide the recent output. Space does too.")
            }
            if let lines {
                ScrollView(.horizontal) {
                    Text(lines.isEmpty ? "(no output)" : lines.joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced))
                        .fixedSize()
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(.peek)
    }

    func sendReply() {
        model.act(["answer", session.name, "--text", reply])
        reply = ""
    }

    func startRename() {
        model.selection = session.name
        model.renaming = session.name
    }

    func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.dir)])
    }

    @ViewBuilder var menu: some View {
        if session.state == .stopped {
            Button("Start") { model.act(["start", session.name]) }
        } else {
            Button("Open in Terminal") { model.act(["open", session.name]) }
            Button(model.peek?.name == session.name ? "Hide Recent Output" : "Show Recent Output") {
                model.togglePeek(session.name)
            }
        }
        Divider()
        Button("Show in Finder", action: showInFinder)
        if let attach = session.attach {
            Button("Copy Attach Command") { Model.copy(attach) }
        }
        Button("Copy Path") { Model.copy(session.dir) }
        Button("Rename…", action: startRename)
        if session.managed {
            Divider()
            if session.state != .stopped {
                Button("Restart") { model.confirming = .init(name: session.name, kind: .restart) }
            }
            Button("Start fresh") { model.confirming = .init(name: session.name, kind: .fresh) }
            Button(session.autostart ? "Don't restore at login" : "Restore at login") {
                model.act(["autostart", session.name, session.autostart ? "off" : "on"])
            }
            if session.app != nil || !session.restoreConversation {
                Button(session.restoreConversation ? "Don't restore conversation" : "Restore conversation") {
                    model.act(["restore-conversation", session.name, session.restoreConversation ? "off" : "on"])
                }
            }
        }
        if session.state != .stopped {
            Button("Stop") { model.act(["stop", session.name]) }
        }
        Divider()
        if session.managed {
            Button("Stop tracking") { model.confirming = .init(name: session.name, kind: .untrack) }
        } else {
            Button("Track") { model.act(["snapshot", session.name]) }
        }
    }

    /// Whether the session can resume, so Restore conversation means something.
    var canResume: Bool { session.app != nil || session.resume != nil || !session.restoreConversation }

    /// An icon for each restore setting. A setting that's off always shows,
    /// slashed. Settings that are on show, lighter, while you hover.
    @ViewBuilder var settingIcons: some View {
        if session.managed {
            let show = hovering || alwaysShowButtons
            HStack(spacing: 3) {
                if !session.autostart {
                    Image(systemName: "autostartstop.slash")
                        .accessibilityLabel("Doesn't restore at login")
                        .help("Tend doesn't start \(session.name) when it restores sessions. Right-click the row to change that.")
                } else if show {
                    Image(systemName: "autostartstop").foregroundStyle(.tertiary)
                        .accessibilityLabel("Restores at login")
                        .help("Tend starts \(session.name) when it restores sessions, like after the Mac restarts.")
                }
                if !session.restoreConversation {
                    ConversationIcon(off: true)
                        .help("\(session.name) starts its command every time. Tend doesn't bring back its conversation or list it as dropped. Right-click the row to change that.")
                } else if show && canResume {
                    ConversationIcon(off: false).foregroundStyle(.tertiary)
                        .help("Tend brings back \(session.name)'s conversation when it restarts.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// An icon-only button, with a name for VoiceOver and a tooltip.
    func icon(_ name: String, _ title: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: name).labelStyle(.iconOnly) }
            .buttonStyle(.borderless)
            .help(help)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                Banner(text: error, systemImage: "xmark.octagon.fill", tint: .red,
                       help: "The last action failed.") { model.error = nil }
                    .padding([.horizontal, .top], 12)
            }
            TabView {
                GeneralPane().settingsPane(height: 560)
                    .tabItem { Label("General", systemImage: "gearshape") }
                AppsPane().settingsPane(height: 340)
                    .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
                TerminalPane().settingsPane(height: 300)
                    .tabItem { Label("Terminal", systemImage: "terminal") }
                AccountsPane().settingsPane(height: 330)
                    .tabItem { Label("Accounts", systemImage: "person.2") }
            }
        }
        .settingsWindowFrame()
    }
}

struct GeneralPane: View {
    @EnvironmentObject var model: Model
    @AppStorage("alwaysShowRowButtons") private var alwaysShowButtons = false
    @AppStorage(Model.restoreOnLaunchKey) private var restoreOnLaunch = true
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var cliPath: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open Tend at login", isOn: $openAtLogin)
                    .help("Open Tend when you log in. With the setting below, this restores your sessions after the Mac starts.")
                    .onChange(of: openAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            model.error = "Couldn't change the login item: \(error.localizedDescription)"
                            openAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("Restore sessions after the Mac starts", isOn: $restoreOnLaunch)
                    .help("The first time Tend opens after the Mac starts, start every tracked session that's set to restore. If you quit Tend or it crashes, your sessions keep running, and opening Tend again doesn't start or stop anything.")
            }
            UpdatesSection()
            Section("Panel") {
                Toggle("Always show session buttons", isOn: $alwaysShowButtons)
                    .help("Show every row's buttons all the time, not only when the pointer is over the row. The Open or Start button always shows.")
            }
            Section("Command line") {
                LabeledContent("tend") {
                    if let cliPath {
                        Text(shortPath(cliPath)).foregroundStyle(.secondary).textSelection(.enabled)
                    } else {
                        Button("Install") {
                            model.installCLI()
                            cliPath = model.cliPath
                        }
                        .disabled(Model.setupProblem != nil)
                        .help("Link tend into ~/.local/bin, so you can run it in a terminal and over ssh. Add ~/.local/bin to your PATH if it isn't there already.")
                    }
                }
                LabeledContent("Config") {
                    if let path = model.configPaths?.config {
                        let name = (path as NSString).lastPathComponent
                        Button("Open \(name)") {
                            if !NSWorkspace.shared.open(URL(fileURLWithPath: path)) {
                                model.error = "Couldn't open \(path). Tend creates it when you track a session."
                            }
                        }
                        .help("Open \(shortPath(path)), the list of tracked sessions, apps, and settings.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { cliPath = model.cliPath }
    }
}

/// The apps tend recognizes. Turn one off to stop recognizing it, or add any
/// program by choosing its executable.
struct AppsPane: View {
    @EnvironmentObject var model: Model

    var body: some View {
        Form {
            Section {
                ForEach(model.apps) { app in
                    Toggle(isOn: Binding(
                        get: { app.enabled },
                        set: { model.act(["apps", $0 ? "enable" : "disable", app.id]) }
                    )) {
                        HStack(spacing: 8) {
                            AppIconView(spec: app.icon, size: 20)
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(spacing: 6) {
                                    Text(app.title)
                                    if app.builtin {
                                        Text("Built in").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Text(app.rules).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    .help("Recognize processes that match: \(app.rules)" + (app.builtin ? "" : ". Right-click to remove it."))
                    .contextMenu {
                        if !app.builtin {
                            Button("Remove") { model.act(["apps", "rm", app.id]) }
                        }
                    }
                }
            } header: {
                Text("The programs Tend looks for in each tmux session")
            } footer: {
                HStack {
                    Spacer()
                    Button("Add app…", action: addApp)
                        .help("Choose a program. Tend then recognizes it when it runs in a tmux session.")
                }
            }
        }
        .formStyle(.grouped)
    }

    func addApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose a program for Tend to recognize"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, var url = panel.url else { return }
        // For a .app bundle, use its main executable, and its icon.
        var icon: [String] = []
        if url.pathExtension == "app", let bundle = Bundle(url: url), let exe = bundle.executableURL {
            icon = ["--icon", bundle.bundleIdentifier ?? url.path]
            url = exe
        }
        model.act(["apps", "add", url.path] + icon)
    }
}

/// How the open button opens a session: which terminal app, and which
/// command it runs there. Use tmux control mode for iTerm2's tmux integration.
struct TerminalPane: View {
    @EnvironmentObject var model: Model
    @State private var custom = ""
    @State private var editingCustom = false

    var body: some View {
        Form {
            if let t = model.terminal {
                Section {
                    Picker("App", selection: Binding(
                        get: { t.app },
                        set: { model.setTerminal(app: $0) }
                    )) {
                        ForEach(t.apps, id: \.self) { Text($0).tag($0) }
                    }
                    .help("The terminal app that the open button opens sessions in")

                    Picker("Attach with", selection: Binding(
                        get: { editingCustom ? "custom" : t.mode },
                        set: { mode in
                            if mode == "custom" {
                                custom = t.attach
                                editingCustom = true
                            } else {
                                editingCustom = false
                                model.setTerminal(attach: mode)
                            }
                        }
                    )) {
                        Text("tmux attach").tag("tmux")
                        Text("iTerm2 tmux integration (tmux -CC)").tag("control")
                        Text("Custom command").tag("custom")
                    }
                    .help("tmux attach shows the session in one terminal window. tmux -CC uses control mode: iTerm2 shows each tmux window as a native window or tab.")

                    if editingCustom || t.mode == "custom" {
                        HStack {
                            TextField("Command", text: $custom)
                                .font(.system(.body, design: .monospaced))
                                .onSubmit(saveCustom)
                            Button("Save", action: saveCustom)
                                .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty
                                          || custom == t.attach)
                        }
                        .help("The command to run in the new window. {tmux} is the path to tmux, {target} is the session's tmux target, and {name} is the session name.")
                    }
                } header: {
                    Text("How the open button opens a session")
                } footer: {
                    if t.mode == "control" && t.app != "iTerm" {
                        Label("tmux -CC needs iTerm2. Terminal shows control mode as raw text.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .onAppear { if t.mode == "custom" { custom = t.attach } }
            } else {
                Text("Tend couldn't read its terminal settings.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    func saveCustom() {
        editingCustom = false
        model.setTerminal(attach: custom)
    }
}

/// Other accounts on this Mac, like a family member's under fast user switching.
/// Tend warns when a watched account isn't logged in or isn't running Tend,
/// because then that account's sessions aren't running.
struct AccountsPane: View {
    @EnvironmentObject var model: Model
    @State private var selection: String?

    var watched: [AccountStatus] { model.accounts?.watched ?? [] }
    var available: [Accounts.Available] { model.accounts?.available ?? [] }

    var body: some View {
        Form {
            Section {
                if available.isEmpty && watched.isEmpty {
                    Text("This Mac has no other accounts.").foregroundStyle(.secondary)
                } else {
                    // A list with + and − buttons beneath it, as in System Settings.
                    VStack(spacing: 0) {
                        List(selection: $selection) {
                            ForEach(watched) { account in
                                HStack {
                                    Circle().fill(account.ok ? Color.green : Color.orange).frame(width: 8, height: 8)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(account.name)
                                        Text(account.ok ? "Tend is running."
                                             : account.loggedIn ? "Logged in, but Tend isn't running." : "Not logged in.")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .accessibilityElement(children: .combine)
                                .tag(account.user)
                            }
                        }
                        .listStyle(.bordered(alternatesRowBackgrounds: true))
                        .frame(height: 160)
                        .overlay {
                            if watched.isEmpty {
                                Text("No accounts watched").foregroundStyle(.secondary)
                            }
                        }
                        .onDeleteCommand(perform: removeSelected)
                        addRemoveBar
                    }
                    .overlay(Rectangle().strokeBorder(Color(nsColor: .separatorColor)))
                }
            } header: {
                Text("Other accounts on this Mac")
            } footer: {
                Text("Tend warns you when a watched account isn't logged in or isn't running Tend, because then that account's sessions aren't running. Install Tend in that account too, with Open Tend at login on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    var addRemoveBar: some View {
        HStack(spacing: 0) {
            Menu {
                ForEach(available, id: \.self) { a in
                    Button(a.name) { model.watchAccount(a.user, true) }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 28, height: 22)
            .disabled(available.isEmpty)
            .accessibilityLabel("Watch an Account")
            .help(available.isEmpty ? "Every other account on this Mac is already watched."
                  : "Warn me when an account isn't logged in or isn't running Tend.")
            Divider().frame(height: 16)
            Button(action: removeSelected) {
                Image(systemName: "minus").frame(width: 28, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(selection == nil)
            .accessibilityLabel("Stop Watching")
            .help("Stop watching the selected account")
            Spacer()
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }

    func removeSelected() {
        guard let user = selection else { return }
        selection = nil
        model.watchAccount(user, false)
    }
}
