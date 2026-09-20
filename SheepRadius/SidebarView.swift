import SwiftUI

/// The build-18 sidebar (PROJECT-STATUS §15): the traffic-light row, the two servers with their
/// switches, then twelve rows in four groups — **no icons, no duplicated page, no footer**.
///
/// (Thirteen in five until build 21 took the Local users pane out; the count is corrected here
/// in build 25, QA L-19. Overview 3 · Directory 4 · RADIUS 3 · App 2.)
///
/// What went away and why:
///
/// - **The icons.** Thirteen SF Symbols, none of which said anything the word next to it did
///   not. They made the list look like a toolbar and cost 25 pt of a 212 pt column.
/// - **"Certificate" twice.** The same CA card appeared under RADIUS and under Directory. There
///   is one Certificates pane now, with the CA and both leaves.
/// - **The RADIUS / LDAP / BOTH badges.** A field is not more understandable for being told
///   which daemon reads it.
/// - **The footer warning.** "Lab use only…" sat under every pane of the app forever; it is one
///   line in Settings ▸ Components now.
///
/// The second server row is called **LDAP** (build 21, PROJECT-STATUS §18). It used to be
/// "Directory", with which directory it was hidden in Directory ▸ Server two panes away; the
/// owner asked for the choice to be on the switch — "ทำปุ่มให้เลือก Radius กับ LDAP > OpenLDAP
/// or SAMBA" — so **OpenLDAP / Samba AD** sits under the row, bound to the same
/// `settings.directoryBackend` the pane binds to, and greyed while the directory is up because
/// the two cannot both have 389.
struct SidebarView: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The sidebar owns the titlebar area, so it also owns the traffic lights' space.
            // The main column reserves the same band (build 22), from the same constant.
            HStack { Spacer() }
                .frame(height: model.isFullScreen ? Metrics.titleBarFullScreen : Metrics.titleBar)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sectionHeader("Servers")
                    // `detail` describes the *running* server, so it reads `applied` — what the
                    // processes were generated from — never the unsaved edits in `doc`.
                    // Availability is the other way round: starting commits `doc` first.
                    ServerRow(server: model.radius, name: "RADIUS",
                              detail: "udp \(model.applied.settings.authPort) · \(model.applied.settings.acctPort)",
                              available: model.tools.radiusReady,
                              start: { await model.startRadius() })
                    if model.doc.settings.directoryBackend == .activeDirectory {
                        ADServerRow()
                    } else {
                        ServerRow(server: model.ldap, name: "LDAP",
                                  detail: model.doc.settings.ldapSuffix,
                                  available: model.tools.ldapReady && model.doc.settings.ldapEnabled,
                                  starting: model.directoryStarting,
                                  pairedWithRadius: true,
                                  start: { await model.startLDAP() },
                                  stop: { await model.stopDirectoryFromSwitch() })
                    }
                    SidebarBackendChoice()

                    sectionHeader("Overview")
                    group {
                        row(.status, "Status")
                        row(.test, "Test")
                        row(.log, "Log")
                    }

                    sectionHeader("Directory", unavailable: directoryNote)
                    group {
                        row(.users, "Users", count: model.directory.users.count)
                        row(.groups, "Groups", count: model.directory.groups.count)
                        row(.ldapServer, "Server")
                        row(.devices, "Devices")
                    }
                    .opacity(directoryNote == nil ? 1 : 0.55)

                    sectionHeader("RADIUS", unavailable: radiusNote)
                    group {
                        row(.clients, "Clients", count: model.doc.clients.count)
                        row(.policy, "Policy")
                        row(.radiusServer, "Server")
                    }
                    .opacity(radiusNote == nil ? 1 : 0.55)

                    sectionHeader("App")
                    group {
                        row(.certificates, "Certificates")
                        row(.settings, "Settings")
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Why a whole section is dimmed, or nil when it is fine.
    private func group(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 1) { content() }
            .padding(.horizontal, 8)
    }

    private var radiusNote: String? {
        model.tools.radiusReady ? nil : "FreeRADIUS not found"
    }

    private var directoryNote: String? {
        if model.doc.settings.directoryBackend == .activeDirectory {
            return model.tools.containerTool == nil ? "container tool not installed" : nil
        }
        if !model.tools.ldapReady { return "OpenLDAP not found" }
        if !model.doc.settings.ldapEnabled { return "switched off in Server" }
        return nil
    }

    private func row(_ pane: MainPane, _ title: String, count: Int? = nil) -> some View {
        SidebarRow(title: title, isSelected: model.mainPane == pane, count: count) {
            model.mainPane = pane
        }
    }

    private func sectionHeader(_ name: String, unavailable: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.4)
                .foregroundStyle(unavailable == nil ? Theme.faintText : Theme.warn)
            if let unavailable {
                Text(unavailable)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faintText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

/// Observes the ServerProcess itself — AppModel does not republish its children's state.
struct ServerRow: View {
    @ObservedObject var server: ServerProcess
    /// **radiusd is observed here, not read off the model** (build 23 — the owner's second
    /// correction, "ก็ต้องเป็นสีเทาสิ แต่ตอนนี้ไม่ใช่").
    ///
    /// `AppModel` does not republish its children's `@Published` state — the comment above
    /// this type has said so since build 18 about the *dot*. The locked hint was computed in
    /// `SidebarView.body` from `model.radius.isRunning`, which nothing in that body was
    /// watching, so the row was only rebuilt when some *other* property of the model happened
    /// to change. Between a start and the next such change the LDAP switch drew live and
    /// clickable over a running RADIUS; which change came next was a matter of timing, which
    /// is why it looked intermittent. Holding the process here makes the greying a
    /// consequence of radiusd's own state and not of the redraw budget.
    @ObservedObject private var radius = AppModel.shared.radius
    let name: String
    let detail: String
    let available: Bool
    /// The pair is moving: this server has been asked for and is not up yet (build 22). The
    /// switch shows as **on** with a spinner from that moment — "RADIUS on starts LDAP first"
    /// is only reassuring if it is visible while it happens.
    var starting = false
    /// This is the directory half of the pair, so it locks while radiusd runs. The RADIUS row
    /// itself is not paired with anything and leaves it false.
    var pairedWithRadius = false
    let start: () async -> Void
    /// Off. The LDAP row passes its own, which goes through `ServerPair`.
    var stop: (() async -> Void)?

    /// Why the switch cannot be flipped, or nil. Computed from the observed process, so it is
    /// true the moment radiusd is up and not one redraw later.
    private var lockedHint: String? {
        guard pairedWithRadius else { return nil }
        return ServerPair.directorySwitchLockedHint(radiusRunning: radius.isRunning)
    }

    var body: some View {
        SidebarServerRow(name: name, detail: detailLine, dot: dotColour,
                         running: ServerPair.directorySwitchIsOn(directoryRunning: server.isRunning,
                                                                 directoryStarting: starting),
                         available: available,
                         busy: starting,
                         lockedHint: lockedHint,
                         isOn: Binding(
                            get: { ServerPair.directorySwitchIsOn(directoryRunning: server.isRunning,
                                                                  directoryStarting: starting) },
                            set: { on in
                                Task {
                                    if on { await start() }
                                    else if let stop { await stop() }
                                    else { await server.stop() }
                                }
                            }))
    }

    private var detailLine: String {
        if starting { return "starting…" }
        return server.isRunning ? detail : statusWord
    }

    private var statusWord: String {
        if !available { return "unavailable" }
        if case .failed = server.state { return "failed" }
        return "off"
    }

    private var dotColour: Color {
        switch server.state {
        case .running: Theme.live
        case .failed: Theme.err
        case .stopped: Theme.faintText
        }
    }
}

/// The shape both server rows use: name and switch on one line, what it is doing under it.
struct SidebarServerRow: View {
    let name: String
    let detail: String
    let dot: Color
    let running: Bool
    let available: Bool
    let busy: Bool
    var lockedHint: String?
    @Binding var isOn: Bool

    /// Unavailable and locked look the same on purpose: in both the switch is not a control.
    private var isLocked: Bool { !available || lockedHint != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(name)
                    .font(.system(size: 13, weight: running ? .medium : .regular))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    // **Grey, and inert, and saying so** (build 23). `.disabled` alone was the
                    // whole of build 22 here, and a `.switch` toggle carrying an explicit
                    // `.tint` goes on drawing that tint while disabled: the locked LDAP
                    // switch came out a slightly paler green than the live one above it,
                    // which is the owner's "ก็ต้องเป็นสีเทาสิ แต่ตอนนี้ไม่ใช่". So the tint itself
                    // goes grey while it is locked. `allowsHitTesting(false)` is belt to
                    // `.disabled`'s braces; the row's name and detail keep their colours,
                    // because a switch that cannot be used still has to say what it is.
                    Toggle("", isOn: $isOn)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .tint(isLocked ? Theme.dimmedControl : Theme.accent)
                        .disabled(isLocked)
                        .allowsHitTesting(!isLocked)
                        .help(lockedHint ?? "")
                }
            }
            Text(detail)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(running ? Theme.ok : Theme.faintText)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 15)
            // Why the switch cannot be flipped is said **once, under the chooser** (build 23).
            // Build 22 put it here and `SidebarBackendChoice` put it there, and while RADIUS
            // runs both are locked for the same reason — so "Stop RADIUS first." appeared
            // twice, four lines apart, in a 212 pt column. It belongs on the last element of
            // the group, where it reads as a note on the whole of SERVERS rather than on one
            // row of it. The row keeps the sentence as its tooltip and, more to the point,
            // keeps the grey: a control nobody can touch has to *look* that way with or
            // without a caption.
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }
}

/// **OpenLDAP or Samba AD, under the LDAP switch** (build 21).
///
/// The same `settings.directoryBackend` Directory ▸ Server binds to, so the two controls are
/// one setting seen twice and can never disagree. Segmented rather than a popup: there are
/// exactly two answers and both fit, and a popup would hide the one that is not chosen behind
/// a click in a column that is 212 pt wide.
///
/// Disabled while either directory runs — both want 389 and 636, and switching underneath a
/// running server is how a lab ends up with two half-started directories. The one line saying
/// so appears only then, and is the same sentence the pane uses.
struct SidebarBackendChoice: View {
    @ObservedObject private var model = AppModel.shared
    /// The three processes, observed rather than reached through the model — the same build-23
    /// correction `ServerRow` carries, and here it was two bugs in one line: `model.ldap` and
    /// `model.ad` were not watched either, so the chooser could stay live over a directory it
    /// had just started.
    @ObservedObject private var radius = AppModel.shared.radius
    @ObservedObject private var ldap = AppModel.shared.ldap
    @ObservedObject private var ad = AppModel.shared.ad

    private var isRunning: Bool { ldap.isRunning || ad.isRunning }

    /// Locked while RADIUS runs as well (build 23): the directory under a running radiusd
    /// cannot be stopped from the switch above, so offering to swap it here would be an offer
    /// the app has to refuse.
    private var isLocked: Bool {
        !ServerPair.backendChooserEnabled(radiusRunning: radius.isRunning,
                                          directoryRunning: isRunning)
    }

    private var lockedHint: String? {
        ServerPair.backendChooserLockedHint(radiusRunning: radius.isRunning,
                                            directoryRunning: isRunning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Picker("", selection: $model.doc.settings.directoryBackend) {
                ForEach(DirectoryBackend.allCases, id: \.self) { backend in
                    Text(backend.label).tag(backend)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.mini)
            // The family accent, so the one control in the sidebar that carries a colour
            // carries the same one as the switches above it rather than the system blue.
            // Grey, not a faded accent — the same build-23 correction the switches carry.
            .tint(isLocked ? Theme.dimmedControl : Theme.accent)
            .disabled(isLocked)
            .allowsHitTesting(!isLocked)
            .help(lockedHint ?? "")
            if let lockedHint {
                Text(lockedHint)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faintText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 1)
        .padding(.bottom, 6)
    }
}

/// A pane row. No icon: the word is the row.
struct SidebarRow: View {
    let title: String
    var isSelected = false
    var count: Int?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Theme.text : Theme.text2)
            Spacer(minLength: 0)
            if let count {
                Text("\(count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.faintText)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Theme.selectedAccent : hovering ? Theme.hover : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
    }
}
