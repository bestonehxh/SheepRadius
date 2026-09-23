import AppKit
import SwiftUI

/// Groups, the same two-column shape as Users: a list on the left, Properties on the right.
///
/// **Live from build 17.** The rows are the running backend's groups and every tick of a
/// member checkbox is an `addmembers` / `removemembers` (AD) or a `member` modify (OpenLDAP)
/// that has already happened by the time the checkbox settles. No Apply, no Sync now.
///
/// A group carries nothing about the RADIUS reply — "members of this group get VLAN 10" is a
/// rule in the Policy pane, and Properties says which rule that is in one line.
struct GroupsView: View {
    @ObservedObject private var model = AppModel.shared
    @State private var newGroup: NewGroupRequest?

    private var selected: DirectoryGroup? {
        model.directory.groups.first { $0.name == model.selectedGroup }
    }

    /// The one width this pane measures (build 26 — `PaneTable`).
    @State private var paneWidth: CGFloat = PaneTable.minimumWindow - PaneTable.sidebar
    @State private var showInspector = false
    /// **The forty the directory brought** (decision C). Folded by default; the state is the
    /// person's for as long as the pane is open, and is not remembered across launches — the
    /// default *is* the decision.
    @State private var showBuiltIn = false

    private var frame: PaneTable.Frame {
        PaneTable.frame(pane: paneWidth, hasTree: false, need: PaneTable.groupsNeed)
    }

    private var headline: PaneHeadline.Block { PaneHeadline.block(for: "groups") }

    /// **The lab's own groups, and the directory's, split by `isReadOnly` and nothing else**
    /// (decision C).
    private var own: [DirectoryGroup] { model.directory.groups.filter { !$0.isReadOnly } }
    private var builtIn: [DirectoryGroup] { model.directory.groups.filter(\.isReadOnly) }

    /// A `Table` row: one of the lab's groups, the disclosure header, or one of the built-ins
    /// under it. A wrapper rather than `DirectoryGroup` itself because `DisclosureTableRow`
    /// needs the header and its children to be the same type, and inventing a fake
    /// `DirectoryGroup` to stand for "Built-in groups (40)" would put it one mis-click away
    /// from the executors.
    private struct Row: Identifiable {
        enum Kind { case group, disclosure }
        let id: String
        let kind: Kind
        let group: DirectoryGroup?
        let title: String
        let note: String
        let members: Int
    }

    private func row(_ group: DirectoryGroup) -> Row {
        Row(id: group.dn, kind: .group, group: group, title: group.name,
            note: group.description.isEmpty ? group.dn : group.description,
            members: group.members.count)
    }

    private var disclosureRow: Row {
        Row(id: "__builtin", kind: .disclosure, group: nil,
            title: GroupsSplit.disclosureTitle(builtIn: builtIn.count),
            note: "The directory's own groups. Shown so the pane matches what a device will find.",
            members: builtIn.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            DirectoryBanner()

            if !model.directoryIsLive {
                DirectoryOffline()
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle("Groups",
                                 note: GroupsSplit.sectionNote(own: own.count,
                                                               builtIn: builtIn.count,
                                                               backendLabel: model.directoryLabel))
                    HStack(spacing: 0) {
                        groupsTable
                        if frame.inspectorIsColumn {
                            if let selected {
                                GroupProperties(group: selected)
                            } else {
                                InspectorPlaceholder(text: "Select a group to edit its members.")
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
                            GroupProperties(group: selected)
                                .background(Theme.content)
                                .overlay(alignment: .leading) {
                                    Rectangle().fill(Theme.hairline).frame(width: 0.5)
                                }
                                .shadow(color: .black.opacity(0.16), radius: 10, x: -2)
                        }
                    }
                }
                .padding(.horizontal, frame.gutter)
                .padding(.bottom, 18)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { paneWidth = $0 }
        .sheet(item: $newGroup) { request in
            NewGroupSheet(request: request) { newGroup = nil }
        }
    }

    private var header: some View {
        PaneHeader(eyebrow: headline.eyebrow, heading: headline.heading,
                   subtitle: headline.subtitle) {
            if model.directoryIsLive {
                Button("Refresh") { Task { await model.refreshDirectory() } }
                    .buttonStyle(.bordered)
                Button("New group") { newGroup = NewGroupRequest() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                if !frame.inspectorIsColumn {
                    Button { showInspector.toggle() } label: {
                        Image(systemName: showInspector ? "sidebar.trailing" : "sidebar.right")
                    }
                    .buttonStyle(.bordered)
                    .disabled(selected == nil)
                    .help(selected == nil ? "Select a group first."
                          : showInspector ? "Hide the inspector" : "Show the inspector")
                }
            }
        }
        .paneColumn()
        .padding(.top, PaneColumn.headerTop)
        .padding(.bottom, 16)
    }

    /// **Three columns, the third fixed** (build 26, QA L-6).
    ///
    /// Build 25 clipped `Members` to **"Me"** at 980 while `Description` had visible slack —
    /// the table was wide enough and the proportions were simply wrong. Name 34 %, Description
    /// the slack, Members a fixed 72 pt right-aligned with monospaced digits, and no stripes.
    ///
    /// The **built-ins fold** (decision C): on Samba AD about forty of these belong to the
    /// directory rather than to the lab, and build 25 listed all of them with a "Directory's
    /// own" pill beside almost every row, which makes the pill decoration. One trailing
    /// disclosure row counts them instead. Nothing is hidden — they are one click away and
    /// still carry their read-only status inside.
    private var groupsTable: some View {
        let columns = PaneTable.groupsColumns(table: frame.table)
        let folds = GroupsSplit.showsDisclosure(builtIn: builtIn.count)
        return Table(of: Row.self, selection: selection) {
            TableColumn("Name") { row in
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(.system(size: 12.5,
                                      weight: row.kind == .disclosure ? .regular : .medium))
                        .foregroundStyle(row.group?.isReadOnly ?? true ? Theme.faintText : Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: PaneTable.groupsMinimums[0], ideal: columns.name)
            TableColumn("Description") { row in
                Text(row.note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.dimText)
                    .lineLimit(1).truncationMode(.middle)
                    .help(row.group?.dn ?? row.note)
            }
            .width(min: PaneTable.groupsMinimums[1], ideal: columns.description)
            TableColumn("Members") { row in
                Text("\(row.members)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Theme.dimText)
                    // The last column's trailing edge is the table's own, and a digit set hard
                    // against it is a digit the rounded border clips — measured at 1180 in the
                    // first cut of this build.
                    .padding(.trailing, 10)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(columns.members)
        } rows: {
            ForEach(own) { group in
                TableRow(row(group))
                    .contextMenu {
                        Button("Delete", role: .destructive) { delete(group) }
                    }
            }
            if folds {
                DisclosureTableRow(disclosureRow, isExpanded: $showBuiltIn) {
                    ForEach(builtIn) { group in
                        TableRow(row(group))
                            .contextMenu {
                                Text("\(group.name) belongs to the directory itself.")
                            }
                    }
                }
            } else {
                ForEach(builtIn) { group in
                    TableRow(row(group))
                        .contextMenu {
                            Text("\(group.name) belongs to the directory itself.")
                        }
                }
            }
        }
        .plainTable()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if own.isEmpty, builtIn.isEmpty {
                TableEmptyOverlay("No groups in \(model.directoryLabel).")
            } else if own.isEmpty {
                TableEmptyOverlay("""
                No groups of this lab's own yet. \(GroupsSplit.disclosureTitle(builtIn: builtIn.count)) \
                below belong to the directory.
                """)
            }
        }
    }

    /// `model.selectedGroup` is a **name**; a `Table`'s selection is the row's DN.
    private var selection: Binding<Row.ID?> {
        Binding(get: { selected?.dn },
                set: { dn in
                    model.selectedGroup = dn.flatMap { value in
                        model.directory.groups.first { $0.dn == value }?.name
                    }
                })
    }

    private func delete(_ group: DirectoryGroup) {
        let name = group.name
        let description = group.description
        let members = group.members
        Task {
            let ok = await model.directoryEdit(
                "Delete \(name)",
                undo: DirectoryUndoStep(done: "Deleted \(name)", button: "Undo delete") { provider in
                    try await provider.createGroup(name, description: description)
                    for member in members {
                        var groups = model.directory.users
                            .first { $0.username == member }?.groups ?? []
                        groups.append(name)
                        try await provider.setMembership(of: member, groups: groups)
                    }
                }) { provider in
                try await provider.deleteGroup(name)
            }
            if ok, model.selectedGroup == name { model.selectedGroup = nil }
        }
    }
}

// MARK: - New group

struct NewGroupRequest: Identifiable { let id = UUID() }

struct NewGroupSheet: View {
    @ObservedObject private var model = AppModel.shared
    let request: NewGroupRequest
    let dismiss: () -> Void

    @State private var name = ""
    @State private var description = ""

    /// The build-15 rule, applied **as the name is typed**: `sAMAccountName` is unique across
    /// the whole domain including groups, so a lab group called `Guests` resolves to
    /// `CN=Guests,CN=Builtin` and `addmembers` quietly puts real users into it.
    private var problem: String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let problem = DirectoryNames.problem(with: trimmed, kind: .group) { return problem }
        if model.directory.groups.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "“\(trimmed)” is already in the directory."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New group").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            HStack(spacing: 10) {
                Text("Name").foregroundStyle(Theme.dimText).frame(width: 90, alignment: .leading)
                TextField("NetAdmins", text: $name).frame(width: 220)
            }
            HStack(spacing: 10) {
                Text("Description").foregroundStyle(Theme.dimText).frame(width: 90, alignment: .leading)
                TextField("Network administrators", text: $description).frame(width: 220)
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
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || problem != nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12.5))
        .controlSize(.small)
        .padding(20)
        .frame(width: 420)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let text = description
        dismiss()
        Task {
            let ok = await model.directoryEdit("Create \(trimmed)") { provider in
                try await provider.createGroup(trimmed, description: text)
            }
            if ok { model.selectedGroup = trimmed }
        }
    }
}

// MARK: - Inspector

/// A group carries nothing about the RADIUS reply — "members of this group get VLAN 10" is a
/// rule in the Policy pane, and the line at the bottom says which rule that is.
struct GroupProperties: View {
    @ObservedObject private var model = AppModel.shared
    let group: DirectoryGroup

    var body: some View {
        Inspector(title: group.name, subtitle: group.dn) {
            if group.isReadOnly {
                Text("""
                This is one of the directory's own groups. It is shown so the pane matches what \
                a device will find, and nothing here can change it.
                """)
                    .hint()
            } else {
                InspectorField("Description") {
                    // Neither backend exposes "set a group's description" through this app's
                    // provider protocol, and inventing a method for one attribute would be a
                    // protocol that grows a method per field. Recreating the group would drop
                    // its members. So it is read-only, and says so.
                    Text(group.description.isEmpty ? "—" : group.description)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text2)
                        .textSelection(.enabled)
                }
                Text("A group's name and description are set when it is created — delete and create to change them.")
                    .hint()
                InspectorField("Members") {
                    if model.directory.users.isEmpty { Text("No users yet.").hint() }
                    ForEach(model.directory.users.filter { !$0.isReadOnly }) { user in
                        Toggle(user.username, isOn: Binding(
                            get: { group.members.contains { $0.caseInsensitiveCompare(user.username) == .orderedSame } },
                            set: { on in toggle(user, into: on) }))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12, design: .monospaced))
                    }
                    // **Greyed, not hidden** (build 25, QA M-16). The read-only filter above
                    // is right about the checkbox — the executor refuses to move one of the
                    // directory's own accounts — and wrong about the *list*: a built-in
                    // account that really is a member simply vanished from it, so the pane
                    // did not match what a device would find, which is the one thing these
                    // panes exist to do.
                    ForEach(model.directory.users.filter { user in
                        user.isReadOnly
                            && group.members.contains { $0.caseInsensitiveCompare(user.username) == .orderedSame }
                    }) { user in
                        Toggle(user.username, isOn: .constant(true))
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12, design: .monospaced))
                            .disabled(true)
                            .help("\(user.dn) belongs to the directory itself.")
                    }
                }
            }
            PolicyLineSummary(line: PolicySummary.forDirectoryGroup(group, doc: model.doc))
        }
        .controlSize(.small)
        .id(group.dn)
    }

    private func toggle(_ user: DirectoryUser, into member: Bool) {
        var names = user.groups.filter { $0.caseInsensitiveCompare(group.name) != .orderedSame }
        if member { names.append(group.name) }
        Task {
            await model.directoryEdit("\(member ? "Add" : "Remove") \(user.username)") { provider in
                try await provider.setMembership(of: user.username, groups: names)
            }
        }
    }
}
