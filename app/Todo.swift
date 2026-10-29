// Todo.app — a small always-on-top window over your to-do list.
//
// Folded, the window is a pill with the item count and a dot per agent session
// at work; a click opens the list, and clicking another app folds it again.
// The window is a thin view over the `todo` CLI (bin/todo): it reads
// `todo list --json` and writes through `todo add` / `todo done`, so the list
// logic lives in one place. It refreshes every minute and immediately when the
// CLI posts the Darwin notification com.rubenhaisma.todo.changed. Which agent
// session works on what comes from `todo claims --json`, read every few
// seconds and on com.rubenhaisma.todo.claims.

import AppKit
import Combine
import notify
import SwiftUI

// MARK: - Model

struct Item: Decodable, Identifiable, Hashable {
    let ref: String
    let repo: String
    let number: Int
    let title: String
    let url: String
    let updatedAt: String
    let personal: Bool
    let labels: [String]
    /// GitHub's colour per label name, hex without the "#".
    let labelColors: [String: String]?
    /// Set when you created the issue but someone else holds it.
    let waitingOn: [String]?

    struct Badge: Hashable {
        let text: String
        let hex: String?
    }

    var id: String { ref }
    /// GitHub names ignore case; claims are matched on this.
    var key: String { ref.lowercased() }
    var waiting: [String] { waitingOn ?? [] }
    var isHighPriority: Bool { labels.contains("priority: high") }
    /// Labels worth a badge: all of them on personal items, only status on team issues.
    var badges: [Badge] {
        let shown = personal ? labels : labels.filter { $0.hasPrefix("status: ") }
        return shown.map {
            Badge(text: personal ? $0 : String($0.dropFirst("status: ".count)), hex: labelColors?[$0])
        }
    }

    private static let iso = ISO8601DateFormatter()
    var updated: Date? { Item.iso.date(from: updatedAt) }
}

/// An agent session working on an item (`todo claim`).
struct Claim: Decodable, Hashable {
    let ref: String
    let agent: String
    let session: String
    let since: TimeInterval
    let lastActive: TimeInterval
    /// The session did something in the last couple of minutes.
    let active: Bool
    /// What a click opens, as `todo claim` found it: a link to the session in
    /// the Claude or Codex app, or the path of the app the agent runs in.
    let open: String?

    var title: String { Agent(rawValue: agent)?.title ?? agent.capitalized }
    var color: Color { Agent(rawValue: agent)?.color ?? .secondary }

    /// Only the links the CLI writes, or an app: a claim file is no reason to
    /// open anything else.
    var target: URL? {
        guard let open else { return nil }
        if open.hasPrefix("/") {
            return open.hasSuffix(".app") && FileManager.default.fileExists(atPath: open) ? URL(fileURLWithPath: open) : nil
        }
        let links = "^(claude://code/continue\\?session=local_[A-Za-z0-9-]{1,64}|codex://threads/[A-Za-z0-9-]+)$"
        return open.range(of: links, options: .regularExpression) != nil ? URL(string: open) : nil
    }
}

enum Agent: String {
    case claude, codex

    var title: String { self == .claude ? "Claude" : "Codex" }
    var app: String { self == .claude ? "Claude Code" : "Codex" }
    var color: Color { self == .claude ? Palette.hex("D97757")! : Palette.hex("10A37F")! }
}

/// "5m", "3h", "2d", "6w", "4mo".
func shortDuration(_ seconds: TimeInterval) -> String {
    let s = max(0, seconds)
    return s < 3600 ? "\(Int(s / 60))m"
        : s < 86400 ? "\(Int(s / 3600))h"
        : s < 14 * 86400 ? "\(Int(s / 86400))d"
        : s < 60 * 86400 ? "\(Int(s / (7 * 86400)))w"
        : "\(Int(s / (30 * 86400)))mo"
}

enum Palette {
    /// Blue is left out for personal items (the accent colour), red for high priority.
    static let repos: [Color] = [.purple, .pink, .orange, .teal, .green, .indigo, .mint, .cyan, .brown]

    static func color(for item: Item) -> Color { item.personal ? .accentColor : repo(item.repo) }

    /// The same colour for a repo on every launch (Swift's hashValue is seeded per process).
    static func repo(_ name: String) -> Color {
        var h: UInt64 = 5381
        for byte in name.lowercased().utf8 { h = (h &<< 5) &+ h &+ UInt64(byte) }
        return repos[Int(h % UInt64(repos.count))]
    }

    static func hex(_ hex: String?) -> Color? { nsColor(hex).map(Color.init(nsColor:)) }

    private static func nsColor(_ hex: String?) -> NSColor? {
        guard let hex, hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    /// A GitHub label colour as a tinted badge. Many label colours are pastel,
    /// so the text gets the same hue at a brightness that reads on the panel.
    static func label(_ hex: String?, dark: Bool) -> (fg: Color, bg: Color) {
        guard let c = nsColor(hex)?.usingColorSpace(.deviceRGB) else {
            return (.secondary, Color.secondary.opacity(0.15))
        }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let fg = dark
            ? NSColor(hue: h, saturation: min(s, 0.55), brightness: max(b, 0.92), alpha: 1)
            : NSColor(hue: h, saturation: s, brightness: min(b, 0.5), alpha: 1)
        return (Color(nsColor: fg), Color(nsColor: c).opacity(dark ? 0.28 : 0.3))
    }
}

enum CLI {
    // TODO_CLI points a dev build at the CLI in a checkout.
    static let path = ProcessInfo.processInfo.environment["TODO_CLI"]
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/todo").path
    static let timeout: TimeInterval = 30

    struct Result {
        let status: Int32
        let out: Data
        let err: String
    }

    /// Runs the todo CLI synchronously; call it off the main thread.
    static func run(_ args: [String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        // Launched by launchd we get a bare PATH (install.sh adds the folders
        // gh and jq were found in); Homebrew's are the usual home of both.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        // `todo start` reads the checkout index only: scanning ~/Documents from
        // here would ask you to grant Todo.app folder access.
        env["TODO_NO_SCAN"] = "1"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch {
            return Result(status: -1, out: Data(), err: "could not run \(path): \(error.localizedDescription)")
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if p.isRunning { p.terminate() }
        }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var message = String(decoding: e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if p.terminationReason == .uncaughtSignal { message = "todo \(args.first ?? "") timed out after \(Int(timeout)) s" }
        return Result(status: p.terminationStatus, out: o, err: message)
    }
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    print("\(stamp) \(message)")
}

final class Store: ObservableObject {
    @Published private(set) var items: [Item] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var closing: Set<String> = []
    /// Items whose Do-now session is being opened, by ref.
    @Published private(set) var starting: [String: Agent] = [:]
    /// Agent sessions working on an item, by Item.key.
    @Published private(set) var claims: [String: [Claim]] = [:]

    private var refreshQueued = false
    private var readingClaims = false

    func refresh(_ reason: String) {
        refreshClaims()
        if loading { refreshQueued = true; return }
        loading = true
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let r = CLI.run(["list", "--json"])
            let decoded: Result<[Item], Error>
            if r.status == 0 {
                decoded = Result { try JSONDecoder().decode([Item].self, from: r.out) }
            } else {
                decoded = .failure(NSError(domain: "todo", code: Int(r.status),
                                           userInfo: [NSLocalizedDescriptionKey: r.err]))
            }
            DispatchQueue.main.async {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                switch decoded {
                case .success(let items):
                    self.items = items
                    self.error = nil
                    self.closing.formIntersection(items.map(\.ref))
                    log("refresh (\(reason)): \(items.count) items in \(ms) ms")
                case .failure(let e):
                    self.error = e.localizedDescription
                    log("refresh (\(reason)) failed in \(ms) ms: \(e.localizedDescription)")
                }
                self.loading = false
                if self.refreshQueued {
                    self.refreshQueued = false
                    self.refresh("queued")
                }
            }
        }
    }

    /// Claims are local files, so reading them is cheap enough to poll.
    func refreshClaims() {
        if readingClaims { return }
        readingClaims = true
        DispatchQueue.global(qos: .utility).async {
            let r = CLI.run(["claims", "--json"])
            let list = r.status == 0 ? try? JSONDecoder().decode([Claim].self, from: r.out) : nil
            DispatchQueue.main.async {
                self.readingClaims = false
                guard let list else {
                    log("todo claims failed: \(r.err)")
                    return
                }
                let byRef = Dictionary(grouping: list) { $0.ref.lowercased() }
                if byRef != self.claims { self.claims = byRef }
            }
        }
    }

    func add(_ title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        perform(["add", title])
    }

    func done(_ item: Item) {
        closing.insert(item.ref)
        perform(["done", item.ref]) { ok in if !ok { self.closing.remove(item.ref) } }
    }

    /// Opens a new Claude Code or Codex session in the issue's repo folder.
    func start(_ item: Item, in agent: Agent, then: @escaping (Bool) -> Void = { _ in }) {
        guard starting[item.ref] == nil else { return }
        starting[item.ref] = agent
        perform(["start", item.ref, "--\(agent.rawValue)"]) { ok in
            self.starting[item.ref] = nil
            then(ok)
        }
    }

    /// Brings an agent's session forward; false when there is nowhere to go.
    func open(_ claim: Claim) -> Bool {
        guard let url = claim.target else { return false }
        log("opening \(claim.agent) session \(claim.session.prefix(8)): \(url.absoluteString)")
        return NSWorkspace.shared.open(url)
    }

    /// Runs a write; the CLI's change notification triggers the refresh.
    private func perform(_ args: [String], then: @escaping (Bool) -> Void = { _ in }) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = CLI.run(args)
            DispatchQueue.main.async {
                if r.status == 0 {
                    let out = String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    log("todo \(args[0]) ok\(out.isEmpty ? "" : ": \(out)")")
                } else {
                    self.error = r.err.isEmpty ? "todo \(args[0]) failed" : r.err
                    log("todo \(args[0]) failed: \(r.err)")
                }
                then(r.status == 0)
            }
        }
    }

    /// Items that are on you, not waiting on someone else.
    var ownCount: Int { items.filter { $0.waiting.isEmpty }.count }

    func claims(for item: Item) -> [Claim] { claims[item.key] ?? [] }

    /// Agent sessions on items in the list, longest-running first.
    var working: [(item: Item, claim: Claim)] {
        items.flatMap { item in claims(for: item).map { (item: item, claim: $0) } }
            .sorted { $0.claim.since < $1.claim.since }
    }

    /// When an agent last did something on the item, if one claimed it.
    private func lastActive(_ item: Item) -> TimeInterval? { claims(for: item).map(\.lastActive).max() }

    struct Group {
        let key: String
        /// nil for the flat most-recent list, which needs no heading.
        let title: String?
        let color: Color?
        let items: [Item]
    }

    /// What agents are working on comes first, the most recently active on top.
    /// Then the rest, most recent activity first: one flat list or one section
    /// per repo (the repo with the latest activity on top); what you handed to
    /// someone else always comes last.
    func groups(byRepo: Bool) -> [Group] {
        let newestFirst: (Item, Item) -> Bool = { $0.updatedAt > $1.updatedAt }
        let working = items.filter { lastActive($0) != nil }
            .sorted { lastActive($0)! > lastActive($1)! }
        let rest = items.filter { lastActive($0) == nil }
        let own = rest.filter { $0.waiting.isEmpty }.sorted(by: newestFirst)
        let waiting = rest.filter { !$0.waiting.isEmpty }.sorted(by: newestFirst)
        var result: [Group] = []
        if !working.isEmpty {
            result.append(Group(key: "working", title: "IN PROGRESS", color: .green, items: working))
        }
        if byRepo {
            // Grouping keeps each repo's items in the newest-first order of `own`.
            result += Dictionary(grouping: own, by: \.repo).values
                .map { list in
                    Group(key: list[0].repo, title: list[0].personal ? "MINE" : list[0].repo.uppercased(),
                          color: Palette.color(for: list[0]), items: list)
                }
                .sorted { newestFirst($0.items[0], $1.items[0]) }
        } else if !own.isEmpty {
            // Under IN PROGRESS the flat list needs a heading of its own.
            result.append(Group(key: "recent", title: working.isEmpty ? nil : "TO DO", color: nil, items: own))
        }
        if !waiting.isEmpty {
            result.append(Group(key: "waiting", title: "WAITING ON OTHERS", color: nil, items: waiting))
        }
        return result
    }
}

// MARK: - Views

/// What the window shows. It trails the `collapsed` setting while the window
/// grows out of the pill or shrinks back into it.
final class PanelLayout: ObservableObject {
    static let pillHeight: CGFloat = 32
    @Published var showsPill = false
    @Published var showsList = false
    /// Which of the two is there or on its way: the pill when folded. The
    /// other one fades out but stays until the window is done moving, so it
    /// keeps to its corner; a view taken out mid-fade stays where it was.
    @Published var folded = true
    /// The list's size while the window grows or shrinks around it, so it is
    /// uncovered and covered instead of squeezed. Nil: it fills the window.
    @Published var listSize: CGSize?
    /// The corner the window grows from and shrinks into; both views keep to it.
    @Published var anchor = Alignment.topTrailing
}

struct PanelView: View {
    @ObservedObject var store: Store
    @ObservedObject var layout: PanelLayout
    /// Folded into the pill.
    @AppStorage("collapsed") private var collapsed = false
    /// Stays open when you click another app.
    @AppStorage("pinned") private var pinned = false
    /// Keys of folded sections, one per line; kept across restarts.
    @AppStorage("foldedGroups") private var foldedGroups = ""
    @AppStorage("byRepo") private var byRepo = false
    @State private var draft = ""
    let onCollapse: (Bool) -> Void
    /// The pill's width, which the window takes on while folded.
    let onPillWidth: (CGFloat) -> Void

    var body: some View {
        // Overlays, so a list bigger than the window spills past its edges
        // instead of growing the view.
        Color.clear
            .overlay(alignment: layout.anchor) {
                if layout.showsList {
                    VStack(spacing: 0) {
                        header
                        Divider().opacity(0.5)
                        list
                        Divider().opacity(0.5)
                        footer
                    }
                    .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .frame(width: layout.listSize?.width, height: layout.listSize?.height)
                    .opacity(layout.folded ? 0 : 1)
                    .allowsHitTesting(!layout.folded)
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
                }
            }
            .overlay(alignment: layout.anchor) {
                if layout.showsPill {
                    pill.opacity(layout.folded ? 1 : 0)
                        .transition(.asymmetric(insertion: .opacity, removal: .identity))
                }
            }
            .ignoresSafeArea()   // the title bar is hidden; don't reserve room for it
            .onChange(of: collapsed) { _, value in onCollapse(value) }
    }

    /// The count, a dot per agent session at work (faded while idle), and a
    /// warning when the list didn't load. The window handles clicks and drags.
    private var pill: some View {
        let working = store.working
        return HStack(spacing: 6) {
            Image(systemName: "checklist")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("\(store.ownCount)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
            if store.error != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
            if !working.isEmpty {
                HStack(spacing: 3) {
                    ForEach(working.prefix(5), id: \.claim.session) { work in
                        // No pulse here: motion at the edge of the screen pulls the eye,
                        // and it kept the always-on pill redrawing.
                        Image(systemName: "circle.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(work.claim.color.opacity(work.claim.active ? 1 : 0.4))
                    }
                    if working.count > 5 {
                        Text("+\(working.count - 5)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { onPillWidth($0) }
        // Its own height, not the window's, so it stays in its corner while
        // the window grows.
        .frame(height: PanelLayout.pillHeight)
        .contentShape(Rectangle())
        .help(([store.error == nil ? "\(store.ownCount) to do" : "Couldn't load the list"]
               + working.map { "\($0.claim.title) \($0.claim.active ? "busy" : "idle") on \($0.item.ref): \($0.item.title)" }
               + ["Click to open the list, drag to move it."]).joined(separator: "\n"))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("To do")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Text("\(store.ownCount)")
                .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.accentColor))
            Spacer()
            Button { byRepo.toggle() } label: {
                Image(systemName: byRepo ? "folder" : "clock")
            }
            .help(byRepo ? "Grouped by repo. Click for most recent first."
                         : "Most recent activity first. Click to group by repo.")
            Button { store.refresh("button") } label: {
                Image(systemName: "arrow.clockwise")
                    // A repeatForever rotation kept running after the refresh
                    // ended (about 10% CPU); the symbol effect stops with it.
                    .symbolEffect(.rotate, options: .repeating, isActive: store.loading)
            }
            .help("Refresh")
            Button { pinned.toggle() } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
            }
            .help(pinned ? "Pinned open. Click to fold it when you click another app."
                         : "Folds into a pill when you click another app. Click to keep it open.")
            Button { collapsed = true } label: {
                Image(systemName: "chevron.up")
            }
            .help("Fold into the pill")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 40)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if store.items.isEmpty && !store.loading {
                    Text(store.error == nil ? "Nothing open." : "Couldn't load the list.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
                ForEach(store.groups(byRepo: byRepo), id: \.key) { group in
                    let folded = group.title != nil && isFolded(group.key)
                    VStack(alignment: .leading, spacing: 2) {
                        if let title = group.title {
                            Button { toggleFold(group.key) } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: folded ? "chevron.right" : "chevron.down")
                                        .font(.system(size: 8, weight: .bold))
                                        .frame(width: 10)
                                        .foregroundStyle(.tertiary)
                                    Text(title)
                                        .foregroundStyle(group.color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tertiary))
                                    Text("\(group.items.count)").monospacedDigit()
                                        .foregroundStyle(.tertiary)
                                    Spacer(minLength: 0)
                                }
                                .font(.system(size: 10, weight: .semibold))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 6)
                            .padding(.bottom, 2)
                        }
                        if !folded {
                            ForEach(group.items) { item in
                                Row(item: item, showRepo: !byRepo || group.key == "waiting" || group.key == "working",
                                    claims: store.claims(for: item),
                                    closing: store.closing.contains(item.ref),
                                    starting: store.starting[item.ref],
                                    onDone: { store.done(item) },
                                    // The new session is where you go next.
                                    onStart: { store.start(item, in: $0) { ok in if ok && !pinned { collapsed = true } } },
                                    onOpen: { if store.open($0) && !pinned { collapsed = true } })
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
    }

    private func isFolded(_ key: String) -> Bool {
        foldedGroups.split(separator: "\n").contains { $0 == key }
    }

    private func toggleFold(_ key: String) {
        var keys = foldedGroups.split(separator: "\n").map(String.init)
        if let i = keys.firstIndex(of: key) { keys.remove(at: i) } else { keys.append(key) }
        foldedGroups = keys.joined(separator: "\n")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = store.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Image(systemName: "plus").foregroundStyle(.secondary)
                TextField("Add a to-do", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .onSubmit {
                        store.add(draft)
                        draft = ""
                    }
                    // Esc clears the draft, and folds the window once it's empty.
                    .onExitCommand { if draft.isEmpty { collapsed = true } else { draft = "" } }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct Row: View {
    let item: Item
    /// Outside a repo section the bare #N isn't enough.
    let showRepo: Bool
    /// Agent sessions working on it.
    let claims: [Claim]
    let closing: Bool
    /// The agent whose session is being opened for this item, if any.
    let starting: Agent?
    let onDone: () -> Void
    let onStart: (Agent) -> Void
    /// Opens a working agent's session.
    let onOpen: (Claim) -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    private var color: Color { Palette.color(for: item) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 12.5))
                    .strikethrough(closing)
                    .foregroundStyle(closing ? .secondary : .primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Flow(spacing: 5) {
                    ForEach(claims, id: \.session) { claim in WorkingBadge(claim: claim) { onOpen(claim) } }
                    if showRepo {
                        Text(item.personal ? "#\(item.number)" : "\(item.repo.split(separator: "/").last ?? "")#\(item.number)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(color.opacity(0.16)))
                            .foregroundStyle(color)
                    } else {
                        Text("#\(item.number)")
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(item.badges, id: \.self) { badge in
                        let style = Palette.label(badge.hex, dark: scheme == .dark)
                        Text(badge.text)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(style.bg))
                            .foregroundStyle(style.fg)
                    }
                    ForEach(item.waiting, id: \.self) { login in
                        Text("→ \(login)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    age
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(hovering ? 0.1 : 0)))
        .overlay(alignment: .bottomTrailing) {
            if hovering || starting != nil {
                HStack(spacing: 4) {
                    agentButton(.claude)
                    agentButton(.codex)
                }
                .padding(.trailing, 5)
                .padding(.bottom, 4)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { openOnGitHub() }
        .contextMenu {
            let open = claims.filter { $0.target != nil }
            ForEach(open, id: \.session) { claim in
                Button("Open the \(claim.title) session") { onOpen(claim) }
            }
            if !open.isEmpty { Divider() }
            Button("Do now in Claude Code") { onStart(.claude) }
            Button("Do now in Codex") { onStart(.codex) }
            Divider()
            Button("Open on GitHub") { openOnGitHub() }
            if item.personal { Button("Mark done", action: onDone) }
        }
        .help("\(item.ref) — click to open on GitHub")
    }

    private func openOnGitHub() {
        if let url = URL(string: item.url) { NSWorkspace.shared.open(url) }
    }

    /// Time since the last activity on the issue: green within a day, faded after a week.
    @ViewBuilder private var age: some View {
        if let updated = item.updated {
            let seconds = max(0, Date().timeIntervalSince(updated))
            Text(shortDuration(seconds))
                .font(.system(size: 10, weight: seconds < 86400 ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(seconds < 86400 ? AnyShapeStyle(Color.green)
                                 : seconds < 7 * 86400 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .help("Last activity \(updated.formatted(date: .abbreviated, time: .shortened))")
        }
    }

    private func agentButton(_ agent: Agent) -> some View {
        Button { onStart(agent) } label: {
            HStack(spacing: 3) {
                Image(systemName: "play.fill").font(.system(size: 7, weight: .bold))
                Text(starting == agent ? "Opening…" : agent.title)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(agent.color))
            .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(starting != nil)
        .help("Do now: a new \(agent.app) session in this repo's folder, with the issue as the prompt")
    }

    /// Personal items get a checkbox; team issues are closed by their reviewer,
    /// so they get a dot in the repo's colour (red for high priority) instead.
    @ViewBuilder private var marker: some View {
        if item.personal {
            Button(action: onDone) {
                Image(systemName: closing ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless)
            .disabled(closing)
            .help("Mark done")
        } else if !item.waiting.isEmpty {
            Circle()
                .strokeBorder(color.opacity(0.7), lineWidth: 1.2)
                .frame(width: 8, height: 8)
                .frame(width: 13)
        } else {
            Circle()
                .fill(item.isHighPriority ? Color.red : color)
                .frame(width: 8, height: 8)
                .frame(width: 13)
        }
    }
}

/// "● Claude 12m": an agent session on the item, how long it has been on it,
/// and whether it is busy right now (green) or idle (grey, how long since).
struct WorkingBadge: View {
    let claim: Claim
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        // The CLI reports activity at each poll; the clock in between ticks here.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date.timeIntervalSince1970
            let about = "\(claim.title) session \(claim.session.prefix(8)) has worked on this since "
                + "\(Date(timeIntervalSince1970: claim.since).formatted(date: .omitted, time: .shortened))"
                + (claim.active ? "" : "; last activity \(shortDuration(now - claim.lastActive)) ago")
            if let target = claim.target {
                Button(action: onOpen) { badge(now, hovered: hovering) }
                    .buttonStyle(.plain)
                    .onHover { hovering = $0 }
                    .help("\(about). Click to \(Self.verb(for: target)).")
            } else {
                badge(now, hovered: false).help(about)
            }
        }
    }

    private func badge(_ now: TimeInterval, hovered: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5.5))
                // Not pulsing: a repeating effect kept the open list redrawing
                // (about 5% CPU) for as long as any session was busy.
                .foregroundStyle(claim.active ? Color.green : Color.secondary)
            Text(claim.title)
            Text(claim.active ? shortDuration(now - claim.since) : "idle \(shortDuration(now - claim.lastActive))")
                .monospacedDigit()
                .opacity(0.75)
            if hovered {
                Image(systemName: "arrow.up.forward").font(.system(size: 7, weight: .bold))
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Capsule().fill(claim.color.opacity(hovered ? 0.3 : 0.16)))
        .foregroundStyle(claim.color)
        .contentShape(Capsule())
    }

    /// The end of "Click to …" for where the claim leads.
    static func verb(for target: URL) -> String {
        switch target.scheme {
        case "claude": "open it in the Claude app"
        case "codex": "open it in the Codex app"
        default: "switch to \(target.deletingPathExtension().lastPathComponent), where it runs"
        }
    }
}

/// Lays children out left to right at their natural size and wraps to a new
/// line when the row is full, so a long list of labels never squeezes a badge.
struct Flow: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = place(subviews, width: proposal.width ?? .infinity)
        let width = frames.map(\.maxX).max() ?? 0
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (frame, subview) in zip(place(subviews, width: bounds.width), subviews) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func place(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += lineHeight + 3
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}

// MARK: - Window and app

final class FloatingPanel: NSPanel {
    /// Set while the panel is the pill: a click on it calls this, a drag moves it.
    var onPillClick: (() -> Void)?

    // Needed so the "Add a to-do" field takes typing without activating the app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .leftMouseDown, let onPillClick else { return super.sendEvent(event) }
        let start = event.locationInWindow
        while let next = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { return onPillClick() }
            let p = next.locationInWindow
            if hypot(p.x - start.x, p.y - start.y) > 3 { return performDrag(with: event) }
        }
    }
}

/// The window on its way to a new frame, a step per screen refresh.
private struct Move {
    let from, to: NSRect
    let duration: CFTimeInterval
    /// Progress for elapsed time, both from 0 to 1.
    let curve: (Double) -> Double
    let done: () -> Void
    /// The first frame drawn, not the call: building the list holds up the
    /// main thread for a few frames, which would otherwise skip the start.
    var start: CFTimeInterval?

    static let easeOut: (Double) -> Double = { 1 - pow(1 - $0, 4) }
    static let easeInOut: (Double) -> Double = { $0 < 0.5 ? 4 * pow($0, 3) : 1 - pow(2 - 2 * $0, 3) / 2 }

    func frame(at progress: Double) -> NSRect {
        let p = CGFloat(progress)
        return NSRect(x: from.minX + (to.minX - from.minX) * p, y: from.minY + (to.minY - from.minY) * p,
                      width: from.width + (to.width - from.width) * p, height: from.height + (to.height - from.height) * p)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private let layout = PanelLayout()
    private var panel: FloatingPanel!
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var bag = Set<AnyCancellable>()
    private var notifyToken: Int32 = 0
    private var claimsToken: Int32 = 0
    private var snapshotSignal: DispatchSourceSignal?
    private let minExpandedHeight: CGFloat = 160
    /// Measured by the view; this is only until it has been.
    private var pillWidth: CGFloat = 64
    /// The corner the list grew from, which the pill goes back to.
    private var growCorner: (right: Bool, top: Bool)?
    /// Set while the window grows or shrinks. Not AppKit's window animation:
    /// that one ended at once when the pill appeared, and its clock ran on
    /// while the list was being built.
    private var move: Move?
    private lazy var moveLink: CADisplayLink = {
        let link = panel.displayLink(target: self, selector: #selector(moveStep))
        link.add(to: .main, forMode: .common)
        return link
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setvbuf(stdout, nil, _IOLBF, 0)
        makePanel()
        makeStatusItem()

        // Clicking or switching to another app folds the list into the pill.
        // Mouse events need no Accessibility access to monitor.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.fold("click elsewhere")
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let app, app.processIdentifier != getpid() { self?.fold("switched to \(app.localizedName ?? "another app")") }
        }

        store.refresh("launch")
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.store.refresh("timer")
        }
        // Search results for team repos lag writes by a few seconds, so look
        // again shortly after every change.
        notify_register_dispatch("com.rubenhaisma.todo.changed", &notifyToken, .main) { [weak self] _ in
            self?.store.refresh("change")
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self?.store.refresh("change+8s") }
        }
        // Claims change with `todo claim` / `release`, and lapse or turn idle
        // without anyone saying so, which only a poll notices.
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.store.refreshClaims()
        }
        notify_register_dispatch("com.rubenhaisma.todo.claims", &claimsToken, .main) { [weak self] _ in
            self?.store.refreshClaims()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.store.refresh("wake") }

        store.$items.sink { [weak self] items in
            self?.statusItem.button?.title = " \(items.filter { $0.waiting.isEmpty }.count)"
        }.store(in: &bag)

        // TODO_SNAPSHOT=/path.png writes a picture of the window after the first
        // load and on every SIGUSR1, for checking the layout without
        // screen-recording rights.
        if let path = ProcessInfo.processInfo.environment["TODO_SNAPSHOT"] {
            store.$loading.dropFirst().filter { !$0 }.first()
                .delay(for: .milliseconds(500), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.snapshot(to: path) }
                .store(in: &bag)
            signal(SIGUSR1, SIG_IGN)
            snapshotSignal = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
            snapshotSignal?.setEventHandler { [weak self] in self?.snapshot(to: path) }
            snapshotSignal?.resume()
        }

        log("started, panel window \(panel.windowNumber)")
    }

    private func snapshot(to path: String) {
        // The hosting view inside the blur: offscreen the blur draws a flat grey.
        guard let view = panel.contentView?.subviews.first,
              // Always at 2x, so the picture is sharp whatever screen it was taken on.
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        rep.size = view.bounds.size
        // The window colour stands in for the blur, painted first so the view
        // draws over it as it does on screen.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        log("snapshot written to \(path)")
    }

    private func makePanel() {
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 440),
            styleMask: [.titled, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(kind)?.isHidden = true
        }
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // The app is never the active one, and the pill's hover text says who
        // is working on what.
        panel.allowsToolTipsWhenApplicationIsInactive = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.minSize = NSSize(width: 240, height: PanelLayout.pillHeight)

        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        let host = NSHostingView(rootView: PanelView(
            store: store,
            layout: layout,
            onCollapse: { [weak self] in self?.setCollapsed($0) },
            onPillWidth: { [weak self] in self?.pillWidthChanged($0) }))
        // The window sets its own size. Otherwise the hosting view's minimum
        // height (still the expanded layout's while collapsing) holds the
        // panel open as an empty blurred box.
        host.sizingOptions = []
        // Frames, not constraints: with constraints the window's layout engine
        // re-applied a stale content height after setFrame (840 pt of content
        // in a 440 pt window), which cut the header off the top.
        host.autoresizingMask = [.width, .height]
        blur.addSubview(host)
        panel.contentView = blur
        host.frame = blur.bounds

        // Default spot: top-right corner; afterwards wherever you left it.
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 320 - 16, y: screen.maxY - 16))
        }
        panel.setFrameAutosaveName("TodoPanel")
        // The saved frame may predate a collapse; the height follows the state.
        setCollapsed(UserDefaults.standard.bool(forKey: "collapsed"), animated: false)
        panel.orderFrontRegardless()
    }

    /// Folded, the panel is the pill, which doesn't resize. The list grows
    /// from the pill's corner nearest the screen's edges, so it opens towards
    /// the middle of the screen, and folds back into that corner.
    private func setCollapsed(_ collapsed: Bool, animated: Bool = true) {
        let defaults = UserDefaults.standard
        // Mid-animation, start from where the window was going, so a quick
        // second click neither saves a passing size nor picks another corner.
        let old = move?.to ?? panel.frame
        let corner: (right: Bool, top: Bool)
        var size: NSSize
        if collapsed {
            if old.height >= minExpandedHeight {
                defaults.set(Double(old.width), forKey: "expandedWidth")
                defaults.set(Double(old.height), forKey: "expandedHeight")
            }
            corner = growCorner ?? nearestCorner(of: old)
            growCorner = nil
            size = NSSize(width: pillWidth, height: PanelLayout.pillHeight)
            panel.onPillClick = { defaults.set(false, forKey: "collapsed") }
        } else {
            corner = nearestCorner(of: old)
            growCorner = corner
            size = old.size
            if old.height < minExpandedHeight {
                size = NSSize(width: max(defaults.double(forKey: "expandedWidth"), 320),
                              height: max(defaults.double(forKey: "expandedHeight"), 240))
            }
            panel.onPillClick = nil
            store.refreshClaims()
        }
        var frame = NSRect(x: corner.right ? old.maxX - size.width : old.minX,
                           y: corner.top ? old.maxY - size.height : old.minY,
                           width: size.width, height: size.height)
        if let screen = (panel.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
        }

        // The window grows out of the pill's corner and shrinks back into it.
        // The pill and the list share no content, so each keeps its own size
        // and fades: the list is uncovered and covered, never squeezed.
        // Reduce Motion skips the resize and keeps only the fade.
        let moves = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        layout.anchor = Alignment(horizontal: corner.right ? .trailing : .leading,
                                  vertical: corner.top ? .top : .bottom)
        layout.listSize = moves ? (collapsed ? old.size : frame.size) : nil
        // What leaves fades first, so the two barely overlap.
        let fade: (out: Animation?, in: Animation?) =
            !animated ? (nil, nil)
            : !moves ? (nil, .easeOut(duration: 0.15))
            : collapsed ? (.easeIn(duration: 0.1), .easeOut(duration: 0.1).delay(0.1))
            : (.easeOut(duration: 0.08), .easeOut(duration: 0.17).delay(0.05))
        withAnimation(fade.out) { layout.folded = collapsed }
        withAnimation(fade.in) {
            if collapsed { layout.showsPill = true } else { layout.showsList = true }
        }
        let gone = { [layout] in if collapsed { layout.showsList = false } else { layout.showsPill = false } }

        // The pill doesn't resize; the list does, down to a few rows. Set once
        // the window is there: an animated frame keeps to these limits too.
        let limits = collapsed
            ? (min: size, max: size)
            : (min: NSSize(width: 240, height: minExpandedHeight),
               max: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        guard moves else {
            move = nil
            gone()
            (panel.minSize, panel.maxSize) = limits
            return panel.setFrame(frame, display: true)
        }
        panel.minSize = NSSize(width: min(old.width, size.width), height: min(old.height, size.height))
        panel.maxSize = NSSize(width: max(old.width, size.width), height: max(old.height, size.height))
        move = Move(from: panel.frame, to: frame, duration: collapsed ? 0.2 : 0.24,
                    curve: collapsed ? Move.easeInOut : Move.easeOut) { [weak self] in
            guard let self else { return }
            gone()
            (self.panel.minSize, self.panel.maxSize) = limits
            if collapsed {
                // The count may have changed while the list was open.
                self.pillWidthChanged(self.pillWidth)
            } else {
                self.layout.listSize = nil   // from here on it follows the window
            }
        }
        moveLink.isPaused = false
    }

    @objc private func moveStep(_ link: CADisplayLink) {
        guard var step = move else { return link.isPaused = true }
        let start = step.start ?? link.timestamp
        step.start = start
        let elapsed = min((link.targetTimestamp - start) / step.duration, 1)
        guard elapsed < 1 else {
            move = nil
            link.isPaused = true
            panel.setFrame(step.to, display: true)
            return step.done()
        }
        move = step
        panel.setFrame(step.frame(at: step.curve(elapsed)), display: true)
    }

    private func nearestCorner(of frame: NSRect) -> (right: Bool, top: Bool) {
        guard let screen = (panel.screen ?? NSScreen.main)?.visibleFrame else { return (true, true) }
        return (frame.midX > screen.midX, frame.midY > screen.midY)
    }

    /// The count grew a digit or an agent started: resize the pill in place.
    private func pillWidthChanged(_ width: CGFloat) {
        pillWidth = ceil(width)
        guard move == nil, UserDefaults.standard.bool(forKey: "collapsed"), panel.frame.width != pillWidth else { return }
        setCollapsed(true, animated: false)
    }

    private func fold(_ reason: String) {
        let defaults = UserDefaults.standard
        guard panel.isVisible, !defaults.bool(forKey: "collapsed"), !defaults.bool(forKey: "pinned") else { return }
        log("folding: \(reason)")
        defaults.set(true, forKey: "collapsed")
    }

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "To do")
        statusItem.button?.imagePosition = .imageLeading

        let menu = NSMenu()
        toggleItem = menu.addItem(withTitle: "Hide window", action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(withTitle: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        menu.addItem(withTitle: "Open list on GitHub", action: #selector(openGitHub), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Todo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
            toggleItem.title = "Show window"
        } else {
            panel.orderFrontRegardless()
            toggleItem.title = "Hide window"
            store.refresh("shown")
        }
    }

    @objc private func refreshNow() { store.refresh("menu") }

    @objc private func openGitHub() {
        DispatchQueue.global().async { _ = CLI.run(["open"]) }
    }
}

@main
enum TodoApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
