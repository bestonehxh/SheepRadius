import Foundation

/// **The pane column, as arithmetic** (build 22; build 24 made it fluid).
///
/// Build 21 centred a pane's column by putting the side padding *inside* the width bound:
/// `padding(.horizontal, 20)` and then `frame(maxWidth: 900)`. That is the wrong way round.
/// The bound then covers the padding as well, so the column cannot get narrower than its
/// content's own minimum — and as soon as a window was narrower than 900 plus two gutters the
/// column stopped shrinking, overflowed the pane and was centred *as an overflow*, which reads
/// on screen as a wide gutter on one side and almost none on the other. Build 22's fix was to
/// put the padding **outside** the bound, and that part stands: the strip and the body wear the
/// same modifier, so the pane title always sits above its own groups.
///
/// **Build 24 removes the bound itself** (the owner picked layout A). A fixed 900 pt column on
/// a 2360 pt window left 700 pt of empty pane on either side of a table that had columns to
/// spare, and the wider the display the more the app looked like a phone app someone had
/// stretched a background behind. The rule is now one line — **the column is everything except
/// the gutters, and the gutter grows with the pane**:
///
///     gutter = clamp(3 % of the pane, 20 … 96)
///
/// 3 % keeps the proportion recognisable across the range this app is used at. Measured on the
/// pane, which is the window less the 212 pt sidebar: 23 pt at the 980 pt minimum window,
/// 36 pt at 1400, 64 pt at 2360, and the 96 pt ceiling from a 3200 pt pane on. The two clamps
/// are limits rather than percentages because below ~667 pt of pane a proportional gutter is
/// too thin to read as a margin at all, and above 3200 it stops being a margin and becomes a
/// second empty pane. Nothing here is a maximum *column* width: a table, a tile row and a
/// key–value row all take what the window gives them.
///
/// What did **not** change: the gutters are equal at every width, which is the property every
/// screenshot is measured for, and `Metrics.key` still fixes the key column of a `KeyValueRow`
/// so two groups' values line up however wide the pane is.
///
/// Pure and here rather than in `Theme.swift` so `Tests/run.sh unit` can compile it: these are
/// the numbers the sweep pins.
nonisolated enum PaneColumn {
    /// The fraction of the pane each gutter takes, between the two clamps.
    static let gutterFraction: CGFloat = 0.03
    /// The narrow end — build 22's fixed gutter, reached at a 667 pt pane and below.
    static let minGutter: CGFloat = 20
    /// The wide end. Past ~3200 pt a proportional gutter stops being a margin.
    static let maxGutter: CGFloat = 96

    /// The band the window's title bar occupies. The sidebar owns the traffic lights in it and
    /// has always reserved it; build 22 reserves the same height in the main column, so a pane
    /// title starts level with the sidebar's first heading instead of inside the title bar.
    static let titleBar: CGFloat = 44

    /// The same band in full screen, where there are no traffic lights to leave room for.
    static let titleBarFullScreen: CGFloat = 12

    /// **How wide a paragraph is allowed to get.** A note row and a `.hint()` are prose, and
    /// prose set across 2200 pt is unreadable however good the margins are — the eye loses the
    /// line on the way back. ~80 characters at 11.5 pt is 560 pt. Controls, tables and tiles
    /// are *not* prose and are not bounded by this.
    static let prose: CGFloat = 560

    /// The gutter on each side of a pane `available` points wide.
    static func gutter(available: CGFloat) -> CGFloat {
        guard available > 0 else { return minGutter }
        return min(maxGutter, max(minGutter, available * gutterFraction))
    }

    /// The width of the column in a pane `available` points wide: everything except the two
    /// gutters, never negative — a pane narrower than two gutters has no column left, and
    /// clamping at zero keeps that a layout rather than a crash.
    static func width(available: CGFloat) -> CGFloat {
        max(0, available - 2 * gutter(available: available))
    }

    /// The gutter that actually results, which is what a screenshot is measured for. It is the
    /// same on the left and on the right, which is the whole point — and below `2 · minGutter`
    /// of pane it is whatever is left, halved, rather than a negative column.
    static func sideGutter(available: CGFloat) -> CGFloat {
        max(0, (available - width(available: available)) / 2)
    }
}

/// **What a copy control does, as data** (build 24, the owner: "เวลากดปุ่ม Copy ไม่มี effect อะไร").
///
/// Every value in this app exists to be pasted into a device's form, and there are twelve
/// places that write to the pasteboard. Until this build not one of them changed by a pixel
/// when it was pressed, so the only way to know whether the click had landed was to paste
/// somewhere and look — and on a form with nine fields in it that is nine gambles.
///
/// The confirmation is **native and in place**: the icon becomes a `checkmark`, a control with
/// room for a word says "Copied", both in the accent colour, and after `hold` it goes back.
/// No toast, no sheet, nothing that moves the layout — a row that changes height when it is
/// clicked pushes everything under it down, which is worse than no feedback at all.
///
/// Pure, so the two answers can be pinned without a view, and so there is exactly one place
/// that decides what "copied" looks like.
nonisolated enum CopyFeedback {
    /// How long the confirmed state is held. Long enough to be read, short enough that a row
    /// of nine fields does not end up a row of nine checkmarks.
    static let hold: Double = 1.2
    static let word = "Copied"
    static let idleSymbol = "doc.on.doc"
    static let copiedSymbol = "checkmark"

    static func symbol(copied: Bool) -> String { copied ? copiedSymbol : idleSymbol }
    /// The title of a control that has room for one. `nil` in, `nil` out — an icon-only
    /// control stays icon-only, because "Copied" in a 16 pt cell is a truncated word.
    static func title(_ idle: String?, copied: Bool) -> String? {
        guard let idle else { return nil }
        return copied ? word : idle
    }

    /// **`-demoCopied 1`** — hold every copy control in its confirmed state, for the one
    /// screenshot that cannot be taken any other way: `-demoShot` draws the window and quits,
    /// and there is nothing in between to press a button in. It writes nothing to the
    /// pasteboard; it is a rendering flag and nothing else.
    static let demoHeld = CommandLine.arguments.contains("-demoCopied")
        && CommandLine.arguments.contains("1")
}

// MARK: - The table panes, as arithmetic (build 26, QA L-1 / L-2 / L-4 / L-6 / L-8)

/// **Why a `Table`'s columns are computed here and not left to SwiftUI** (build 26).
///
/// `Table` drops the columns that do not fit, *silently* — no warning, no truncation, the
/// column simply is not drawn. Build 18 lost `Enabled` at 1180 pt, build 24 lost it again at
/// 980 (QA **L-1**), and both times the app and all three suites went on passing, because what
/// decides is the sum of the `.width(min:)` values plus the inset style's own chrome, and
/// nothing anywhere added that sum up.
///
/// So the sum is a function now, `budget(_:)`, and `Tests/run.sh unit` walks every window
/// width from 980 to 4000 asserting that the table the layout hands each pane is at least its
/// budget. A column added without taking the width from somewhere fails the suite rather than
/// disappearing off a screenshot nobody took.
///
/// The three columns beside the table are the other half of the same sum, and build 24 froze
/// all of them: a 150 pt OU tree against a 1738 pt table at 2360 (**L-2**), a 260 pt inspector
/// holding the sentence *"Select a user to edit it."* at 980 while the table next to it lost a
/// column (**L-4**). Here the tree scales, the inspector is 300 and becomes a toggle on a
/// narrow window, and the table is what is left.
///
/// Pure and in this file so the unit suite compiles it — these are the numbers the sweep pins.
nonisolated enum PaneTable {
    /// The sidebar, which is fixed and is not part of any pane.
    static let sidebar: CGFloat = 212
    /// The narrowest window `ContentView` allows. Every budget below is checked at this width.
    static let minimumWindow: CGFloat = 980

    // MARK: The OU tree (L-2)

    /// The tree's three widths — the `minWidth / idealWidth / maxWidth` the owner asked for.
    static let treeMin: CGFloat = 200
    static let treeIdeal: CGFloat = 240
    static let treeMax: CGFloat = 320
    /// How much of a wide column the tree is allowed to become before `treeMax` stops it.
    /// 240 wins below a ~1850 pt column, which is every window this app is normally used at.
    static let treeFraction: CGFloat = 0.13
    /// One level of nesting. 12 pt is unreadable at 150 pt and right at 240.
    static let treeIndent: CGFloat = 12
    /// **The count is a column, not a trailing `Text`** (L-2c). Without a frame its *right*
    /// edge aligns and its left edge moves with the number of digits, so every OU that reaches
    /// ten users steals width from its own name and the rows go ragged. 28 pt is four
    /// monospaced digits at 10 pt.
    static let treeCountColumn: CGFloat = 28

    /// **One pitch for the tree and the table, and one header height** (L-2d / L-9).
    ///
    /// Measured on build 25: table rows at 203, 227, 251, 275 …; tree rows at 225, 249, 273 …
    /// Same 24 pt pitch, permanently 22 pt out of phase, so no tree row ever lined up with a
    /// row of the table it was filtering. The phase error was the root label's
    /// `.padding(.top, 10)` + `.padding(.bottom, 4)` against the table header's own height.
    ///
    /// **26, because that is what SwiftUI's `.inset` table style actually draws**, measured off
    /// `Screenshots/Build26/users-980x760-light.png` rather than assumed: heading strip
    /// 309 → 336, then row separators at 367, 393, 419, 445. A `Table`'s row height cannot be
    /// set, so the only way for the tree to be in phase with it is to be told what it is.
    static let rowPitch: CGFloat = 26

    /// **The heading strip, for the one thing that has to match it** — the OU tree's own
    /// header. SwiftUI will not say what a `Table` drew, so this is measured off the same
    /// capture (309 → 336) and then *given* to the tree. `Metrics.tableHeader` is this
    /// constant; there is deliberately only one.
    static let tableHeader: CGFloat = 28

    /// **The inset style's own space above its first row**, from the same capture: the first
    /// band is 336 → 367 where every later one is 26 pt. The tree's row list wears it as top
    /// padding, which puts tree row *n* exactly on table row *n* from the second row on and
    /// leaves the first 2.5 pt high — against build 25's 22 pt, at every row, at every width.
    static let tableBodyInset: CGFloat = 5

    /// The tree's width inside a column `column` points wide. Clamped so the table beside it
    /// can never fall under `need`, which is the whole of L-1: the tree yields, not the table.
    static func tree(column: CGFloat, inspectorShown: Bool, need: CGFloat) -> CGFloat {
        let wanted = min(treeMax, max(treeIdeal, column * treeFraction))
        let spare = column - (inspectorShown ? inspector : 0) - need
        return max(treeMin, min(wanted, spare))
    }

    // MARK: The inspector (L-4)

    /// 300, not build 24's 260. At 980 the old one was 27 % of the window and was what pushed
    /// the table under its own minimum; at 2360 it was 11 % and the 220 pt fields inside it
    /// were swimming.
    static let inspector: CGFloat = 300

    /// **Below this pane width the inspector is a toolbar toggle, not a column.**
    ///
    /// The pane is the window less the 212 pt sidebar, so 1100 pt of pane is a 1312 pt window.
    /// Under that the table needs every point it can get and the inspector's *placeholder* —
    /// 300 pt saying "Select a user to edit it." — was the single worst use of width in the
    /// app. It is not removed, it is behind a button.
    static let inspectorCollapseBelow: CGFloat = 1100

    /// Whether the inspector is a column at this **pane** width (window − sidebar).
    static func inspectorIsColumn(pane: CGFloat) -> Bool { pane >= inspectorCollapseBelow }

    // MARK: The budget a `Table` has to clear

    /// What the `.inset` style costs outside the columns themselves: its own leading and
    /// trailing padding. Deliberately generous — the failure mode this guards is silent.
    static let chromeEdges: CGFloat = 24
    /// …and between two columns.
    static let chromePerGap: CGFloat = 10

    /// The narrowest a table with these column minimums can be drawn at without losing one.
    static func budget(_ minimums: [CGFloat]) -> CGFloat {
        guard !minimums.isEmpty else { return 0 }
        return minimums.reduce(0, +) + chromeEdges + chromePerGap * CGFloat(minimums.count - 1)
    }

    /// **The width the columns share**: the table less the same chrome `budget(_:)` allows for.
    ///
    /// Three settings were tried against real captures in this build, which is the only way to
    /// find out what SwiftUI does — `TableColumn.width(_:)` is an *ideal*, not a promise, and
    /// what it does with the slack is not the same on two tables of the same shape:
    ///
    /// - **the full allowance (this one)**: Groups fills its table exactly at every width, and
    ///   Users at 2360 leaves ~70 pt of trailing space after the last column;
    /// - **no allowance**: Users at 2360 fills exactly — and Groups at 980 overflows and clips
    ///   `Members` to **"Mer"**, which is L-6 coming straight back;
    /// - **a small 8 + 4·(n−1) inset**: still clips Groups at 980.
    ///
    /// So the conservative one wins. A strip of empty table after the last column is a
    /// cosmetic cost at one width; a column cut in half at the documented minimum is the
    /// finding this build exists to close.
    static func body(table: CGFloat, columns: Int) -> CGFloat {
        guard columns > 0 else { return 0 }
        return max(0, table - chromeEdges - chromePerGap * CGFloat(columns - 1))
    }

    // MARK: Users (L-1)

    /// `Enabled` and `Members` are **fixed and never dropped** — a two-character value has no
    /// business being the column that flexes, and it was the one build 18 and build 24 both
    /// lost. 72 pt holds "Read-only" at 11 pt.
    static let fixedStatus: CGFloat = 72
    /// The inline Enable / Disable link (the owner-approved mock). A fifth column, so it is in
    /// the budget; `usersShowsAction` turns it off on a window that cannot afford it rather
    /// than letting `Table` decide in silence.
    static let usersAction: CGFloat = 78

    static let usersMinimums: [CGFloat] = [120, 90, 90, fixedStatus]
    static var usersMinimumsWithAction: [CGFloat] { usersMinimums + [usersAction] }
    static var usersNeed: CGFloat { budget(usersMinimums) }

    /// Whether the fifth column is drawn: the window has to afford it **and** the backend has
    /// to have an "account disabled" flag to toggle. OpenLDAP has none — the inspector says so
    /// in as many words — so on a slapd lab the column would be a 78 pt strip of nothing, which
    /// is what the 1400 pt capture of the first cut showed while `Member of` truncated beside
    /// it. The answer is a function, so the pane and the suite agree about it.
    static func usersShowsAction(table: CGFloat, canDisable: Bool) -> Bool {
        canDisable && table >= budget(usersMinimumsWithAction)
    }

    /// The four (or five) widths, as points. `Name` 34 % and `Username` 20 % of the body,
    /// `Member of` takes the slack, `Enabled` and the action are fixed — the proportions the
    /// QA sweep proposed, turned into numbers so they can be asserted.
    nonisolated struct UsersColumns: Sendable, Equatable {
        var name: CGFloat
        var username: CGFloat
        var memberOf: CGFloat
        var status: CGFloat
        /// nil when the window cannot afford the inline Enable / Disable column.
        var action: CGFloat?

        var widths: [CGFloat] { [name, username, memberOf, status] + (action.map { [$0] } ?? []) }
        var total: CGFloat { widths.reduce(0, +) }
    }

    static func usersColumns(table: CGFloat, canDisable: Bool = true) -> UsersColumns {
        let action = usersShowsAction(table: table, canDisable: canDisable)

        let body = body(table: table, columns: action ? 5 : 4)
        let fixed = fixedStatus + (action ? usersAction : 0)
        let name = max(usersMinimums[0], body * 0.34)
        let username = max(usersMinimums[1], body * 0.20)
        let memberOf = max(usersMinimums[2], body - fixed - name - username)
        return UsersColumns(name: name, username: username, memberOf: memberOf,
                            status: fixedStatus, action: action ? usersAction : nil)
    }

    // MARK: Computers (build 27)

    /// Name · Account · Joined · Last seen · Status plus the remove control at the documented
    /// 980 pt minimum. These minimums fit the Users table's measured 482 pt width including
    /// inset chrome, so SwiftUI never gets to discard a column silently.
    static let computersMinimums: [CGFloat] = [65, 80, 90, 75, 62, 34]
    static var computersNeed: CGFloat { budget(computersMinimums) }

    // MARK: Groups (L-6)

    /// `Members` clipped to **"Me"** at 980 in build 25 while `Description` had visible slack:
    /// the table was wide enough and the proportions were simply wrong. Name 34 %, Description
    /// takes the slack, Members fixed and right-aligned with monospaced digits.
    static let groupsMinimums: [CGFloat] = [140, 110, fixedStatus]
    static var groupsNeed: CGFloat { budget(groupsMinimums) }

    nonisolated struct GroupsColumns: Sendable, Equatable {
        var name: CGFloat
        var description: CGFloat
        var members: CGFloat
        var total: CGFloat { name + description + members }
    }

    static func groupsColumns(table: CGFloat) -> GroupsColumns {
        let body = body(table: table, columns: 3)
        let name = max(groupsMinimums[0], body * 0.34)
        let description = max(groupsMinimums[1], body - fixedStatus - name)
        return GroupsColumns(name: name, description: description, members: fixedStatus)
    }

    // MARK: Clients

    static let clientsMinimums: [CGFloat] = [120, 120, 120]
    static var clientsNeed: CGFloat { budget(clientsMinimums) }

    nonisolated struct ClientsColumns: Sendable, Equatable {
        var name: CGFloat
        var address: CGFloat
        var secret: CGFloat
        var total: CGFloat { name + address + secret }
    }

    static func clientsColumns(table: CGFloat) -> ClientsColumns {
        let body = body(table: table, columns: 3)
        let name = max(clientsMinimums[0], body * 0.30)
        let address = max(clientsMinimums[1], body * 0.26)
        let secret = max(clientsMinimums[2], body - name - address)
        return ClientsColumns(name: name, address: address, secret: secret)
    }

    // MARK: The whole frame, in one call

    /// Everything a table pane needs to lay itself out, from the one width it measures.
    ///
    /// `pane` is the main column — the window less the 212 pt sidebar. **L-8**: the gutters are
    /// `PaneColumn`'s, the same ones every grouped pane has had since build 22, so the app has
    /// one width rule rather than "a narrow ribbon floating in the middle or a table sprawling
    /// across everything, depending on which row of the sidebar is selected".
    nonisolated struct Frame: Sendable, Equatable {
        var gutter: CGFloat
        var column: CGFloat
        var tree: CGFloat
        var inspector: CGFloat?
        var table: CGFloat

        var inspectorIsColumn: Bool { inspector != nil }
    }

    /// `need` is the table's own budget — `usersNeed`, `groupsNeed`, `clientsNeed`.
    /// `hasTree` is true only on Users.
    static func frame(pane: CGFloat, hasTree: Bool, need: CGFloat) -> Frame {
        let gutter = PaneColumn.gutter(available: pane)
        let column = PaneColumn.width(available: pane)
        let shown = inspectorIsColumn(pane: pane)
        let treeWidth = hasTree ? tree(column: column, inspectorShown: shown, need: need) : 0
        let inspectorWidth = shown ? inspector : nil
        let table = max(0, column - treeWidth - (inspectorWidth ?? 0))
        return Frame(gutter: gutter, column: column, tree: treeWidth,
                     inspector: inspectorWidth, table: table)
    }
}

// MARK: - The editorial heading block (build 26, the owner-approved mock)

/// **Every pane says what it is and what state it is in, in words** (build 26).
///
/// The mock the owner approved replaces a 15 pt pane title with three lines: an eyebrow, a
/// large heading that *states the state* — "lab.sheep is up.", "Everything is stopped." — and
/// one subtitle. The point is the heading: a person opening Status wanted to know whether the
/// lab was answering, and the old pane made them read a tile to find out.
///
/// The words are here rather than in the views so the unit suite pins them, and so the four
/// server states cannot each grow their own sentence in a different file.
nonisolated enum PaneHeadline {
    nonisolated struct Block: Sendable, Equatable {
        var eyebrow: String
        var heading: String
        var subtitle: String
    }

    /// **Status.** The lab is named, because a person with two of these open needs to know
    /// which one they are looking at.
    static func status(labDomain: String, radiusRunning: Bool, directoryRunning: Bool) -> String {
        let name = labDomain.trimmingCharacters(in: .whitespaces)
        let lab = name.isEmpty ? "The lab" : name
        switch (radiusRunning, directoryRunning) {
        case (true, true): return "\(lab) is up."
        case (false, false): return "Everything is stopped."
        case (true, false): return "RADIUS is up; the directory is not."
        case (false, true): return "The directory is up; RADIUS is not."
        }
    }

    /// The one line under the Status heading.
    static func statusSubtitle(directoryLabel: String, address: String,
                               accepted: Int, rejected: Int) -> String {
        let where_ = "RADIUS and \(directoryLabel) on \(address)"
        let total = accepted + rejected
        guard total > 0 else { return "\(where_) · no authentications today" }
        return "\(where_) · \(total) authentication\(total == 1 ? "" : "s") today, \(accepted) accepted"
    }

    /// The fixed blocks. Status' heading and subtitle are computed, so it is not in here.
    static func block(for pane: String) -> Block {
        switch pane {
        case "test":
            Block(eyebrow: "Check",
                  heading: "One check at a time.",
                  subtitle: "Pick what to prove, fill in the account, and read the server's own answer")
        case "log":
            Block(eyebrow: "Output",
                  heading: "Everything the servers say.",
                  subtitle: "radiusd, the directory and the domain controller, as they write it")
        case "users":
            Block(eyebrow: "Identity source",
                  heading: "One directory.",
                  subtitle: "Every account here logs in to the domain, 802.1X, VPN and RADIUS tests · edits apply at once")
        case "groups":
            Block(eyebrow: "Identity source",
                  heading: "One directory.",
                  subtitle: "A group names who is in it; what they are given is a rule under Policy")
        case "ldapServer":
            Block(eyebrow: "Directory",
                  heading: "Where the accounts live.",
                  subtitle: "The backend, its listeners, the base DN and the administrator")
        case "devices":
            Block(eyebrow: "Devices",
                  heading: "What to type into each product.",
                  subtitle: "One table per device, every value copyable")
        case "clients":
            Block(eyebrow: "RADIUS clients",
                  heading: "Who may ask.",
                  subtitle: "Switches, APs, controllers and firewalls allowed to reach this server")
        case "policy":
            Block(eyebrow: "Policy",
                  heading: "First match wins.",
                  subtitle: "One ordered list · the order is the priority")
        case "radiusServer":
            Block(eyebrow: "RADIUS",
                  heading: "The server itself.",
                  subtitle: "Ports, EAP, TLS and how much the log says")
        case "certificates":
            Block(eyebrow: "TLS",
                  heading: "One authority, two leaves.",
                  subtitle: "The lab CA, the RADIUS certificate, the directory certificate and the client certificates")
        case "settings":
            Block(eyebrow: "App",
                  heading: "The lab and this build.",
                  subtitle: "Where the files are, what is bundled, and how to move the lab")
        default:
            Block(eyebrow: "Lab", heading: "SheepRadius.", subtitle: "")
        }
    }
}

// MARK: - Groups: the lab's own, and the forty the directory brought (build 26, decision C)

/// **A Samba AD directory has about forty built-in groups, and none of them is the lab's**
/// (build 26, the owner: show only the lab's own by default).
///
/// Build 25 listed all of them, each with a "Directory's own" pill beside its name, so four
/// groups somebody made were four rows in a list of forty-four and the pill was on almost every
/// row — which makes it decoration rather than information. The pill goes; the built-ins move
/// under one trailing disclosure row that counts them. **Nothing is hidden**: the user-facing
/// built-in status is inside the disclosure, and `Domain Admins` is still where a device will
/// find it.
///
/// Pure, so "the split is by `isReadOnly` and by nothing else" is a test rather than a read of
/// the view.
nonisolated enum GroupsSplit {
    /// The trailing row's title.
    static func disclosureTitle(builtIn: Int) -> String {
        "Built-in groups (\(builtIn))"
    }

    /// The note beside the section title: what the list is showing.
    static func sectionNote(own: Int, builtIn: Int, backendLabel: String) -> String {
        let groups = "\(own) group\(own == 1 ? "" : "s")"
        guard builtIn > 0 else { return "\(groups) · from \(backendLabel)" }
        return "\(groups) · \(builtIn) built-in · from \(backendLabel)"
    }

    /// Whether the disclosure is offered at all. One or two built-ins — which is what OpenLDAP
    /// has — is not a list worth folding.
    static let disclosureFrom = 3
    static func showsDisclosure(builtIn: Int) -> Bool { builtIn >= disclosureFrom }
}
