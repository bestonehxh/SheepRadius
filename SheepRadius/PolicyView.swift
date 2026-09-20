import AppKit
import SwiftUI

/// The whole reply policy, as one ordered list that is read top to bottom (build 13).
///
/// Build 12 had three stacked sections — replies by group, per-user overrides, then rules — and
/// a three-step evaluation order to go with them. It was accurate and nobody could hold it in
/// their head. There is now one list, first match wins, and everything else in this pane is
/// either the editor for the selected row or hidden behind Advanced.
struct PolicyView: View {
    /// `-demoSection <id>` shows one part on its own, for a screenshot at the minimum window
    /// size. Named `DemoSection` rather than `Section` so it cannot be confused with SwiftUI's.
    enum DemoSection: String, CaseIterable {
        case list, editor, advanced
    }

    @ObservedObject private var model = AppModel.shared
    /// The row whose editor is open. Never nil in practice — `onAppear` picks the first rule,
    /// because a pane that shows its editor is a pane that explains itself.
    @State private var selected: UUID?
    @State private var dropTarget: UUID?
    /// The **username**, not an id: the preview reads the directory snapshot, which has no
    /// ids of this app's making (build 21).
    @State private var previewUser: String?
    @State private var previewRequest = PolicyRequest()
    @State private var previewTime = Date()
    @State private var showAdvanced = false
    @State private var importing: RadctlImport.Result?
    /// The `-CX` dump behind the one-line refusal (QA M-20).
    @State private var showUnlangDetail = false

    private let only = CommandLine.value(after: "-demoSection")
        .flatMap { raw in DemoSection.allCases.first { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame } }

    private func shows(_ section: DemoSection) -> Bool { only == nil || only == section }

    /// Shown under the "Also send" editor — the vendor forms a lab actually needs.
    static let examples = [
        "Filter-Id = \"staff\"",
        "Class = \"NetAdmins\"",
        "Session-Timeout := 3600",
        "Fortinet-Group-Name = \"NetAdmins\"",
        "Aruba-User-Role = \"employee\"",
        "Cisco-AVPair = \"shell:priv-lvl=15\"",
    ]

    private var context: PolicyContext { PolicyContext(model.doc) }

    var body: some View {
        VStack(spacing: 0) {
            PaneBody {
                PaneHeader(eyebrow: PaneHeadline.block(for: "policy").eyebrow,
                           heading: PaneHeadline.block(for: "policy").heading,
                           subtitle: "One ordered list · the order is the priority · no match leaves the VLAN of the port or SSID") {
                Menu {
                    Button("Import from radctl…") { importing = RadctlImport.read(directory: RadctlImport.defaultDirectory) }
                    Divider()
                    // **The one copy control that cannot confirm** (build 24): a menu item
                    // closes the menu the moment it is chosen, so there is nothing left on
                    // screen to turn into a checkmark. The same text is on a real button
                    // under Advanced, which does.
                    Button("Copy generated unlang") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ConfigGenerator.rulesUnlang(model.doc), forType: .string)
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .frame(width: 34)
                    .help("Import rules, or copy the generated unlang")
                Button { addRule() } label: { Label("Add rule", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
                }
                if shows(.list) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Rules").groupTitle().padding(.horizontal, 2)
                        list
                    }
                }
                if shows(.editor), let index = selectedIndex {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Rule \(index + 1)").groupTitle().padding(.horizontal, 2)
                        RuleEditor(rule: $model.doc.rules[index], context: context)
                    }
                }
                if shows(.advanced) { advanced }
            }
        }
        .onAppear {
            if selected == nil { selected = model.doc.rules.first?.id }
            if only != nil { showAdvanced = true }
        }
        .sheet(item: $importing) { result in
            RadctlImportSheet(result: result) { rules in
                model.doc.rules.insert(contentsOf: rules, at: 0)
                selected = rules.first?.id ?? selected
                importing = nil
            } cancel: {
                importing = nil
            }
        }
    }

    private var selectedIndex: Int? {
        guard let selected else { return nil }
        return model.doc.rules.firstIndex { $0.id == selected }
    }

    // MARK: The list

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.doc.rules.isEmpty {
                Text("No rules yet — everyone is accepted with no VLAN. Press “Add rule”.")
                    .hint()
                    .padding(.vertical, 14)
                    .padding(.horizontal, 14)
            }
            ForEach(Array(model.doc.rules.enumerated()), id: \.element.id) { index, rule in
                if let bound = model.doc.rules.firstIndex(where: { $0.id == rule.id }) {
                    row(index: index, rule: $model.doc.rules[bound])
                    Divider().opacity(0.35)
                }
            }
            fallthroughRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
    }

    private var header: some View {
        HStack(spacing: RuleColumn.spacing) {
            Text("#").ruleColumn(.number)
            Text("When").ruleColumn(.when)
            Text("VLAN").ruleColumn(.vlan)
            Text("Also send").ruleColumn(.alsoSend)
            Text("On").ruleColumn(.on)
            Text("").ruleColumn(.move)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Theme.faintText)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Theme.header)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairlineSoft).frame(height: 0.5) }
    }

    private func row(index: Int, rule: Binding<PolicyRule>) -> some View {
        let value = rule.wrappedValue
        let isSelected = selected == value.id
        let named = !value.name.trimmingCharacters(in: .whitespaces).isEmpty
        let when = value.conditions.isEmpty
            ? "Anyone"
            : value.conditions.map { $0.summary(context: context) }
                  .joined(separator: value.match == .any ? "  or  " : "  and  ")
        return HStack(spacing: RuleColumn.spacing) {
            Text("\(index + 1)")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.faintText)
                .ruleColumn(.number)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(named ? value.name : when)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1).truncationMode(.tail)
                    if let warning = missingGroup(in: value) {
                        StatusPill(text: warning, kind: .warn)
                    }
                }
                if named {
                    Text(when)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.faintText)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .ruleColumn(.when)
            .help(when)
            Group {
                if value.rejects {
                    Text("Reject").foregroundStyle(Theme.err)
                } else if !value.vlan.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(value.vlan).foregroundStyle(Theme.text2)
                } else {
                    Text("—").foregroundStyle(Theme.faintText)
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .ruleColumn(.vlan)
            Text(alsoSendSummary(value))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.dimText)
                .lineLimit(1).truncationMode(.tail)
                .ruleColumn(.alsoSend)
                .help(alsoSendSummary(value))
            Toggle("", isOn: rule.enabled)
                .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(Theme.accent)
                .ruleColumn(.on)
                .help(value.enabled ? "Switch this rule off — it stays here but is left out of the generated config"
                                    : "Switch this rule on")
            HStack(spacing: 1) {
                Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).disabled(index == 0)
                Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).disabled(index == model.doc.rules.count - 1)
            }
            .font(.system(size: 9))
            .foregroundStyle(Theme.dimText)
            .ruleColumn(.move)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .opacity(value.enabled ? 1 : 0.5)
        .background(isSelected ? Theme.selectedAccent : .clear)
        .contentShape(Rectangle())
        .onTapGesture { selected = value.id }
        .overlay(alignment: .bottom) {
            if dropTarget == value.id { Rectangle().fill(Theme.accent).frame(height: 2) }
        }
        .draggable(value.id.uuidString) {
            Text(value.displayName(index: index, context: context))
                .font(.system(size: 12)).padding(6)
        }
        .dropDestination(for: String.self) { items, _ in
            defer { dropTarget = nil }
            return drop(items, onto: index)
        } isTargeted: { targeted in
            dropTarget = targeted ? value.id : nil
        }
        .contextMenu {
            Button("Duplicate") { duplicate(index) }
            Button("Delete", role: .destructive) { delete(value.id) }
        }
    }

    /// **A rule whose group is not there**, in two flavours (build 21).
    ///
    /// *group no longer exists* — the lab was upgraded and the id this condition pointed at was
    /// not in the old group table, so there is no name to write. The rule is kept: it may be
    /// the only record of what somebody meant, and deleting it would take a VLAN assignment
    /// with it that nobody could then explain.
    ///
    /// *not in <the directory>* — the rule names a group the running directory does not have.
    /// Perfectly legal (the generated unlang is a string comparison that simply never matches,
    /// and the group may be created a minute from now), so it is a note, not a refusal. Said
    /// only while a directory is actually answering: with LDAP off, every group is "missing".
    private func missingGroup(in rule: PolicyRule) -> String? {
        if rule.conditions.contains(where: { $0.isDanglingGroup }) { return "group no longer exists" }
        guard model.directoryIsLive else { return nil }
        let have = Set(model.directory.groups.map { $0.name.lowercased() })
        let missing = rule.conditions.first {
            $0.kind.picksGroup && !$0.value.isEmpty && !have.contains($0.value.lowercased())
        }
        return missing.map { "no group “\($0.value)”" }
    }

    private func alsoSendSummary(_ rule: PolicyRule) -> String {
        var parts = rule.alsoSend
        let message = rule.rejectMessage.trimmingCharacters(in: .whitespaces)
        if rule.rejects, !message.isEmpty { parts.append("Reply-Message := \"\(message)\"") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    /// The row that is always last and is not a rule: what happens when nothing matched.
    private var fallthroughRow: some View {
        HStack(spacing: RuleColumn.spacing) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 10))
                .foregroundStyle(Theme.faintText)
                .ruleColumn(.number)
            Text("Anyone else (no rule matched)")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faintText)
                .ruleColumn(.when)
            Text("—")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.faintText)
                .ruleColumn(.vlan)
            Text("VLAN of the port/SSID")
                .font(.system(size: 11))
                .foregroundStyle(Theme.faintText)
                .ruleColumn(.alsoSend)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.header)
        .help("Access-Accept with no VLAN. The switch port or the SSID decides what the device lands on.")
    }

    // MARK: Editing the list

    private func addRule() {
        let rule = PolicyRule(conditions: [RuleCondition(kind: .groupIs,
                                                         value: model.directory.groups.first?.name ?? "")])
        model.doc.rules.append(rule)
        selected = rule.id
    }

    private func duplicate(_ index: Int) {
        guard model.doc.rules.indices.contains(index) else { return }
        var copy = model.doc.rules[index]
        copy.id = UUID()
        copy.conditions = copy.conditions.map { var c = $0; c.id = UUID(); return c }
        model.doc.rules.insert(copy, at: index + 1)
        selected = copy.id
    }

    private func delete(_ id: UUID) {
        model.doc.rules.removeAll { $0.id == id }
        if selected == id { selected = model.doc.rules.first?.id }
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard model.doc.rules.indices.contains(target) else { return }
        model.doc.rules.swapAt(index, target)
    }

    /// Payload is the rule's id, the same String shape the Users pane drags a user with.
    private func drop(_ items: [String], onto index: Int) -> Bool {
        guard let raw = items.first, let id = UUID(uuidString: raw),
              let from = model.doc.rules.firstIndex(where: { $0.id == id }), from != index else { return false }
        let rule = model.doc.rules.remove(at: from)
        model.doc.rules.insert(rule, at: min(index, model.doc.rules.count))
        selected = id
        return true
    }

    // MARK: Advanced

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.dimText)
                    Text("Advanced").cardTitle()
                    Text("preview a login · generated unlang · custom unlang")
                        .font(.system(size: 11)).foregroundStyle(Theme.faintText)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            if showAdvanced {
                preview
                Divider().opacity(0.4).padding(.vertical, 4)
                generated
                Divider().opacity(0.4).padding(.vertical, 4)
                custom
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
    }

    /// **Previewed against the directory** (build 21): the same accounts, OUs and group names
    /// `authorize` writes into `Sheep-OU` / `Sheep-Group`, so the preview answers the question
    /// radiusd is actually going to be asked.
    private var preview: some View {
        let live = model.directory.users.first { $0.username == previewUser }
            ?? model.directory.users.first
        let user = live.map { LabUser(username: $0.username, ou: $0.ou) }
        var request = previewRequest
        request.date = previewTime
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Preview a login").cardTitle()
                Picker("", selection: Binding(get: { live?.username }, set: { previewUser = $0 })) {
                    ForEach(model.directory.users) { Text($0.username).tag(Optional($0.username)) }
                }
                .labelsHidden().valueControl(Metrics.sheetField)
                .disabled(model.directory.users.isEmpty)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Text("An empty field means the attribute is not in the request at all.").hint()
                HelpDot(text: """
                Which is what a missing attribute does in unlang: the condition is false.
                """)
                Spacer(minLength: 0)
            }
            requestFields()
            if let user, let live {
                PolicyPreview(user: user, groups: live.groups.map { LabGroup(name: $0) },
                              rules: model.doc.rules, context: context,
                              request: request, showTraces: true)
            } else {
                Text(model.directoryIsLive ? "No users in the directory yet."
                     : OfflineDirectory.message).hint()
            }
        }
    }

    @ViewBuilder
    private func requestFields() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                field("NAS-IP-Address", "10.0.0.1", $previewRequest.nasIPAddress, width: 120)
                field("NAS-Identifier", "sw-lab-1", $previewRequest.nasIdentifier, width: 120)
                Text("NAS-Port-Type").font(.system(size: 11)).foregroundStyle(Theme.faintText)
                Picker("", selection: $previewRequest.nasPortType) {
                    Text("—").tag("")
                    ForEach(RulePortType.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }
                .labelsHidden().valueControl(Metrics.sheetField)
            }
            HStack(spacing: 8) {
                field("Called-Station-Id", "SIAM-BUILDING:test2", $previewRequest.calledStationID, width: 210)
                field("Calling-Station-Id", "aa:bb:cc:dd:ee:ff", $previewRequest.callingStationID, width: 150)
                // Pinned to a Gregorian calendar and en_US_POSIX: on a Thai-locale Mac the
                // default picker offers 2569 BE, which is the same trap ADUserFacts hit —
                // and radiusd's %H%G and %a are Gregorian and English whatever the Mac says.
                DatePicker("", selection: $previewTime, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden().datePickerStyle(.compact)
                    .environment(\.calendar, Calendar(identifier: .gregorian))
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                Button("Now") { previewTime = Date() }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
    }

    private func field(_ label: String, _ placeholder: String, _ text: Binding<String>, width: CGFloat) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.faintText)
            TextField(placeholder, text: text).frame(width: width)
        }
    }

    private var generated: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Generated unlang").cardTitle()
                Spacer()
                CopyButton("Copy", value: ConfigGenerator.rulesUnlang(model.doc), bordered: true)
                    .controlSize(.small)
            }
            HStack(spacing: 6) {
                Text("Read-only — edit the rules, not this.").hint()
                HelpDot(text: """
                This is what the list above becomes, as it is written into \
                raddb/radiusd.conf. A rule that stops puts everything below it in its `else`, \
                which is why a list where every rule stops collapses into one `if / elsif` \
                chain.
                """)
                Spacer(minLength: 0)
            }
            ScrollView([.horizontal, .vertical]) {
                Text(ConfigGenerator.rulesUnlang(model.doc))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.text2)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220)
            .background(RoundedRectangle(cornerRadius: Metrics.field).fill(Theme.well))
        }
    }

    private var custom: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                CardTitle(title: "Custom unlang (runs after the rules)", help: """
                Written verbatim into post-auth, in both the outer server and the inner tunnel, \
                after every rule. It is parsed by `radiusd -CX` on a staged copy as you type — \
                whether or not any server is running — and Apply parses the whole configuration \
                again before it replaces anything.

                The site-local attributes the rules read — Sheep-Group, Sheep-OU, Sheep-Rule — are \
                declared in raddb/dictionary in FreeRADIUS's own 3000–3999 range. Numbers above 255 \
                cannot be encoded into a RADIUS packet, so none of them can reach the wire.
                """)
                if model.customUnlangChecking { ProgressView().controlSize(.small) }
                Button("Check") { Task { await model.checkCustomUnlang() } }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(model.customUnlangChecking || model.tools.radiusd == nil)
                    .help(model.tools.radiusd == nil
                          ? "radiusd is not in this build, so nothing can parse the block."
                          : "Parse this block with radiusd -CX on a staged copy.")
            }
            TextEditor(text: $model.doc.customUnlang)
                .font(.system(size: 11.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(height: 120)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: Metrics.field).fill(Theme.well))
                .overlay {
                    // The border says whether it parses, where the block is.
                    RoundedRectangle(cornerRadius: Metrics.field)
                        .strokeBorder(model.customUnlangProblem == nil ? Color.clear : Theme.err,
                                      lineWidth: 1)
                }
                .overlay(alignment: .topLeading) {
                    if model.doc.customUnlang.isEmpty {
                        Text("if (&NAS-Port-Type == Ethernet) {\n\tupdate reply {\n\t\tFilter-Id := \"wired\"\n\t}\n}")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.disabledText)
                            .padding(.horizontal, 11).padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
            // **What `radiusd -CX` said, beside the block, before anything is applied**
            // (build 26, QA M-20). With radiusd stopped there was no Apply path at all, so a
            // broken block was written to lab.json in silence and came back at the next start
            // with a message claiming the server was "still running the last one that worked".
            if let problem = model.customUnlangProblem {
                VStack(alignment: .leading, spacing: 4) {
                    ValidationNotes(problems: [problem.summary])
                    if problem.detail != problem.summary, !problem.detail.isEmpty {
                        DisclosureGroup("Details", isExpanded: $showUnlangDetail) {
                            ScrollView {
                                Text(problem.detail)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.dimText)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                            .frame(height: 140)
                            .background(RoundedRectangle(cornerRadius: Metrics.field).fill(Theme.well))
                        }
                        .font(.system(size: 11.5))
                        .tint(Theme.accent)
                        .frame(maxWidth: Metrics.prose, alignment: .leading)
                    }
                }
            } else if !model.doc.customUnlang.isEmpty, !model.customUnlangChecking,
                      model.tools.radiusd != nil {
                Text("radiusd parses this block.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ok)
            }
        }
        .onChange(of: model.doc.customUnlang) { model.scheduleCustomUnlangCheck() }
        .onAppear { Task { await model.checkCustomUnlang() } }
    }
}

// MARK: - The columns

/// The rule list's columns, in one place so the header and the rows cannot drift apart.
///
/// **Every column is bounded at both ends**, which is the fix build 12 had to make to the Users
/// list: a single `maxWidth: .infinity` column is right at the 980 pt minimum and wrong on a
/// full-screen window, where it swallows every spare point and pushes the rest against the far
/// edge. The minimums add up to 452 pt including the spacing, inside the 708 pt this pane has
/// at the 980 pt minimum window (980 − 240 sidebar − 32 padding).
nonisolated enum RuleColumn {
    case number, when, vlan, alsoSend, on, move

    static let spacing: CGFloat = 10

    var bounds: (min: CGFloat, max: CGFloat) {
        switch self {
        case .number: (22, 26)
        case .when: (170, 330)
        case .vlan: (52, 70)
        case .alsoSend: (130, 320)
        case .on: (34, 40)
        case .move: (34, 40)
        }
    }
}

extension View {
    func ruleColumn(_ column: RuleColumn) -> some View {
        frame(minWidth: column.bounds.min, maxWidth: column.bounds.max, alignment: .leading)
    }
}

// MARK: - The editor for one rule

/// One rule, opened under the list. Deliberately one condition, one VLAN field and two
/// switches: the second condition, the attribute box and the Reply-Message are all opt-in, and
/// a rule that needs none of them is three controls wide.
struct RuleEditor: View {
    @ObservedObject private var model = AppModel.shared
    @Binding var rule: PolicyRule
    let context: PolicyContext
    /// **The switch is the rule's own flag now** (build 25, QA M-21), not view state that
    /// erased two fields on its way past.
    private var showAttributes: Binding<Bool> { $rule.sendsAttributes }
    @State private var showName = false

    init(rule: Binding<PolicyRule>, context: PolicyContext) {
        _rule = rule
        self.context = context
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading
            conditions
            action
            // **Beside the control that caused it** (build 25, QA M-19). Every one of these
            // sentences used to reach the person only through `problems.first` on one
            // truncated line of the ApplyBar, so a rule with two faults showed one of them,
            // half of it, on a pane the rule might not even be on.
            ValidationNotes(problems: model.ruleProblems(rule.id))
            if !rule.stopAfterMatch { keepsGoingNote }
            if rule.match == .any { anyOfNote }
        }
        .textFieldStyle(.roundedBorder)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
        .onAppear { sync() }
        .onChange(of: rule.id) { sync() }
    }

    private func sync() {
        showName = !rule.name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// "2 attribute lines" — what is being kept and no longer sent (M-21).
    private var attributesHeldBack: String {
        let n = rule.heldBackAttributeCount
        guard n > 0 else { return "" }
        return n == 1 ? "1 attribute line" : "\(n) attribute lines"
    }

    private var heading: some View {
        HStack(spacing: 8) {
            Text("This rule").cardTitle()
            Text(rule.displayName(index: 0, context: context))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.faintText)
                .lineLimit(1)
            Spacer(minLength: 0)
            if showName {
                TextField(rule.autoName(context: context), text: $rule.name)
                    .valueControl(Metrics.sheetField).controlSize(.small)
            } else {
                Button("Name it…") { showName = true }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("A rule is named after what it does unless you give it a name of your own")
            }
        }
    }

    // MARK: When

    private var conditions: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rule.conditions.enumerated()), id: \.element.id) { index, condition in
                if let bound = rule.conditions.firstIndex(where: { $0.id == condition.id }) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(index == 0 ? "When" : "and")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.dimText)
                            .frame(width: 38, alignment: .leading)
                            .padding(.top, 3)
                        ConditionRow(condition: $rule.conditions[bound],
                                     removable: rule.conditions.count > 1) {
                            rule.conditions.removeAll { $0.id == condition.id }
                        }
                    }
                }
            }
            if rule.conditions.isEmpty {
                HStack(spacing: 8) {
                    Text("When").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.dimText)
                        .frame(width: 38, alignment: .leading)
                    Text("Anyone — this rule matches every request.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.faintText)
                    Spacer(minLength: 0)
                }
            }
            if rule.conditions.count < 2 {
                Button {
                    rule.conditions.append(RuleCondition(kind: .portType,
                                                         value: RulePortType.wireless.rawValue))
                } label: { Label("AND another condition", systemImage: "plus") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .padding(.leading, 46)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.field).fill(Theme.well))
    }

    // MARK: Then

    private var action: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Then")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.dimText)
                    .frame(width: 38, alignment: .leading)
                if rule.rejects {
                    Text("reject this login")
                        .font(.system(size: 12)).foregroundStyle(Theme.err)
                } else {
                    Text("VLAN").font(.system(size: 11)).foregroundStyle(Theme.faintText)
                    TextField("—", text: $rule.vlan).frame(width: 64).controlSize(.small)
                    Text("leave empty to change only the attributes below")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.faintText)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 14) {
                // **Turning it off hides the lines; it does not erase them** (build 25,
                // QA M-21). Build 24 cleared `replyAttributes` *and* `sessionTimeout` on the
                // flick of a checkbox, with no warning and nothing to undo — and a rule's
                // reply attributes are typed by hand, often a dozen lines of them. They are
                // kept until Apply, the row says what will happen, and turning the switch
                // back on brings them straight back.
                Toggle("Also send attributes", isOn: showAttributes)
                    .controlSize(.small)
                Toggle("Reject instead", isOn: $rule.rejects)
                    .controlSize(.small)
                    .onChange(of: rule.rejects) { _, on in if on { rule.vlan = "" } }
                    .help("An Access-Reject. A rule either sets a VLAN or rejects — never both.")
                Spacer(minLength: 0)
            }
            .padding(.leading, 46)
            if !rule.sendsAttributes, !attributesHeldBack.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(Theme.warn)
                    Text("\(attributesHeldBack) \u{2014} no longer sent. "
                         + "\(attributesHeldBack.hasPrefix("1 ") ? "It is" : "They are") kept "
                         + "until you apply and discarded then. Switch this back on to keep "
                         + "\(attributesHeldBack.hasPrefix("1 ") ? "it" : "them").")
                        .hint()
                    Spacer(minLength: 0)
                }
                .padding(.leading, 46)
            }
            if rule.sendsAttributes {
                VStack(alignment: .leading, spacing: 4) {
                    ReplyEditor(text: $rule.replyAttributes)
                    Text("One `Name = value` per line; the operator may be =, := or +=. # starts a comment.")
                        .hint()
                    HStack(spacing: 10) {
                        ForEach(PolicyView.examples.prefix(3), id: \.self) { example in
                            Text(example)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.dimText)
                                .textSelection(.enabled)
                        }
                    }
                    if !rule.sessionTimeout.trimmingCharacters(in: .whitespaces).isEmpty {
                        HStack(spacing: 6) {
                            Text("Session-Timeout").font(.system(size: 11)).foregroundStyle(Theme.faintText)
                            TextField("3600", text: $rule.sessionTimeout).frame(width: 70).controlSize(.small)
                            Text("kept from an older build — new rules write it as an attribute line above")
                                .font(.system(size: 10.5)).foregroundStyle(Theme.faintText)
                        }
                    }
                }
                .padding(.leading, 46)
            }
            if rule.rejects {
                HStack(spacing: 6) {
                    Text("Reply-Message").font(.system(size: 11)).foregroundStyle(Theme.faintText)
                    TextField("optional — why", text: $rule.rejectMessage)
                        .frame(maxWidth: 320).controlSize(.small)
                }
                .padding(.leading, 46)
                HStack(spacing: 6) {
                    Text("PAP, CHAP and MS-CHAP carry it back; a tunnel does not.").hint()
                    HelpDot(text: """
                    A reject decided inside a PEAP or TTLS tunnel arrives as a bare \
                    EAP-Failure — measured — so the message is dropped there, by FreeRADIUS \
                    and not by this app.
                    """)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 46)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.field).fill(Theme.well))
    }

    private var keepsGoingNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.to.line").font(.system(size: 10)).foregroundStyle(Theme.warn)
            Text("This rule does not stop the walk — rules below it can overwrite it.").hint()
            Button("Make first match win") { rule.stopAfterMatch = true }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }

    private var anyOfNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.circle").font(.system(size: 10)).foregroundStyle(Theme.warn)
            Text("This rule matches ANY of its conditions, which older builds could set. New rules join them with AND.")
                .hint()
            Button("Use AND") { rule.match = .all }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }
}

// MARK: - One condition

struct ConditionRow: View {
    @ObservedObject private var model = AppModel.shared
    @Binding var condition: RuleCondition
    var removable = true
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // **All twenty-one kinds, in four sections** (build 25, QA M-23 —
                // `ConditionKind.groupedMenu` has the grouping and why).
                Picker("", selection: $condition.kind) {
                    ForEach(ConditionKind.groupedMenu(including: condition.kind)) { group in
                        Section(group.title) {
                            ForEach(group.kinds, id: \.self) { Text($0.label).tag($0) }
                        }
                    }
                }
                .labelsHidden().valueControl(Metrics.sheetField).controlSize(.small)
                value
                Spacer(minLength: 0)
                if removable {
                    Button(action: remove) { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(Theme.dimText)
                        .help("Remove this condition")
                }
            }
            if condition.kind.isTimeWindow { timeWindow }
            if danglingClient != nil {
                Text("The client this rule named is not in the Clients table any more. Pick "
                     + "another, or the rule will never match.")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(condition.kind.hint)
                .font(.system(size: 10.5)).foregroundStyle(Theme.faintText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var value: some View {
        if condition.kind.picksGroup {
            // **The directory's groups, by name** (build 21). The rule holds the name because
            // that is what `&control:Sheep-Group` carries; a name the running directory does
            // not have is still offered as the current choice, so opening the pane never
            // silently rewrites somebody's rule.
            Picker("", selection: $condition.value) {
                Text(pickerPlaceholder).tag("")
                ForEach(namesIncludingCurrent(model.directory.groups.map(\.name)), id: \.self) {
                    Text($0).tag($0)
                }
            }
            .labelsHidden().valueControl(Metrics.sheetField).controlSize(.small)
        } else if condition.kind.picksOU {
            Picker("", selection: $condition.value) {
                Text(pickerPlaceholder).tag("")
                ForEach(namesIncludingCurrent(model.directory.ous.map(\.path)), id: \.self) {
                    Text($0).tag($0)
                }
            }
            .labelsHidden().valueControl(Metrics.sheetField).controlSize(.small)
        } else if condition.kind.picksClient {
            // **A client that was deleted is still shown, as itself** (build 25, QA M-22).
            // `namesIncludingCurrent` has done this for groups and OUs since build 21 and was
            // never applied here: a `Picker` whose selection is not among its tags draws
            // **blank**, and the next interaction writes the first tag into the rule — so a
            // rule that pointed at a deleted switch silently became a rule about a different
            // one. The row keeps its own id and says what happened to it.
            Picker("", selection: $condition.reference) {
                Text(model.doc.clients.isEmpty ? "no clients yet" : "—").tag(Optional<UUID>.none)
                ForEach(model.doc.clients) { client in
                    Text(client.name.isEmpty ? client.address : "\(client.name) · \(client.address)")
                        .tag(Optional(client.id))
                }
                if let missing = danglingClient {
                    Text("client no longer exists").tag(Optional(missing))
                }
            }
            .labelsHidden().valueControl(Metrics.sheetField).controlSize(.small)
        } else if condition.kind.picksPortType {
            Picker("", selection: $condition.value) {
                Text("—").tag("")
                ForEach(RulePortType.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
            }
            .labelsHidden().valueControl(Metrics.sheetField).controlSize(.small)
        } else if condition.kind.isTimeWindow || condition.kind.isValueless {
            EmptyView()
        } else {
            TextField(condition.kind.placeholder, text: $condition.value)
                .font(condition.kind.isRaw ? .system(size: 11.5, design: .monospaced) : nil)
                .valueControl(Metrics.sheetField)
                .controlSize(.small)
        }
    }

    /// The client id this condition names when no client in the document has it — the tag
    /// that has to exist for the picker to render at all (M-22).
    private var danglingClient: UUID? {
        guard condition.kind.picksClient, let id = condition.reference,
              !model.doc.clients.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// "LDAP is off." when there is no snapshot to pick from, "—" when there is.
    private var pickerPlaceholder: String {
        model.directoryIsLive ? "—" : OfflineDirectory.message
    }

    /// The snapshot's names, with whatever the rule already says put back if the directory no
    /// longer has it. A `Picker` whose selection is not among its tags shows nothing at all and
    /// writes the first tag back on the next edit, which would turn "a group that was deleted"
    /// into "a different group" without anybody touching the rule.
    private func namesIncludingCurrent(_ names: [String]) -> [String] {
        let current = condition.value.trimmingCharacters(in: .whitespaces)
        guard !current.isEmpty, !names.contains(current) else { return names }
        return names + [current]
    }

    private var timeWindow: some View {
        HStack(spacing: 8) {
            MinutePicker(label: "from", minutes: $condition.fromMinute)
            MinutePicker(label: "to", minutes: $condition.toMinute)
            ForEach(1...7, id: \.self) { day in
                let on = condition.weekdays.contains(day)
                Button(RuleUnlang.weekdayAbbreviations[day - 1]) {
                    if on { condition.weekdays.removeAll { $0 == day } }
                    else { condition.weekdays.append(day) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.accent : Theme.faintText)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Capsule().fill(on ? Theme.accent.opacity(0.15) : Theme.control))
                .help(RuleUnlang.weekdayNames[day - 1])
            }
            Spacer(minLength: 0)
        }
    }
}

/// Hours and minutes as two steppers, so the generated `"%H%G"` bounds are always four digits.
struct MinutePicker: View {
    let label: String
    @Binding var minutes: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(Theme.faintText)
            Text(RuleUnlang.clock(minutes))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.text2)
                .frame(width: 42, alignment: .trailing)
            Stepper("") { minutes = min(1439, minutes + 15) } onDecrement: { minutes = max(0, minutes - 15) }
                .labelsHidden().controlSize(.mini)
        }
    }
}

/// The free-text `Attribute = value` editor.
struct ReplyEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 11.5, design: .monospaced))
            .scrollContentBackground(.hidden)
            .frame(height: 46)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: Metrics.field).fill(Theme.well))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Filter-Id = \"staff\"")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.disabledText)
                        .padding(.horizontal, 11).padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
    }
}

// MARK: - Importing radctl's tables

extension RadctlImport.Result: Identifiable {
    /// Enough to tell one reading of the two files from another, which is all `.sheet(item:)`
    /// asks of it.
    var id: String { items.map(\.origin).joined(separator: ",") + "|" + missing.joined(separator: ",") }
}

struct RadctlImportSheet: View {
    let result: RadctlImport.Result
    let add: ([PolicyRule]) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import from radctl").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            Text("\(RadctlImport.defaultDirectory)/\(RadctlImport.mapFileName) and \(RadctlImport.rulesFileName), read and not modified.")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.faintText)
                .textSelection(.enabled)

            if result.items.isEmpty {
                Text(result.missing.isEmpty
                     ? "Nothing to import — both files are empty apart from their headers."
                     : "Nothing to import. radctl's files are not present on this host:")
                    .font(.system(size: 12)).foregroundStyle(Theme.text2)
                ForEach(result.missing, id: \.self) { path in
                    Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.faintText)
                }
            } else {
                Label("radctl's last match wins; this list's first match wins. The order below is therefore **reversed** — the advanced rules first, then the maps — and they go in at the top of the list, above the group rules, which is where they have to be to keep overriding them.", systemImage: "arrow.up.arrow.down")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text2)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: Metrics.field).fill(Theme.well))

                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(result.items.enumerated()), id: \.element.id) { index, item in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.faintText).frame(width: 20, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.rule.displayName(index: index))
                                        .font(.system(size: 12)).foregroundStyle(Theme.text)
                                    Text("\(item.origin)  \(item.source)")
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(Theme.faintText)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 200)
            }

            if !result.problems.isEmpty {
                Text("Skipped:").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.warn)
                ForEach(result.problems, id: \.self) { problem in
                    Text(problem).font(.system(size: 11)).foregroundStyle(Theme.faintText)
                }
            }

            HStack {
                Spacer()
                // **Esc closes it** (build 25, QA L-12): the radctl sheet had no cancel
                // binding at all, so ⌘. fell through to Stop All Servers behind it.
                Button("Cancel", role: .cancel) { cancel() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button(result.items.count == 1 ? "Add 1 rule" : "Add \(result.items.count) rules") {
                    add(result.items.map(\.rule))
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .disabled(result.items.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

// MARK: - The resolved reply

/// The reply the rules produce, rule by rule, for the Preview under Advanced.
struct PolicyPreview: View {
    let user: LabUser
    let groups: [LabGroup]
    var rules: [PolicyRule] = []
    var context = PolicyContext()
    var request = PolicyRequest()
    /// The Policy pane shows the rule-by-rule trace; anything else only wants the outcome.
    var showTraces = false

    private var result: PolicyResult {
        PolicyEvaluator.evaluate(user: user, groups: groups, rules: rules,
                                 context: context, request: request)
    }

    private var activeRules: [PolicyRule] { rules.filter { $0.enabled } }

    var body: some View {
        let outcome = result
        VStack(alignment: .leading, spacing: 5) {
            if showTraces {
                traces(outcome)
                Divider().opacity(0.4).padding(.vertical, 3)
            }
            Text("Reply").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.dimText)
            if outcome.rejected {
                Label(outcome.rejectMessage.isEmpty
                      ? "Access-Reject — a rule rejected this request."
                      : "Access-Reject — “\(outcome.rejectMessage)”",
                      systemImage: "xmark.circle.fill")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.err)
            }
            if outcome.lines.isEmpty && !outcome.rejected {
                Text("Access-Accept with no attributes — the VLAN of the port or SSID applies.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.faintText)
            }
            ForEach(outcome.lines) { item in line(item.line, item.source) }
            if outcome.approximate {
                Text("A raw condition is in play, so this is the best guess the app can make — only radiusd decides those.")
                    .hint()
            }
        }
    }

    @ViewBuilder
    private func traces(_ outcome: PolicyResult) -> some View {
        Text("Rules").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.dimText)
        if outcome.traces.isEmpty {
            Text("No rules yet.").font(.system(size: 11.5)).foregroundStyle(Theme.faintText)
        }
        ForEach(outcome.traces) { trace in
            HStack(spacing: 8) {
                Image(systemName: icon(trace.verdict))
                    .font(.system(size: 10))
                    .foregroundStyle(tint(trace.verdict))
                Text("\(trace.index + 1). \(trace.name)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(trace.verdict == .matched ? Theme.text : Theme.text2)
                    .lineLimit(1)
                Text(describe(trace))
                    .font(.system(size: 10.5)).foregroundStyle(Theme.faintText)
                Spacer(minLength: 0)
            }
        }
    }

    private func describe(_ trace: RuleTrace) -> String {
        if !trace.note.isEmpty { return trace.note }
        switch trace.verdict {
        case .matched: return "fired"
        case .skipped: return "did not match"
        case .notReached: return "not reached — an earlier rule matched"
        case .disabled: return "switched off"
        case .unknown: return "cannot be decided here"
        }
    }

    private func icon(_ verdict: RuleVerdict) -> String {
        switch verdict {
        case .matched: "checkmark.circle.fill"
        case .skipped: "circle"
        case .notReached: "minus.circle"
        case .disabled: "slash.circle"
        case .unknown: "questionmark.circle"
        }
    }

    private func tint(_ verdict: RuleVerdict) -> Color {
        switch verdict {
        case .matched: Theme.accent
        case .unknown: Theme.warn
        default: Theme.faintText
        }
    }

    private func line(_ text: String, _ source: String) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.text2)
                .textSelection(.enabled)
            Text(source.hasPrefix("rule: ") ? source : "from \(source)")
                .font(.system(size: 10.5))
                .foregroundStyle(source.hasPrefix("rule: ") ? Theme.accent : Theme.faintText)
            Spacer(minLength: 0)
        }
    }
}

/// The one muted line Users and Groups show instead of an editor, with the way into this pane.
///
/// "RADIUS: rule 3 · Group NetAdmins → VLAN 10". Identity panes describe the policy; they do
/// not contain any of it.
struct PolicyLineSummary: View {
    @ObservedObject private var model = AppModel.shared
    let line: PolicySummary.Line

    var body: some View {
        // **Wraps rather than truncates.** This is the one line in the inspector that says
        // what will actually happen to the person's login — "rule 1 · Group NetAdmins · VLAN
        // 10" — and at the inspector's real width (the pane is ~1180 pt before the inspector
        // takes its share) `lineLimit(1)` cut it off mid-rule-name. A summary that has to be
        // hovered to be read is not a summary. `firstTextBaseline` keeps the label, the
        // caveat and the link sitting on the first line while the text grows downwards.
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("RADIUS:")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.faintText)
            Text(line.text)
                .font(.system(size: 11.5))
                .foregroundStyle(line.ruleID == nil ? Theme.faintText : Theme.text2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .help(line.text)
            if !line.certain {
                Text("· depends on the request")
                    .font(.system(size: 11)).foregroundStyle(Theme.faintText)
            }
            Button("Open Policy") { model.mainPane = .policy }
                .buttonStyle(.link)
                .font(.system(size: 11))
            Spacer(minLength: 0)
        }
    }
}
