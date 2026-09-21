import AppKit
import SwiftUI

/// Active Directory Users and Computers, in miniature — and from build 17, **live**.
///
/// The rows are `AppModel.directory`, a snapshot of whichever backend is running, and every
/// edit calls that backend straight away: create, rename, move, delete, set password, tick a
/// group. There is no Apply here and no Sync now (PROJECT-STATUS §13). What each edit gets
/// instead is an inline "saved · 0.3 s", the backend's own refusal when it says no, and one
/// step of Undo for the two edits that lose something — a move and a delete.
///
/// With LDAP off the pane is an empty state — "LDAP is off." and a Start button — and nothing
/// else (build 21, PROJECT-STATUS §18). Until build 20 it quietly showed a second user table
/// from `lab.json` instead, which is the confusion the owner asked to have removed.
struct UsersView: View {
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var ad = AppModel.shared.ad
    @State private var selectedOU: String?
    @State private var search = ""
    @State private var editor: OUEditor?
    @State private var dropTarget: String?
    @State private var newUser: NewUserRequest?
    @State private var pendingDelete: OUDeletion?
    @State private var showingComputers = false
    @State private var pendingComputerDelete: DirectoryComputer?

    private var paths: [String] { model.directory.ous.map(\.path) }

    /// **The OU a New user / New OU would land in, or nil** (build 25, QA H-5 —
    /// `OUCreationTarget` has the reasoning). A read-only container can be browsed and is
    /// never a target, so the two New buttons are disabled while one is selected and the tree
    /// says why rather than handing a sheet a path its own picker refuses to show.
    private var creationTarget: String? {
        guard !showingComputers else { return nil }
        return OUCreationTarget.target(selected: selectedOU, isReadOnly: selectedIsReadOnly)
    }

    private var selectedIsReadOnly: Bool {
        guard let selectedOU else { return false }
        return model.directory.ous.first { OUPath.isSame($0.path, selectedOU) }?.isReadOnly ?? false
    }

    /// nil means the "All users" row.
    private var listed: [DirectoryUser] {
        let base = selectedOU.map { path in
            model.directory.users.filter { OUPath.isSame($0.ou, path) }
        } ?? model.directory.users
        guard !search.isEmpty else { return base }
        return base.filter {
            $0.username.localizedCaseInsensitiveContains(search)
                || $0.displayName.localizedCaseInsensitiveContains(search)
        }
    }

    private var selected: DirectoryUser? {
        guard !showingComputers else { return nil }
        return model.directory.users.first { $0.username == model.selectedUser }
    }

    /// **The one width this pane measures** (build 26). Everything else — the tree, the
    /// inspector, the table and its four column widths — is `PaneTable.frame` of it, so the
    /// pane and `Tests/run.sh unit` are looking at the same arithmetic.
    @State private var paneWidth: CGFloat = PaneTable.minimumWindow - PaneTable.sidebar
    /// **The inspector on a window too narrow to give it a column** (QA L-4). Below
    /// `PaneTable.inspectorCollapseBelow` of pane it is off, a toolbar button brings it back,
    /// and it is drawn *over* the table's right edge rather than taking 300 pt of the width the
    /// four columns need — which is the trade build 25 got backwards.
    @State private var showInspector = false

    private var frame: PaneTable.Frame {
        PaneTable.frame(pane: paneWidth, hasTree: true,
                        need: showingComputers ? PaneTable.computersNeed : PaneTable.usersNeed)
    }

    private var headline: PaneHeadline.Block { PaneHeadline.block(for: "users") }

    var body: some View {
        VStack(spacing: 0) {
            header

            DirectoryBanner()

            if !model.directoryIsLive {
                DirectoryOffline()
            } else {
                // Tree · table · inspector, all three from `PaneTable.frame` (QA L-1, L-2,
                // L-4, L-8). Build 25 froze the tree at 150 pt and the inspector at 260 at
                // every width, and the table — the only thing that grew — silently dropped its
                // fourth column at the documented 980 pt minimum. Now the **tree** yields: it
                // is 240 pt, it grows towards 320 on a wide window, and it is clamped so the
                // table can never fall under `PaneTable.usersNeed`.
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(showingComputers ? "Computers" : "Users",
                                 note: showingComputers ? computersSectionNote : usersSectionNote)
                    HStack(spacing: 0) {
                        tree
                            .frame(width: frame.tree)
                            .overlay(alignment: .trailing) {
                                Rectangle().fill(Theme.hairline).frame(width: 0.5)
                            }
                        if showingComputers { computersTable } else { usersTable }
                        if !showingComputers, frame.inspectorIsColumn {
                            if let selected {
                                UserProperties(user: selected)
                            } else {
                                InspectorPlaceholder(text: "Select a user to edit it.")
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.card))
                    .overlay {
                        RoundedRectangle(cornerRadius: Metrics.card)
                            .strokeBorder(Theme.hairline, lineWidth: 0.5)
                    }
                    .overlay(alignment: .trailing) {
                        if !frame.inspectorIsColumn, showInspector, let selected {
                            UserProperties(user: selected)
                                .background(Theme.content)
                                .overlay(alignment: .leading) {
                                    Rectangle().fill(Theme.hairline).frame(width: 0.5)
                                }
                                .shadow(color: .black.opacity(0.16), radius: 10, x: -2)
                        }
                    }
                }
                // **L-8 — one width rule app-wide.** The grouped panes have had
                // `PaneColumn`'s gutters since build 22; the table panes ran edge to edge, so
                // at 2360 the app showed either a ribbon in the middle of the window or a
                // table sprawling across all of it depending on which sidebar row was chosen.
                .padding(.horizontal, frame.gutter)
                .padding(.bottom, 18)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { paneWidth = $0 }
        // `-demoSheet newUser|newOU` opens one of this pane's two sheets on launch, so a
        // screenshot can show it (build 25). Reads nothing, writes nothing, changes no state
        // the app would keep.
        .onAppear {
            switch CommandLine.value(after: "-demoSheet") {
            case "newUser": newUser = NewUserRequest(ou: creationTarget ?? "")
            case "newOU": editor = .init(mode: .create, parent: creationTarget ?? "")
            default: break
            }
        }
        .sheet(item: $editor) { editor in
            OUEditorSheet(editor: editor) { self.editor = nil }
        }
        .sheet(item: $newUser) { request in
            NewUserSheet(request: request) { self.newUser = nil }
        }
        .confirmationDialog("Delete this OU?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let pending = pendingDelete { deleteOU(pending.path, confirmed: true) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
                .keyboardShortcut(.cancelAction)
        } message: {
            Text(pendingDelete?.warning ?? "")
        }
        .confirmationDialog("Remove this computer from the domain?", isPresented: Binding(
            get: { pendingComputerDelete != nil },
            set: { if !$0 { pendingComputerDelete = nil } })) {
            Button("Remove", role: .destructive) {
                if let computer = pendingComputerDelete { deleteComputer(computer) }
                pendingComputerDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingComputerDelete = nil }
                .keyboardShortcut(.cancelAction)
        } message: {
            Text(pendingComputerDelete.map {
                "This deletes the machine account \($0.account). The computer must join the domain again before its trust and machine authentication will work."
            } ?? "")
        }
    }

    /// The heading block the owner approved: an eyebrow, "One directory.", one line under it,
    /// and this pane's four controls on the right where build 25's `PaneStrip` put them.
    private var header: some View {
        PaneHeader(eyebrow: headline.eyebrow, heading: headline.heading,
                   subtitle: model.directoryIsLive ? directorySubtitle : headline.subtitle) {
            if model.directoryIsLive {
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder).frame(width: 150)
                Button("Refresh") { Task { await model.refreshDirectory() } }
                    .buttonStyle(.bordered)
                Button("New OU") { editor = .init(mode: .create, parent: creationTarget ?? "") }
                    .buttonStyle(.bordered)
                    .disabled(creationTarget == nil)
                    .help(creationTarget == nil ? OUCreationTarget.refusal(path: selectedOU ?? "") : "")
                Button("New user") { newUser = NewUserRequest(ou: creationTarget ?? "") }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(creationTarget == nil)
                    .help(creationTarget == nil ? OUCreationTarget.refusal(path: selectedOU ?? "") : "")
                // Only where it is the only way to reach the inspector (QA L-4).
                if !showingComputers, !frame.inspectorIsColumn {
                    Button(showInspector ? "Close editor" : "Edit user…") {
                        showInspector.toggle()
                    }
                    .buttonStyle(.bordered)
                    .disabled(selected == nil)
                    .help(selected == nil ? "Select a user first."
                          : showInspector ? "Hide the inspector" : "Show the inspector")
                }
            }
        }
        .paneColumn()
        .padding(.top, 18)
        .padding(.bottom, 16)
    }

    /// The mock's one-liner: what this directory is and how many accounts are in it.
    private var directorySubtitle: String {
        let count = model.directory.users.count
        return "\(count) account\(count == 1 ? "" : "s") in \(model.directoryLabel) · every edit applies at once"
    }

    /// The note beside the section title, which is what the OU selection has filtered to.
    private var usersSectionNote: String {
        let shown = listed.count
        let word = "\(shown) account\(shown == 1 ? "" : "s")"
        if let selectedOU { return "\(word) in \(OUPath.leaf(selectedOU))" }
        return "\(word) · from \(model.directoryLabel)"
    }

    private var computersSectionNote: String {
        let count = filteredComputers.count
        return "\(count) joined computer\(count == 1 ? "" : "s") · from the domain controller"
    }

    // MARK: OU tree

    /// **In phase with the table beside it** (build 26, QA L-2 / L-9).
    ///
    /// Three things had to change together. The header is exactly `Metrics.tableHeader` —
    /// build 25's root label wore `.padding(.top, 10)` + `.padding(.bottom, 4)` against a
    /// table header of a different height, which put every tree row 22 pt below the table row
    /// it was filtering, at every width, permanently. The rows are exactly
    /// `PaneTable.rowPitch`. And the count is a real 28 pt trailing column with monospaced
    /// digits, so a tenth user in an OU no longer steals width from that row's name alone.
    ///
    /// **All users** moved to the top, under the header, because a divider two thirds of the
    /// way down was the other thing breaking the pitch — and because the row directly under a
    /// heading that names the domain is the domain's own.
    private var tree: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(rootLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.2)
                    .foregroundStyle(Theme.faintText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: Metrics.tableHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.header)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairlineSoft).frame(height: 0.5) }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    row(title: "All users", icon: "person.2", count: model.directory.users.count,
                        selected: selectedOU == nil && !showingComputers, depth: 0, muted: false) {
                        showingComputers = false
                        selectedOU = nil
                    }
                    if model.doc.settings.directoryBackend == .activeDirectory {
                        row(title: "Computers", icon: "desktopcomputer",
                            count: model.directory.computers.count,
                            selected: showingComputers, depth: 0,
                            muted: model.directory.computers.isEmpty) {
                            showingComputers = true
                            selectedOU = nil
                            model.selectedUser = nil
                        }
                    }
                    ForEach(model.directory.ous) { ou in
                        ouNode(ou)
                    }

                    // **Why the New buttons are off** (build 25, QA H-5), where the selection
                    // is — not in a sheet, and not only as a tooltip on a greyed control.
                    if let selectedOU, selectedIsReadOnly {
                        Text(OUCreationTarget.refusal(path: selectedOU))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.faintText)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, PaneTable.tableBodyInset)
                .padding(.bottom, 10)
            }
        }
        .background(Theme.sidebar.opacity(0.35))
    }

    private var rootLabel: String {
        if model.doc.settings.directoryBackend == .activeDirectory, model.ad.isRunning {
            return model.applied.settings.ad.realm
        }
        let domain = model.doc.settings.dnsDomain
        return domain.isEmpty ? model.doc.settings.ldapSuffix : domain
    }

    @ViewBuilder
    private func ouNode(_ ou: DirectoryOU) -> some View {
        let path = ou.path
        let count = model.directory.users.filter { OUPath.isSame($0.ou, path) }.count
        row(title: OUPath.leaf(path), icon: count == 0 ? "folder" : "folder.fill", count: count,
            selected: !showingComputers && (selectedOU.map { OUPath.isSame($0, path) } ?? false),
            depth: OUPath.depth(path) - 1, muted: ou.isReadOnly || count == 0,
            readOnly: ou.isReadOnly) {
            showingComputers = false
            selectedOU = path
        }
        .overlay(alignment: .bottom) {
            // Where a dragged user would land.
            if dropTarget.map({ OUPath.isSame($0, path) }) ?? false {
                Rectangle().fill(Theme.accent).frame(height: 2)
            }
        }
        .contextMenu { ouCommands(ou) }
        .dropDestination(for: String.self) { items, _ in
            defer { dropTarget = nil }
            guard !ou.isReadOnly else { return false }
            move(items, to: path)
            return true
        } isTargeted: { targeted in
            dropTarget = targeted && !ou.isReadOnly ? path : nil
        }
    }

    /// One tree row: the icon, the name, and the count in its own column.
    ///
    /// `.truncationMode(.middle)` is QA **L-2b**: at 150 pt and depth 2 a name had about
    /// eleven characters and was cut at the **tail**, so `Domain Controllers` and
    /// `Domain Computers` were both `Domain Cont…` / `Domain Comp…` and two siblings sharing a
    /// prefix became indistinguishable. Middle elision keeps both ends, which is the same rule
    /// `CopyableValue(path:)` and the inspector's DN already follow (L-10).
    private func row(title: String, icon: String, count: Int, selected: Bool, depth: Int,
                     muted: Bool, readOnly: Bool = false, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: readOnly ? "lock" : icon)
                .font(.system(size: 10.5))
                .foregroundStyle(selected ? Theme.accent : Theme.dimText)
                .frame(width: 14)
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(muted ? Theme.faintText : Theme.text2)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text("\(count)")
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Theme.faintText)
                .frame(width: PaneTable.treeCountColumn, alignment: .trailing)
        }
        .padding(.leading, CGFloat(depth) * PaneTable.treeIndent)
        .padding(.horizontal, 8)
        .frame(height: PaneTable.rowPitch)
        .background(RoundedRectangle(cornerRadius: Metrics.row).fill(selected ? Theme.selectedRow : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .help(title)
    }

    @ViewBuilder
    private func ouCommands(_ ou: DirectoryOU) -> some View {
        let path = ou.path
        if ou.isReadOnly {
            Text("\(OUPath.leaf(path)) belongs to the directory itself.")
        } else {
            Button("New user here") { newUser = NewUserRequest(ou: path) }
            Button("New OU inside…") { editor = .init(mode: .create, parent: path) }
            Button("Rename…") { editor = .init(mode: .rename, parent: path) }
            Menu("Move to…") {
                Button("(top level)") { moveOU(path, under: "") }
                ForEach(destinations(excluding: path), id: \.self) { target in
                    Button(target) { moveOU(path, under: target) }
                }
            }
            Divider()
            Button("Delete", role: .destructive) { deleteOU(path) }
        }
    }

    private func destinations(excluding path: String) -> [String] {
        model.directory.ous.filter {
            !$0.isReadOnly && !OUPath.isSame($0.path, path) && !OUPath.isDescendant($0.path, of: path)
        }.map(\.path)
    }

    private func moveOU(_ path: String, under parent: String) {
        let previous = OUPath.parent(path) ?? ""
        let leaf = OUPath.leaf(path)
        let landed = parent.isEmpty ? leaf : parent + "/" + leaf
        Task {
            await model.directoryEdit(
                "Move \(leaf)",
                undo: DirectoryUndoStep(done: "Moved \(leaf)", button: "Undo move") { provider in
                    try await provider.moveOU(landed, under: previous)
                }) { provider in
                try await provider.moveOU(path, under: parent)
            }
        }
    }

    /// **The one directory action that moves other people's objects, and it now asks**
    /// (build 25, QA M-12).
    ///
    /// Deleting an OU relocates every account inside it to the top level — that is what both
    /// backends' executors do — and build 24 did it with neither a confirmation nor an undo.
    /// The confirmation counts what will move, and the undo recreates the container and puts
    /// them back.
    private func deleteOU(_ path: String, confirmed: Bool = false) {
        let accounts = model.directory.users.filter { OUPath.isSame($0.ou, path) }
        let descendants = model.directory.ous.filter { OUPath.isDescendant($0.path, of: path) }
        guard confirmed else {
            pendingDelete = OUDeletion(
                path: path,
                warning: OUHousekeeping.deleteWarning(path: path, accounts: accounts.count,
                                                      descendants: descendants.count))
            return
        }
        let moved = accounts.map(\.username)
        let undo = DirectoryUndoStep(done: "Deleted \(OUPath.leaf(path))",
                                     button: "Undo delete") { provider in
            try await provider.createOU(path)
            for username in moved { try await provider.moveUser(username, toOU: path) }
        }
        Task {
            await model.directoryEdit("Delete \(OUPath.leaf(path))", undo: undo) { provider in
                try await provider.deleteOU(path)
            }
            if selectedOU.map({ OUPath.isSame($0, path) }) ?? false { selectedOU = nil }
        }
    }

    /// Payload is the username, the same String-payload shape SheepDrop's sidebar uses.
    private func move(_ items: [String], to path: String) {
        for username in items {
            guard let user = model.directory.users.first(where: { $0.username == username }),
                  !user.isReadOnly else { continue }
            let previous = user.ou
            Task {
                let ok = await model.directoryEdit(
                    "Move \(username)",
                    undo: DirectoryUndoStep(done: "Moved \(username) to \(path)",
                                            button: "Undo move") { provider in
                        try await provider.moveUser(username, toOU: previous)
                    }) { provider in
                    try await provider.moveUser(username, toOU: path)
                }
                if ok { offerToPrune(previous) }
            }
        }
    }

    /// **An OU a move has just emptied** (build 25, QA M-2).
    ///
    /// `moveUser` creates its destination implicitly and prunes nothing, so a tree accumulated
    /// containers with nothing in them and no sign that anything had happened. Pruning silently
    /// is the wrong answer — an OU made on purpose and emptied for an afternoon is not litter,
    /// and the app must never delete a container a person made — so the banner offers it once,
    /// beside the move's own Undo, and says nothing more if it is ignored.
    private func offerToPrune(_ path: String) {
        let path = OUPath.normalized(path)
        guard let ou = model.directory.ous.first(where: { OUPath.isSame($0.path, path) }) else { return }
        let remaining = model.directory.users.filter { OUPath.isSame($0.ou, path) }.count
        let children = model.directory.ous.filter { OUPath.isDescendant($0.path, of: path) }.count
        guard children == 0,
              OUHousekeeping.isNowEmpty(path: path, remaining: remaining, isReadOnly: ou.isReadOnly)
        else { return }
        model.offerDirectoryFollowUp(OUHousekeeping.emptyOffer(path: path),
                                     button: "Delete this OU") {
            deleteOU(path, confirmed: true)
        }
    }

    // MARK: The table

    private struct ComputerRow: Identifiable {
        let id: String
        let computer: DirectoryComputer
        let name: String
        let account: String
        let joined: String
        let lastSeen: String
        let trusted: Bool
    }

    /// Machine accounts live beside people and OUs, as they do in AD Users and Computers.
    /// The richer join time comes from the controller's computer query; the account and its
    /// protection flag come from the same directory snapshot the tree uses.
    private var computerRows: [ComputerRow] {
        let now = Date()
        let realm = model.applied.settings.ad.realm
        let netbios = model.applied.settings.ad.netbiosDomain
        return model.directory.computers.map { computer in
            let fact = ad.computers.first {
                $0.name.caseInsensitiveCompare(computer.account) == .orderedSame || $0.dn == computer.dn
            }
            let seen = model.events.first {
                JoinedComputer.isSameMachine(event: $0.username, computer: computer.account,
                                             realm: realm, netbiosDomain: netbios)
            }?.time
            return ComputerRow(
                id: computer.dn, computer: computer,
                name: computer.account.hasSuffix("$") ? String(computer.account.dropLast()) : computer.account,
                account: computer.account, joined: fact?.whenCreated ?? "—",
                lastSeen: JoinedComputer.lastSeenLabel(seen, now: now) { LogTime.clock($0) },
                trusted: JoinedComputer.isTrusted(lastSeen: seen, now: now))
        }
    }

    private var filteredComputers: [ComputerRow] {
        guard !search.isEmpty else { return computerRows }
        return computerRows.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.account.localizedCaseInsensitiveContains(search)
        }
    }

    private var computersTable: some View {
        Table(filteredComputers) {
            TableColumn("Name") { row in
                Text(row.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(row.computer.isReadOnly ? Theme.faintText : Theme.text)
                    .lineLimit(1).truncationMode(.middle)
            }
            .width(min: PaneTable.computersMinimums[0], ideal: 130)
            TableColumn("Account") { row in
                Text(row.account)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(row.computer.isReadOnly ? Theme.faintText : Theme.text2)
                    .lineLimit(1).truncationMode(.middle)
            }
            .width(min: PaneTable.computersMinimums[1], ideal: 125)
            TableColumn("Joined") { row in
                Text(row.joined).font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.dimText).lineLimit(1)
            }
            .width(min: PaneTable.computersMinimums[2], ideal: 145)
            TableColumn("Last seen") { row in
                Text(row.lastSeen).font(.system(size: 11))
                    .foregroundStyle(Theme.dimText).lineLimit(1)
                    .help("The last authentication this RADIUS server answered for it.")
            }
            .width(min: PaneTable.computersMinimums[3], ideal: 120)
            TableColumn("Status") { row in
                StatusPill(text: row.trusted ? "Trusted" : "Idle",
                           kind: row.trusted ? .ok : .neutral)
            }
            .width(min: PaneTable.computersMinimums[4], ideal: PaneTable.fixedStatus)
            TableColumn("") { row in
                Button {
                    pendingComputerDelete = row.computer
                } label: {
                    Image(systemName: row.computer.isReadOnly ? "lock" : "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(row.computer.isReadOnly ? Theme.faintText : Theme.err)
                .disabled(row.computer.isReadOnly)
                .help(row.computer.isReadOnly
                      ? "The domain controller's own machine account cannot be removed here."
                      : "Remove \(row.account) from the domain")
            }
            .width(PaneTable.computersMinimums[5])
        }
        .contextMenu(forSelectionType: ComputerRow.ID.self) { ids in
            if let id = ids.first, let row = filteredComputers.first(where: { $0.id == id }) {
                if row.computer.isReadOnly {
                    Text("The domain controller's own machine account cannot be removed here.")
                } else {
                    Button("Remove from domain…", role: .destructive) {
                        pendingComputerDelete = row.computer
                    }
                }
            }
        } primaryAction: { _ in }
        .plainTable()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if filteredComputers.isEmpty {
                TableEmptyOverlay(search.isEmpty
                    ? "No joined computers yet. A machine appears here after it joins the domain."
                    : "Nothing matches \u{201C}\(search)\u{201D}.")
            }
        }
    }

    /// **Four columns that survive 980 pt** (build 26, QA L-1).
    ///
    /// The widths are `PaneTable.usersColumns(table:)` — Name 34 %, Username 20 %, Member of
    /// the slack, Enabled a fixed 72 — rather than a set of `min`s whose sum nobody ever added
    /// up. `Table` drops what does not fit **silently**, which is how build 18 lost Enabled at
    /// 1180 and build 24 lost it again at 980; the unit suite now walks every width from 980
    /// to 4000 and fails if the table is handed less than its own budget.
    ///
    /// Enable / Disable belongs to Edit user with the rest of the account's actions. Keeping
    /// it out of the table also means the control does not disappear when the window narrows.
    private var usersTable: some View {
        let columns = PaneTable.usersColumns(table: frame.table,
                                             canDisable: false)
        return Table(of: DirectoryUser.self, selection: selection) {
            TableColumn("Name") { user in
                Text(user.displayName.isEmpty ? user.username : user.displayName)
                    .font(.system(size: 12.5))
                    .foregroundStyle(user.isReadOnly ? Theme.faintText
                                     : user.enabled ? Theme.text : Theme.disabledText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: PaneTable.usersMinimums[0], ideal: columns.name)
            TableColumn("Username") { user in
                Text(user.username)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(user.isReadOnly ? Theme.faintText : Theme.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: PaneTable.usersMinimums[1], ideal: columns.username)
            TableColumn("Member of") { user in
                let memberOf = user.groups.joined(separator: ", ")
                Text(memberOf.isEmpty ? "—" : memberOf)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.dimText)
                    .lineLimit(1)
                    .help(memberOf.isEmpty ? "No groups" : memberOf)
            }
            .width(min: PaneTable.usersMinimums[2], ideal: columns.memberOf)
            TableColumn("Status") { user in
                if user.isReadOnly {
                    StatusPill(text: "Read-only")
                } else {
                    StatusPill(text: user.enabled ? "Enabled" : "Disabled",
                               kind: user.enabled ? .ok : .neutral)
                }
            }
            .width(columns.status)
        } rows: {
            ForEach(listed) { user in
                TableRow(user)
                    // Payload is the username, the same String-payload shape SheepDrop's
                    // sidebar uses. A read-only row drags nothing.
                    .draggable(user.isReadOnly ? "" : user.username)
                    .contextMenu {
                        if !user.isReadOnly {
                            // **The same submenu the OU rows have** (build 25, QA M-1). Until
                            // build 24 an account could be moved only by dragging it onto the
                            // tree or through the inspector's picker, and the row's own menu
                            // had one item on it.
                            Menu("Move to…") {
                                Button("(top level)") { move([user.username], to: "") }
                                ForEach(OUHousekeeping.destinations(for: model.directory.ous,
                                                                    excluding: user.ou),
                                        id: \.self) { target in
                                    Button(target) { move([user.username], to: target) }
                                }
                            }
                            Button("Delete", role: .destructive) { delete(user) }
                        } else {
                            Text("\(user.dn) belongs to the directory itself.")
                        }
                    }
            }
        }
        .tint(Theme.selectedAccent)
        // **No stripes** (QA L-5 / L-7; the owner: "สีสลับ 2 สี ไม่สวย").
        .plainTable()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if listed.isEmpty {
                TableEmptyOverlay(text: search.isEmpty ? "No users in this OU."
                                  : "Nothing matches \u{201C}\(search)\u{201D}.") {
                    if search.isEmpty, creationTarget != nil {
                        Button("New user here") { newUser = NewUserRequest(ou: creationTarget ?? "") }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
    }

    private func deleteComputer(_ computer: DirectoryComputer) {
        guard !computer.isReadOnly else { return }
        Task {
            let ok = await model.directoryEdit("Remove \(computer.account)") { provider in
                try await provider.deleteUser(computer.account)
            }
            if ok { await ad.refreshDirectoryFacts(model.applied.settings.ad) }
        }
    }

    /// `model.selectedUser` is a **username**; a `Table`'s selection is the row's `id`, which
    /// is its DN. This is the only place the two meet.
    private var selection: Binding<DirectoryUser.ID?> {
        Binding(get: { selected?.dn },
                set: { dn in
                    model.selectedUser = dn.flatMap { value in
                        model.directory.users.first { $0.dn == value }?.username
                    }
                })
    }


    /// Delete, with one step of undo that recreates the account.
    ///
    /// **Undo is honest about what it can do**: it makes an account of the same name, in the
    /// same OU, in the same groups, with the password this app knows. It is not the same
    /// object — a new AD account has a new SID and a device that trusted the old one will not
    /// trust this one — and the button says "Recreate" rather than "Undo" for exactly that
    /// reason when the backend is a domain.
    private func delete(_ user: DirectoryUser) {
        let password = model.doc.directoryPasswords[user.username.lowercased()]
        let groups = user.groups
        let ou = user.ou
        let display = user.displayName
        let name = user.username
        let isDomain = model.doc.settings.directoryBackend == .activeDirectory && model.ad.isRunning
        let undo = password.map { password in
            DirectoryUndoStep(done: "Deleted \(name)",
                              button: isDomain ? "Recreate \(name)" : "Undo delete") { provider in
                try await provider.createUser(name, displayName: display, ou: ou, password: password)
                if !groups.isEmpty { try await provider.setMembership(of: name, groups: groups) }
            }
        }
        Task {
            let ok = await model.directoryEdit("Delete \(name)", undo: undo) { provider in
                try await provider.deleteUser(name)
            }
            if ok {
                model.forgetDirectoryPassword(for: name)
                if model.selectedUser == name { model.selectedUser = nil }
            }
        }
    }
}

/// The OU a confirmation is being asked about, with the sentence that counts what it will
/// move (build 25, QA M-12).
struct OUDeletion: Identifiable {
    let id = UUID()
    let path: String
    let warning: String
}

// MARK: - The banner and the inline result

/// What went wrong with the directory, and what the last edit did.
///
/// One strip under every directory pane rather than two separate notices: they are read
/// together — "the DC did not answer", "saved · 0.3 s" — and a person looking for the first
/// should not have to find it somewhere else. **With LDAP off there is no strip at all**
/// (build 21): the pane itself is `DirectoryOffline`, which says so with a button on it, and a
/// warning bar over the top of that would be saying it twice.
struct DirectoryBanner: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        VStack(spacing: 0) {
            if model.directoryIsLive, let error = model.directoryError {
                strip(icon: "exclamationmark.triangle.fill", tint: Theme.err, text: error)
            }
            if let status = model.directoryStatus {
                HStack(spacing: 8) {
                    Image(systemName: status.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(status.isError ? Theme.err : Theme.ok)
                    Text(status.text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(status.isError ? Theme.text2 : Theme.dimText)
                        .lineLimit(2)
                    // **The one thing a finished edit may leave behind** (build 25, QA M-2).
                    if let followUp = model.directoryFollowUp {
                        Text(followUp.note)
                            .font(.system(size: 11.5)).foregroundStyle(Theme.dimText)
                    }
                    Spacer(minLength: 0)
                    if let followUp = model.directoryFollowUp {
                        Button(followUp.button) { followUp.perform() }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    if let undo = model.directoryUndo {
                        Button(undo.button) { Task { await model.undoLastDirectoryEdit() } }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    Button { model.clearDirectoryStatus() } label: {
                        Image(systemName: "xmark").font(.system(size: 9))
                    }
                    .buttonStyle(.borderless).foregroundStyle(Theme.dimText)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairlineSoft).frame(height: 0.5) }
            }
        }
        .sheet(item: $model.directoryImportProposal) { proposal in
            DirectoryImportSheet(proposal: proposal)
        }
    }

    private func strip(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.text2).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(tint.opacity(0.08))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairlineSoft).frame(height: 0.5) }
    }
}

// MARK: - LDAP is off

/// **What Users and Groups show while the directory comes up** (build 22, owner's decision —
/// `DirectoryPaneStart` has the rule and why).
///
/// Build 21 showed "LDAP is off." and a Start button here. The owner's answer to that was that
/// a pane whose content is a button asking to see the pane is a step nobody wants to take
/// twice a day, so opening Users or Groups starts the directory. What is left to draw is the
/// three states that are not a table: starting, failed, and "there is nothing to start".
///
/// The start is launched from a `Task` of its own rather than `.task {}`, because a `.task`
/// is cancelled when the view goes away — and switching to Status halfway through would then
/// cancel the start. Leaving the pane must change nothing at all.
struct DirectoryOffline: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        VStack(spacing: 12) {
            if let problem = model.directoryStartProblem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.warn)
                Text(problem)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text2)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 460)
                if let detail = model.directoryStartDetail, !detail.isEmpty {
                    Text(detail)
                        .hint()
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .frame(maxWidth: 460)
                }
                Button("Retry") { Task { await model.retryDirectoryFromPane() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(model.busy)
            } else if !model.directoryIsAvailable {
                Text(unavailable)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text2)
            } else {
                ProgressView().controlSize(.small)
                Text(model.directoryStartingLine)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { Task { await model.startDirectoryFromPane() } }
    }

    /// The one sentence that is true when there is nothing to start.
    private var unavailable: String {
        switch model.doc.settings.directoryBackend {
        case .activeDirectory:
            "Samba AD needs Apple's container tool, which is not installed."
        case .openLDAP:
            model.doc.settings.ldapEnabled
                ? "OpenLDAP was not found in this build."
                : "The LDAP server is switched off under Directory ▸ Server."
        }
    }
}

// MARK: - The one-time import

/// What an upgraded `lab.json` would put into the running backend, before it does it.
struct DirectoryImportSheet: View {
    @ObservedObject private var model = AppModel.shared
    let proposal: DirectoryImportProposal
    @State private var confirmNever = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move this lab's users into \(proposal.backendLabel)")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            Text("""
            The directory itself holds the users. lab.json keeps this list only as the seed a \
            new OpenLDAP database is filled from — this is the one-time copy across.
            """)
                .hint()

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text(proposal.report.summary)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2)
                    list("Create", proposal.report.createOUs.map { "OU \($0)" }
                         + proposal.report.createGroups.map { "group \($0)" }
                         + proposal.report.createUsers.map { "user \($0)" })
                    list("Already there", proposal.report.skipped)
                    list("Refused", proposal.report.refused)
                    if !proposal.migration.moves.isEmpty {
                        list("Lift out of OU=\(model.applied.settings.ad.managedRootRDN)",
                             proposal.migration.lines)
                    }
                    list("Cannot be lifted", proposal.migration.conflicts)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(height: 220)
            .background(RoundedRectangle(cornerRadius: Metrics.field).fill(Theme.well))

            HStack {
                // **Never is irreversible, so it asks** (build 25, QA L-10). It sets
                // `directoryImported` and the offer is not made again for this lab — there is
                // no menu item anywhere that brings it back.
                Button("Never", role: .destructive) { confirmNever = true }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Not now", role: .cancel) { model.dismissDirectoryImport() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Import") { Task { await model.runDirectoryImport(proposal) } }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(model.directoryBusy)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.small)
        .padding(18)
        .frame(width: 520)
        .confirmationDialog("Never import this table?", isPresented: $confirmNever) {
            Button("Never Import", role: .destructive) { model.refuseDirectoryImport() }
            Button("Cancel", role: .cancel) { }
                .keyboardShortcut(.cancelAction)
        } message: {
            Text("""
            This offer will not be made again for this lab, and there is no way to ask for it \
            back. lab.json keeps the table either way — it is the seed a brand-new OpenLDAP \
            database is filled from.
            """)
        }
    }

    @ViewBuilder
    private func list(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.dimText)
                .padding(.top, 6)
            ForEach(items, id: \.self) { item in
                Text(item).font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.text2)
            }
        }
    }
}

// MARK: - New user

struct NewUserRequest: Identifiable {
    let id = UUID()
    var ou: String
}

struct NewUserSheet: View {
    @ObservedObject private var model = AppModel.shared
    let request: NewUserRequest
    let dismiss: () -> Void

    @State private var username = ""
    @State private var displayName = ""
    @State private var password = ""
    /// **A repeat field, and both of them secure** (build 25, QA M-15). The sheet typed the
    /// password in the clear while the inspector's equivalent has been a `SecureField` since
    /// build 18, and neither asked for it twice — so one typo made an account nobody could log
    /// in as, diagnosable only by setting the password again.
    @State private var confirmation = ""
    @State private var revealPassword = false
    @State private var ou = ""

    /// Refused **at typing time**, in both backends — the build-15 rule. A group or a user
    /// called `Guests` resolves to AD's own object, and finding that out from a failed sync
    /// is how a real user ended up in `BUILTIN\Guests`.
    private var problem: String? {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let problem = DirectoryNames.problem(with: trimmed, kind: .user) { return problem }
        if model.directory.users.contains(where: { $0.username.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "“\(trimmed)” is already in the directory."
        }
        if !password.isEmpty, !confirmation.isEmpty, password != confirmation {
            return "The two passwords are not the same."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New user").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            field("Username") { TextField("alice", text: $username).frame(width: 220) }
            field("Display name") { TextField("Alice Anderson", text: $displayName).frame(width: 220) }
            field("Password") {
                HStack(spacing: 6) {
                    Group {
                        if revealPassword { TextField("", text: $password) }
                        else { SecureField("", text: $password) }
                    }
                    .frame(width: 194)
                    Button { revealPassword.toggle() } label: {
                        Image(systemName: revealPassword ? "eye.slash" : "eye").font(.system(size: 10))
                    }
                    .buttonStyle(.borderless).foregroundStyle(Theme.dimText)
                    .help(revealPassword ? "Hide the password" : "Show the password")
                    .accessibilityLabel(revealPassword ? "Hide the password" : "Show the password")
                }
            }
            field("Repeat") {
                Group {
                    if revealPassword { TextField("", text: $confirmation) }
                    else { SecureField("", text: $confirmation) }
                }
                .frame(width: 220)
            }
            field("OU") {
                Picker("", selection: $ou) {
                    Text("(top level)").tag("")
                    ForEach(model.directory.ous.filter { !$0.isReadOnly }) { entry in
                        Text(indented(entry.path)).tag(entry.path)
                    }
                }
                .labelsHidden().frame(width: 220)
            }
            if let problem {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(Theme.err)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty
                              || password.isEmpty || password != confirmation || problem != nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12.5))
        .controlSize(.small)
        .padding(20)
        .frame(width: 420)
        .onAppear { ou = request.ou }
    }

    private func create() {
        let name = username.trimmingCharacters(in: .whitespaces)
        let display = displayName
        let secret = password
        let path = ou
        dismiss()
        Task {
            let ok = await model.directoryEdit("Create \(name)") { provider in
                try await provider.createUser(name, displayName: display, ou: path, password: secret)
            }
            if ok {
                model.rememberDirectoryPassword(secret, for: name)
                model.selectedUser = name
            }
        }
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(label).foregroundStyle(Theme.dimText).frame(width: 90, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func indented(_ path: String) -> String {
        String(repeating: "    ", count: max(0, OUPath.depth(path) - 1)) + OUPath.leaf(path)
    }
}

// MARK: - Inspector

/// The right-hand column: everything about the selected account, each field committing on
/// Return or on losing focus. Nothing here is staged — there is no Apply in a directory pane,
/// and the result of every edit appears in the strip under the title as "saved · 0.3 s".
private struct UserProperties: View {
    @ObservedObject private var model = AppModel.shared
    /// Observed **directly**, not through `model`: `AppModel` does not republish its children's
    /// `@Published` state, so without this the "In the domain" figures would sit at whatever
    /// they were when this pane was opened.
    @ObservedObject private var ad = AppModel.shared.ad
    let user: DirectoryUser

    @State private var displayName = ""
    @State private var username = ""
    @State private var userPrincipalName = ""
    @State private var password = ""
    @State private var issuing = false
    @State private var confirmRevoke = false
    @State private var revoking = false
    /// **Which field has the keyboard** (build 25, QA M-13). The doc comment above has
    /// promised "committing on Return **or on losing focus**" since build 17 and only the
    /// first half was true: typing a display name and clicking anywhere else threw the edit
    /// away without a word. `@FocusState` is what makes the second half real — SwiftUI has no
    /// per-field "editing ended" callback, so the commit hangs off the focus leaving.
    private enum Field: Hashable { case displayName, username, userPrincipalName }
    @FocusState private var focused: Field?

    var body: some View {
        Inspector(title: user.displayName.isEmpty ? user.username : user.displayName,
                  subtitle: user.dn) {
            if user.isReadOnly {
                Text("""
                This is one of the directory's own objects. It is shown so the tree matches what \
                a device will find, and nothing here can change it.
                """)
                    .hint()
            } else {
                InspectorField("Display name") {
                    TextField("Alice Anderson", text: $displayName)
                        .focused($focused, equals: .displayName)
                        .onSubmit { commitDisplayName() }
                }
                InspectorField("Username") {
                    TextField("alice", text: $username)
                        .focused($focused, equals: .username)
                        .onSubmit { commitRename() }
                }
                InspectorField("User principal name") {
                    TextField("alice@lab.sheep", text: $userPrincipalName)
                        .focused($focused, equals: .userPrincipalName)
                        .onSubmit { commitUserPrincipalName() }
                    Text("Use a different suffix to test account mapping in a NAC. Samba AD registers it as an alternate UPN suffix automatically.")
                        .hint()
                }
                InspectorField("Password") {
                    HStack(spacing: 6) {
                        SecureField("new password", text: $password)
                        Button("Set") { commitPassword() }
                            .buttonStyle(.bordered)
                            .disabled(password.isEmpty)
                    }
                }
                InspectorField("Organizational unit") {
                    Picker("", selection: Binding(
                        get: { user.ou },
                        set: { path in
                            let previous = user.ou
                            edit("Move \(user.username)",
                                 undo: DirectoryUndoStep(done: "Moved \(user.username) to \(path)",
                                                         button: "Undo move") { provider in
                                     try await provider.moveUser(user.username, toOU: previous)
                                 }) { try await $0.moveUser(user.username, toOU: path) }
                        })) {
                        Text("(top level)").tag("")
                        ForEach(model.directory.ous.filter { !$0.isReadOnly }) { entry in
                            Text(String(repeating: "    ", count: max(0, OUPath.depth(entry.path) - 1))
                                 + OUPath.leaf(entry.path))
                                .tag(entry.path)
                        }
                    }
                    .labelsHidden()
                }
                InspectorField("Member of") {
                    if model.directory.groups.isEmpty {
                        Text("No groups yet.").hint()
                    }
                    // **The read-only filter the Groups side has had since build 20**
                    // (build 25, QA M-14). Without it a built-in AD group got a live checkbox
                    // that the executor then refused — a control whose only outcome is an
                    // error message.
                    ForEach(model.directory.groups.filter { !$0.isReadOnly }) { group in
                        Toggle(group.name, isOn: Binding(
                            get: { user.groups.contains { $0.caseInsensitiveCompare(group.name) == .orderedSame } },
                            set: { on in
                                var names = user.groups.filter { $0.caseInsensitiveCompare(group.name) != .orderedSame }
                                if on { names.append(group.name) }
                                edit("Member of") { try await $0.setMembership(of: user.username, groups: names) }
                            }))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                    }
                    // A built-in group this account is really in is shown, greyed, rather than
                    // hidden — the same rule the Groups pane's Members list follows (M-16).
                    ForEach(model.directory.groups.filter { group in
                        group.isReadOnly
                            && user.groups.contains { $0.caseInsensitiveCompare(group.name) == .orderedSame }
                    }) { group in
                        Toggle(group.name, isOn: .constant(true))
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))
                            .disabled(true)
                            .help("\(group.name) belongs to the directory itself.")
                    }
                }
                if model.directoryCanDisable {
                    Toggle("Account enabled", isOn: Binding(
                        get: { user.enabled },
                        set: { on in edit("\(on ? "Enable" : "Disable") \(user.username)") {
                            try await $0.setEnabled(user.username, to: on)
                        } }))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                } else {
                    Text("OpenLDAP has no \u{201C}account disabled\u{201D} flag.").hint()
                }
            }
            if model.doc.settings.directoryBackend == .activeDirectory { domainFacts }
            // **Not `isReadOnly`** (build 24). That flag is about editing the directory, and
            // issuing a certificate does not touch it — see
            // `DirectoryNames.mayIssueClientCertificate`. Gating on it hid the button for
            // every account in `CN=Users`, which on a real domain is all of them.
            if DirectoryNames.mayIssueClientCertificate(username: user.username, dn: user.dn) {
                InspectorField("Client certificate") {
                    // **Revoke is where the certificate was issued** (build 25, QA M-7). It
                    // was on the Certificates pane only, three panes away from the button
                    // that made the thing it revokes.
                    let index = model.env.loadClientIndex()
                    let revocable = index.revocable(for: user.username)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Button("Issue client certificate…") { issuing = true }
                                .buttonStyle(.bordered)
                            Button("Revoke…") { confirmRevoke = true }
                                .buttonStyle(.bordered)
                                .disabled(revoking || revocable == nil)
                                .help(revocable == nil
                                      ? "This account has no certificate that can be revoked."
                                      : "Revoke serial \(revocable?.serial.prefix(16) ?? "")")
                            if revoking { ProgressView().controlSize(.small) }
                        }
                        if let summary = index.summary(for: user.username) {
                            Text(summary).font(.system(size: 11)).foregroundStyle(Theme.faintText)
                        }
                    }
                    .confirmationDialog("Revoke this certificate?", isPresented: $confirmRevoke) {
                        Button("Revoke", role: .destructive) { revoke(revocable?.serial) }
                        Button("Cancel", role: .cancel) { }
                            .keyboardShortcut(.cancelAction)
                    } message: {
                        Text(revocable.map {
                            "\($0.username) — serial \($0.serial.prefix(16)). The device holding it "
                                + "stops authenticating, and the RADIUS server restarts."
                        } ?? "")
                    }
                }
            }
            // The entire RADIUS side of a user, in one line: which rule will fire.
            PolicyLineSummary(line: PolicySummary.forDirectoryUser(user, doc: model.doc))
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .id(user.dn)
        // Whichever field the focus has just left is committed, exactly as ⏎ would (M-13).
        .onChange(of: focused) { was, _ in
            switch was {
            case .displayName: commitDisplayName()
            case .username: commitRename()
            case .userPrincipalName: commitUserPrincipalName()
            case nil: break
            }
        }
        .onAppear(perform: load)
        .onChange(of: user.username) { load() }
        .onChange(of: user.displayName) { load() }
        .onChange(of: user.userPrincipalName) { load() }
        .sheet(isPresented: $issuing) {
            ClientCertificateSheet(username: user.username) { issuing = false }
        }
    }

    private func load() {
        displayName = user.displayName
        username = user.username
        userPrincipalName = user.userPrincipalName
        password = ""
    }

    private func revoke(_ serial: String?) {
        guard let serial else { return }
        revoking = true
        Task {
            let problem = await model.revokeClientCertificate(serial: serial)
            revoking = false
            if let problem { model.report(problem) }
        }
    }

    private func commitDisplayName() {
        guard displayName != user.displayName else { return }
        let value = displayName
        edit("Display name") { try await $0.setDisplayName(user.username, to: value) }
    }

    private func commitRename() {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        guard trimmed != user.username, !trimmed.isEmpty else { return }
        // Build 20, audit N-12: the same refusal the New user sheet gives, said before the
        // backend is asked. Two accounts sharing a username is not a directory error the user
        // can read — it is one row of the table quietly disappearing.
        if model.directory.users.contains(where: {
            $0.username.caseInsensitiveCompare(trimmed) == .orderedSame
                && $0.username.caseInsensitiveCompare(user.username) != .orderedSame
        }) {
            model.report("“\(trimmed)” already exists.")
            load()
            return
        }
        let old = user.username
        edit("Rename \(old) to \(trimmed)") { provider in
            try await provider.renameUser(old, to: trimmed)
        } then: {
            model.renameDirectoryPassword(from: old, to: trimmed)
            model.selectedUser = trimmed
        }
    }

    private func commitUserPrincipalName() {
        let value = userPrincipalName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.caseInsensitiveCompare(user.userPrincipalName) != .orderedSame else { return }
        if let problem = DirectoryNames.userPrincipalNameProblem(value) {
            model.report(problem)
            load()
            return
        }
        if model.directory.users.contains(where: {
            $0.username.caseInsensitiveCompare(user.username) != .orderedSame
                && $0.userPrincipalName.caseInsensitiveCompare(value) == .orderedSame
        }) {
            model.report("“\(value)” is already used by another account.")
            load()
            return
        }
        edit("User principal name") {
            try await $0.setUserPrincipalName(user.username, to: value)
        }
    }

    private func commitPassword() {
        let secret = password
        password = ""
        edit("Password for \(user.username)") { provider in
            try await provider.setPassword(user.username, to: secret)
        } then: {
            model.rememberDirectoryPassword(secret, for: user.username)
        }
    }

    /// Figures only the domain controller knows. Read, never edited.
    private var domainFacts: some View {
        let facts = ad.userFacts[user.username.lowercased()]
        return VStack(alignment: .leading, spacing: 5) {
            Text("In the domain").font(.system(size: 11)).foregroundStyle(Theme.faintText)
            if let facts {
                fact("Last logon", facts.lastLogon)
                fact("Logon count", facts.logonCount)
                fact("Bad passwords", facts.badPasswordCount)
            } else {
                Text(ad.isRunning ? "No counters for this account yet."
                     : "The domain controller is not running.").hint()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.field).fill(Theme.well))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.faintText)
                .frame(width: 96, alignment: .leading)
            Text(value).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.text2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func edit(_ label: String, undo: DirectoryUndoStep? = nil,
                      _ body: @escaping (any DirectoryProvider) async throws -> Void,
                      then after: (() -> Void)? = nil) {
        Task {
            let ok = await model.directoryEdit(label, undo: undo, body)
            if ok { after?() } else { load() }
        }
    }
}

// MARK: - OU editor

/// One sheet for create and rename, so they share their validation and their parent picker
/// instead of drifting apart. Delete is a context-menu item now: with the directory as the
/// original, an OU that still has something in it is refused by the backend itself, and the
/// message it gives is better than one this app would guess at.
struct OUEditor: Identifiable {
    enum Mode { case create, rename }
    let id = UUID()
    let mode: Mode
    /// Create: the parent to nest under. Rename: the OU being renamed.
    let parent: String
}

struct OUEditorSheet: View {
    @ObservedObject private var model = AppModel.shared
    let editor: OUEditor
    let dismiss: () -> Void

    @State private var name = ""
    @State private var parent = ""

    private var title: String { editor.mode == .create ? "New OU" : "Rename OU" }

    /// The path the sheet would produce, so the preview and the validation agree.
    private var resultingPath: String {
        switch editor.mode {
        case .create: OUPath.normalized(parent.isEmpty ? name : "\(parent)/\(name)")
        case .rename: OUPath.normalized(OUPath.parent(editor.parent).map { "\($0)/\(name)" } ?? name)
        }
    }

    private var problem: String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if !Validation.isValidName(trimmed) { return "A name \(Validation.nameRule)" }
        if let problem = DirectoryNames.problem(with: trimmed, kind: .ou) { return problem }
        if OUPath.depth(resultingPath) > OUPath.maxDepth {
            return "That would be \(OUPath.depth(resultingPath)) levels deep; the limit is \(OUPath.maxDepth)."
        }
        if editor.mode == .rename, OUPath.isSame(resultingPath, editor.parent) { return nil }
        if model.directory.ous.contains(where: { OUPath.isSame($0.path, resultingPath) }) {
            return "\(resultingPath) already exists."
        }
        return nil
    }

    private var canCommit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && problem == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)

            HStack(spacing: 10) {
                Text("Name").foregroundStyle(Theme.dimText).frame(width: 60, alignment: .leading)
                TextField("IT", text: $name).frame(width: 220)
            }
            if editor.mode == .create {
                HStack(spacing: 10) {
                    Text("Inside").foregroundStyle(Theme.dimText).frame(width: 60, alignment: .leading)
                    Picker("", selection: $parent) {
                        Text("(top level)").tag("")
                        ForEach(model.directory.ous.filter { !$0.isReadOnly }) { entry in
                            Text(indented(entry.path)).tag(entry.path)
                        }
                    }
                    .labelsHidden().frame(width: 220)
                }
            }
            if !resultingPath.isEmpty {
                Text(editor.mode == .rename ? "\(editor.parent) → \(resultingPath)" : resultingPath)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.dimText)
            }
            if let problem {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(Theme.err)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("OK") { commit() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(!canCommit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12.5))
        .controlSize(.small)
        .padding(20)
        .frame(width: 400)
        .onAppear {
            parent = editor.parent
            if editor.mode == .rename { name = OUPath.leaf(editor.parent) }
        }
    }

    private func indented(_ path: String) -> String {
        String(repeating: "    ", count: max(0, OUPath.depth(path) - 1)) + OUPath.leaf(path)
    }

    private func commit() {
        let path = resultingPath
        let leaf = OUPath.leaf(path)
        let source = editor.parent
        let mode = editor.mode
        dismiss()
        Task {
            switch mode {
            case .create:
                await model.directoryEdit("Create \(path)") { try await $0.createOU(path) }
            case .rename:
                await model.directoryEdit("Rename \(source) to \(leaf)") {
                    try await $0.renameOU(source, to: leaf)
                }
            }
        }
    }
}
