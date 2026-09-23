import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared pieces

/// A read-only value with a copy button. Everything in AD mode is something that gets pasted
/// into a device's form, so selecting it by hand is the failure mode to design out.
struct ADCopyField: View {
    let label: String
    let value: String
    var note: String?
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label)
                    .font(.system(size: prominent ? 12.5 : 12, weight: prominent ? .semibold : .regular))
                    .foregroundStyle(prominent ? Theme.text : Theme.dimText)
                    .frame(width: 170, alignment: .leading)
                Text(value)
                    .font(.system(size: prominent ? 18 : 11.5, weight: prominent ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(prominent ? Theme.accent : Theme.text2)
                    .textSelection(.enabled)
                CopyButton(value: value, iconSize: nil, help: "Copy \(value)")
                Spacer(minLength: 0)
            }
            if let note {
                Text(note)
                    .hint()
                    .padding(.leading, 180)
            }
        }
    }
}

/// The per-device table: a picker of profiles, then two columns — the label the device's own
/// form uses, and the value to paste there.
///
/// Used by both backends, because the problem is the same in both: the copy rows above answer
/// "what is the base DN", and this answers "which of the nine boxes on that page wants it".
struct DeviceProfileTable: View {
    let profiles: [DeviceProfile]
    /// Remembered per backend, so switching panes does not lose the selection.
    @State private var selection: String = ""

    private var chosen: DeviceProfile? {
        profiles.first { $0.id == selection } ?? profiles.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: Binding(get: { chosen?.id ?? "" }, set: { selection = $0 })) {
                ForEach(profiles) { profile in
                    Text(profile.short ?? profile.name).tag(profile.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if let profile = chosen {
                // The full product name, because the segment above is an abbreviation of it.
                Text(profile.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                Text(profile.location).hint()
                VStack(alignment: .leading, spacing: 0) {
                    header
                    ForEach(Array(profile.fields.enumerated()), id: \.offset) { index, field in
                        Divider().opacity(0.35)
                        row(field, alternate: index.isMultiple(of: 2))
                    }
                }
                .background(RoundedRectangle(cornerRadius: Metrics.field).fill(Theme.well))
                HStack(spacing: 8) {
                    CopyButton("Copy the whole table", value: tabSeparated(profile), bordered: true)
                        .controlSize(.small)
                    Spacer(minLength: 0)
                }
                if let caveat = profile.caveat {
                    Label(caveat, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(Theme.warn)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Field in the device")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.dimText)
                .frame(width: 250, alignment: .leading)
            Text("Value")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.dimText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func row(_ field: DeviceField, alternate: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(field.field)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text)
                    .frame(width: 250, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(field.value)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.text2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                CopyButton(value: field.value, iconSize: nil, help: "Copy \(field.value)")
                Spacer(minLength: 0)
            }
            if let note = field.note {
                Text(note).hint().padding(.leading, 260)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(alternate ? Color.clear : Theme.hover)
    }

    /// Tab-separated, so it lands in a spreadsheet or a ticket as two columns.
    private func tabSeparated(_ profile: DeviceProfile) -> String {
        ([profile.name, profile.location].joined(separator: " — "))
            + "\n" + profile.fields.map { "\($0.field)\t\($0.value)" }.joined(separator: "\n")
    }
}

/// The pass/fail rows a sync or a self-test produces.
struct ADResultRows: View {
    let lines: [ADResultLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines) { line in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon(line.outcome))
                        .font(.system(size: 11))
                        .foregroundStyle(colour(line.outcome))
                        .frame(width: 14)
                    Text(LogTime.clock(line.time))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.dimText)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(line.title)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.text2)
                            .textSelection(.enabled)
                        if !line.detail.isEmpty {
                            Text(line.detail).hint().textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func icon(_ outcome: ADResultLine.Outcome) -> String {
        switch outcome {
        case .ok: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .skipped: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        }
    }

    private func colour(_ outcome: ADResultLine.Outcome) -> Color {
        switch outcome {
        case .ok: Theme.ok
        case .failed: Theme.err
        case .skipped: Theme.warn
        case .info: Theme.dimText
        }
    }
}

private func adCard(_ title: String, help: String? = nil,
                    @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        CardTitle(title: title, help: help)
        content()
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .panelCard()
}

private func adField(_ label: String, @ViewBuilder content: () -> some View) -> some View {
    HStack(spacing: 10) {
        Text(label).foregroundStyle(Theme.dimText).frame(width: 170, alignment: .leading)
        content()
        Spacer(minLength: 0)
    }
}

// MARK: - Backend picker

/// The one switch that decides which directory runs. They are mutually exclusive because both
/// want 389 and 636 on the wildcard address — pretending otherwise would only produce a port
/// clash at the worst possible moment.
struct ADBackendCard: View {
    @ObservedObject private var model = AppModel.shared
    /// **The three processes, observed directly** (build 25, QA H-3). Build 23 held only
    /// `AppModel.shared` and then read `model.ldap.isRunning` / `model.ad.isRunning` out of
    /// it — `AppModel` does not republish its children, which is exactly the staleness
    /// `SidebarView` documents at length — so this card was rebuilt only when some other
    /// `@Published` happened to fire.
    @ObservedObject private var radius = AppModel.shared.radius
    @ObservedObject private var ldap = AppModel.shared.ldap
    @ObservedObject private var ad = AppModel.shared.ad

    private var directoryRunning: Bool { ldap.isRunning || ad.isRunning }

    var body: some View {
        adCard("LDAP directory", help: """
        OpenLDAP is a 16 MB process on this Mac and cannot be joined. Samba AD runs an Active \
        Directory domain controller in a Linux container — about 600–700 MB of RAM while it is \
        up — and a Windows PC or a NAC appliance can really join it.

        This is the same setting as the choice under the LDAP switch in the sidebar. The two \
        directories cannot run together: both want ports 389 and 636.
        """) {
            Picker("", selection: $model.doc.settings.directoryBackend) {
                ForEach(DirectoryBackend.allCases, id: \.self) { backend in
                    Text(backend.label).tag(backend)
                }
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
            // **One rule, not a second hand-rolled copy of it** (build 25, QA H-3). This card
            // omitted `radius.isRunning` altogether, so Directory ▸ Server let the backend be
            // changed while the sidebar's copy of the very same control was greyed out for
            // exactly that reason — and stopping the directory under a running radiusd is what
            // the lock is for.
            .disabled(!ServerPair.backendChooserEnabled(radiusRunning: radius.isRunning,
                                                        directoryRunning: directoryRunning))
            if let hint = ServerPair.backendChooserLockedHint(radiusRunning: radius.isRunning,
                                                              directoryRunning: directoryRunning) {
                Text(hint).hint()
            }
        }
    }
}

// MARK: - Directory ▸ Server, AD mode

struct ADServerSections: View {
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var ad = AppModel.shared.ad
    @State private var confirmRemove = false
    @State private var revealPassword = false
    @State private var changingPassword = false

    private var settings: ADSettings { model.doc.settings.ad }

    var body: some View {
        Group {
            prerequisites
            domain
            control
            selfTest
            dangerZone
        }
        .task {
            await ad.refreshPrerequisites()
            await ad.refreshDiskUsage()
        }
        // "Set password…" on the start refusal lands here (build 32).
        .onChange(of: model.requestADPasswordEntry, initial: true) { _, wanted in
            guard wanted else { return }
            model.requestADPasswordEntry = false
            changingPassword = true
        }
        .sheet(isPresented: $changingPassword) {
            ADPasswordChangeSheet(isRunning: ad.isRunning, realm: settings.realm) {
                changingPassword = false
            }
        }
    }

    /// The stored password, or dots — never the placeholder text of an editable field, because
    /// this one is not editable any more.
    private var passwordDisplay: String {
        let password = settings.administratorPassword
        if password.isEmpty { return "— not set —" }
        return revealPassword ? password : String(repeating: "•", count: min(password.count, 24))
    }

    // MARK: Prerequisites

    /// Build 32: installing `container` and building the image live on App ▸ Environment, with
    /// every other install. This card only says whether AD mode can start and where to go.
    private var prerequisites: some View {
        adCard("Prerequisites") {
            if model.tools.containerTool == nil {
                Text("Apple's container tool is not installed.").hint()
            } else if ad.imageKnownMissing {
                Text("The domain-controller image is not built yet.").hint()
            } else if ad.imageReference == nil {
                Text("The container system is stopped; the image is checked when it starts.").hint()
            } else {
                status("domain controller image",
                       ad.imageReference! + (ad.imageIsOutdated ? " — a build behind \(ADImage.reference)" : ""),
                       ok: !ad.imageIsOutdated)
            }
            HStack {
                Button("Open Environment") {
                    // Highlight only what is really missing — a built image is not a problem.
                    model.openEnvironment(for: model.tools.containerTool == nil ? .container
                                          : ad.imageKnownMissing ? .adImage : nil)
                }
                    .buttonStyle(.bordered).controlSize(.small)
                Spacer()
            }
        }
    }

    private func status(_ label: String, _ value: String, ok: Bool) -> some View {
        adStatus(label, value, ok: ok)
    }

    // MARK: Domain settings

    private var domain: some View {
        adCard("Domain", help: """
        The realm is what a device types into its “Domain” field. A .local realm is rejected: \
        macOS resolves .local through Bonjour, so a domain there can never be found.

        The Administrator password is set when the domain is first provisioned — changing it \
        here afterwards does not change it in the domain.

        Simple LDAP bind on means `ldap server require strong auth = no`, so ClearPass and \
        friends can bind with a username and password, including over unencrypted 389 where \
        that password crosses the LAN in the clear. Off is correct everywhere but a lab.

        A joined device points its DNS at this Mac, so the controller answers for the rest of \
        the internet too; names it does not own go to the forwarder.
        """) {
            // **The lab domain, not "the realm"** (build 24). It is the same stored value it
            // always was, but it is the OpenLDAP base DN as well now
            // (`LabSettings.labDomain`), so the field says what it really sets and the base DN
            // it implies is on the row under it. Locked while a directory runs, for the same
            // reason the OpenLDAP side is: renaming a live database is a restart's work.
            adField("Lab domain (realm)") {
                TextField("lab.sheep", text: $model.doc.settings.labDomain)
                    .valueControl(Metrics.sheetField)
                    .disabled(model.directoryIsLive)
            }
            adField("OpenLDAP base DN") {
                MonoValue(value: model.doc.settings.labDomainSuffix)
            }
            adField("NetBIOS name") {
                TextField("LABSHEEP", text: $model.doc.settings.ad.netbiosDomain).valueControl(Metrics.sheetField)
            }
            adField("Domain controller") {
                HStack(spacing: 6) {
                    TextField("dc1", text: $model.doc.settings.ad.dcHostname).frame(width: 110)
                    Text(".\(settings.realm)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.faintText)
                }
            }
            // **Read-only, with one button** (owner request, build 17). Typing into this field
            // used to change the *setting* only: on a running domain the controller kept the
            // password it already had, and the two could disagree for days before a device
            // failed to join and said nothing useful about why. Change… sets both together.
            adField("Administrator password") {
                HStack(spacing: 6) {
                    Text(passwordDisplay)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(settings.administratorPassword.isEmpty ? Theme.faintText : Theme.text2)
                        .textSelection(.enabled)
                        .valueControl(Metrics.sheetField)
                    Button { revealPassword.toggle() } label: {
                        Image(systemName: revealPassword ? "eye.slash" : "eye").font(.system(size: 10))
                    }
                    .buttonStyle(.borderless).foregroundStyle(Theme.dimText)
                    .disabled(settings.administratorPassword.isEmpty)
                    Button("Change…") { changingPassword = true }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(ad.settingPassword)
                    if ad.settingPassword { ProgressView().controlSize(.small) }
                }
            }
            Text(ad.isRunning
                 ? "Change… sets it in the domain and in these settings together."
                 : "The domain controller is not running — this is the password the domain will be provisioned with.")
                .hint()

            Divider().opacity(0.5).padding(.vertical, 2)

            Toggle("Allow simple LDAP bind (lab NAC compatibility)", isOn: $model.doc.settings.ad.allowSimpleBind)

            adField("DNS forwarder") {
                TextField("1.1.1.1", text: $model.doc.settings.ad.dnsForwarder).valueControl(Metrics.sheetField)
            }
            adField("Container size") {
                HStack(spacing: 8) {
                    TextField("", value: $model.doc.settings.ad.memoryMB, format: .number.grouping(.never)).valueNumber(70)
                    Text("MB ·").foregroundStyle(Theme.faintText)
                    TextField("", value: $model.doc.settings.ad.cpus, format: .number.grouping(.never)).valueNumber(70)
                    Text("CPUs").foregroundStyle(Theme.faintText)
                }
            }
        }
    }

    // MARK: Control

    private var control: some View {
        adCard("Domain controller") {
            HStack(spacing: 10) {
                Circle().fill(dotColour).frame(width: 9, height: 9)
                Text(stateText).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text2)
                Spacer()
                if ad.state.isBusy || ad.syncing { ProgressView().controlSize(.small) }
                Button(ad.isRunning ? "Stop" : "Start") {
                    Task { ad.isRunning ? await model.stopAD() : await model.startAD() }
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                // Not disabled for a settings problem (build 32): a greyed Start said nothing,
                // and the press now says what is missing and where it is set.
                .disabled(ad.state.isBusy)
                // **No Sync now from build 17.** The domain is the original: the Users, Groups
                // and tree panes edit it directly and each edit has already landed by the time
                // it is drawn. Refresh, in those panes, is the only button left — and it re-reads
                // rather than writes.
            }
            .controlSize(.small)
            if case .failed(let why) = ad.state {
                Text(why).font(.system(size: 11.5)).foregroundStyle(Theme.err).textSelection(.enabled)
            }
            if !ad.selfHeldPorts.isEmpty { selfHeldPortsNotice }
            if ad.adoptedDomain { adoptedNotice }
            if ad.isRunning {
                ADCopyField(label: "Base DN", value: settings.baseDN)
                ADCopyField(label: "LDAP", value: "ldap://\(ad.hostIP):389")
                ADCopyField(label: "LDAPS", value: "ldaps://\(ad.hostIP):636")
                ADCopyField(label: "Global catalog", value: "ldap://\(ad.hostIP):3268")
                Text("DNS relay on 0.0.0.0:53 → \(ad.containerIP ?? "—").").hint()
            }
        }
    }

    /// "This app is in its own way" — the one port conflict a person cannot act on from the
    /// outside, because the process named in the message is the one showing the message.
    private var selfHeldPortsNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(ad.selfHeldPorts.joined(separator: ", ")) \(ad.selfHeldPorts.count == 1 ? "is" : "are") held by this app.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.warn)
            Text("Nothing outside SheepRadius is in the way.").hint()
            HStack(spacing: 8) {
                Button("Release and retry") {
                    ad.releaseOwnPorts()
                    Task { await model.startAD() }
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.field).fill(Theme.well))
    }

    /// Shown whenever the running domain came off an existing state volume.
    ///
    /// The distinction the owner lost an afternoon to: `ADSettings.administratorPassword` is
    /// only ever *used* when a domain is provisioned. On an adopted volume the domain already
    /// has a password, editing this field changes nothing in it, and the app's own sync keeps
    /// working — because it runs as root inside the DC and never binds. The first thing that
    /// notices is a device, or the self-test.
    private var adoptedNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("This domain already exists — it was adopted from the volume \(ad.volumeName), not created here.",
                      systemImage: "info.circle")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                HelpDot(text: """
                The Administrator password has to be the domain's current one. The field in \
                Domain is only read when a domain is provisioned, so editing it changes nothing \
                in the domain — and a sync will not complain either, because it runs inside the \
                controller and never authenticates. Only the things that really bind (a device \
                joining, a NAC, the self-test's kinit / LDAP bind / SMB / DNS-zone checks) \
                reject it.
                """)
                Spacer(minLength: 0)
            }
            if let step = ad.passwordRejected { passwordMismatch(step) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.field).fill(Theme.well))
    }

    /// The offer, and only after something has actually been refused.
    private func passwordMismatch(_ step: ADBindStep) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.5)
            Label("\(step.label) failed: the password does not match the adopted domain.",
                  systemImage: "xmark.circle.fill")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.err)
            HStack(spacing: 8) {
                Button("Set the domain's Administrator password to the one in Settings") {
                    Task { await ad.setDomainAdministratorPassword(model.applied.settings.ad) }
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .disabled(ad.settingPassword || ad.testing || model.applied.settings.ad.administratorPassword.isEmpty)
                if ad.settingPassword { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            Text("Everything that knew the old password has to be updated afterwards.").hint()
        }
    }

    private var dotColour: Color {
        switch ad.state {
        case .running: Theme.live
        case .failed: Theme.err
        case .starting: Theme.warn
        case .stopped: Theme.faintText
        }
    }

    private var stateText: String {
        switch ad.state {
        case .running: "running · \(settings.dcFQDN) at \(ad.hostIP)"
        case .starting(let step): step
        case .failed: "failed"
        case .stopped: "stopped"
        }
    }

    // MARK: (gone in build 17) Collisions and the sync log
    //
    // Both cards belonged to the reconcile model: "this name exists outside OU=SheepRadius,
    // adopt it?" is a question only something copying a table into a domain has to ask. With
    // the domain as the original there is nothing to reconcile — a name that is taken is
    // refused as it is typed (`DirectoryNames.problem`) and the objects AD owns are shown,
    // greyed, in the tree. `ADController.sync` and `ADPlan` are still there and still tested;
    // nothing in the UI calls them.

    // MARK: Self-test

    private var selfTest: some View {
        adCard("AD self-test", help: """
        The same checks that were done by hand for the first real join, in the same order: the \
        ten DNS names a client looks up, DNS over TCP, a CLDAP netlogon ping on udp/389 (which \
        is how Windows *chooses* a domain controller — TCP 389 being open says nothing about \
        it), every port a join opens, a Kerberos ticket, an LDAP simple bind, and the SMB \
        share list.
        """) {
            HStack(spacing: 10) {
                Button("Run AD self-test") { Task { await ad.runSelfTest(settings) } }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(!ad.isRunning || ad.testing)
                if ad.testing { ProgressView().controlSize(.small) }
                Spacer()
            }
            .controlSize(.small)
            if ad.checks.isEmpty {
            } else {
                ADResultRows(lines: ad.checks)
            }
            // The four checks that authenticate are the only ones a wrong password can break,
            // and this is where a person is standing when one of them does.
            if let step = ad.passwordRejected {
                VStack(alignment: .leading, spacing: 6) { passwordMismatch(step) }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Metrics.field).fill(Theme.well))
            }
        }
    }

    // MARK: Danger zone

    private var dangerZone: some View {
        adCard("Remove AD components") {
            Text("The state volume holds the domain — every joined computer has to rejoin.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.warn)
            HStack {
                Button("Remove AD components…", role: .destructive) { confirmRemove = true }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(model.tools.containerTool == nil)
                Spacer()
            }
        }
        .confirmationDialog("Remove the container, the state volume and the image?",
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    // The volume **is** the domain — its SID, its computer accounts, its
                    // passwords. This is the most destructive button in the app, so the
                    // automatic backup happens here and is not a checkbox.
                    if let problem = await model.backupNow(.beforeRebuild) { model.report(problem) }
                    await ad.removeComponents()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The domain \(settings.realm), its users and every joined computer's machine account are destroyed. This cannot be undone.")
        }
    }
}

// MARK: - Samba AD prerequisites (App ▸ Environment)

/// Installing `container`, building / importing / exporting the DC image. Lived on Directory ▸
/// Server until build 32; it is on Environment now with every other install.
struct ADPrerequisitesCard: View {
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var ad = AppModel.shared.ad

    var body: some View {
        adCard("Prerequisites", help: """
        Apple's `container` tool is the one part of this app that cannot be bundled: it ships a \
        Linux kernel and installs a launchd agent of its own.

        Building the image takes a couple of minutes and pulls Debian's arm64 base image and \
        Samba's packages. The platform is pinned to linux/arm64: without that pin the base \
        image is pulled for every architecture in its index, which cost 19.9 GB once.

        Rebuilding never touches a running domain controller or the state volume — stop and \
        start AD mode for a new image to take effect. Export writes a ~100 MB tar for a second \
        Mac, which still needs `container` and its kernel.
        """) {
            if model.tools.containerTool == nil {
                Text("Apple's container tool is not installed.").hint()
                if model.tools.brew != nil {
                    ADStreamedCommand(title: "Install container with Homebrew",
                                      run: { model.installWithHomebrew(["container"]) },
                                      process: model.installer)
                } else {
                    HStack(spacing: 8) {
                        CopyButton("Copy install command", value: "brew install container",
                                   bordered: true)
                        Button("Open Terminal") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                }
            } else {
                status("container tool", model.tools.containerTool ?? "", ok: true)
                status("container system", ad.systemRunning ? "running" : "not running (started automatically)", ok: true)
                status("domain controller image",
                       (ad.imageReference ?? "not built") + (ad.imageIsOutdated ? " — a build behind \(ADImage.reference)" : ""),
                       ok: ad.imageReference != nil && !ad.imageIsOutdated)
                status("state volume", ad.volumeExists ? "\(ad.volumeName) — adopted, never reprovisioned" : "not created yet", ok: true)
                // An image built from an older Containerfile is an offer, never a refusal: the
                // running domain controller goes on serving, and a rebuild changes nothing in
                // the state volume. The one thing it cannot do is change a DC that is already
                // up — which is why the sentence says so out loud.
                if let reason = ad.imageRebuildReason { Text(reason).hint() }
                if !ad.diskUsage.isEmpty { Text(ad.diskUsage).hint() }

                if ad.imageReference == nil || ad.builder.isRunning || !ad.builder.log.isEmpty {
                    ADStreamedCommand(title: ad.imageReference == nil ? "Build image" : "Rebuild image",
                                      run: {
                                          Task {
                                              await ad.startBuilder()
                                              ad.buildImage(context: ADImage.bundledContext)
                                          }
                                      },
                                      process: ad.builder)
                    Text("Builds \(ADImage.reference) — a couple of minutes.").hint()
                } else {
                    HStack(spacing: 8) {
                        // **Not** disabled while the DC is running. A rebuild writes a new tag
                        // and leaves the image the running container was created from alone, so
                        // there is nothing here that a live domain can be hurt by — and telling
                        // the owner of a running domain to stop it before he can even build the
                        // fix is how a one-button upgrade becomes an outage.
                        let rebuild = Button(ad.imageIsOutdated ? "Rebuild image (\(ADImage.reference))" : "Rebuild image") {
                            Task {
                                await ad.startBuilder()
                                ad.buildImage(context: ADImage.bundledContext)
                            }
                        }
                        if ad.imageIsOutdated {
                            rebuild.buttonStyle(.borderedProminent)
                        } else {
                            rebuild.buttonStyle(.bordered)
                        }
                        Group {
                            Button("Export image…") { exportImage() }.buttonStyle(.bordered)
                            Button("Import image…") { importImage() }.buttonStyle(.bordered)
                        }
                        .disabled(ad.isRunning)
                        Spacer()
                    }
                    .controlSize(.small)

                }
            }
        }
    }

    private func status(_ label: String, _ value: String, ok: Bool) -> some View {
        adStatus(label, value, ok: ok)
    }

    private func exportImage() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(ADImage.repository)-\(ADImage.tag).tar"
        panel.allowedContentTypes = [UTType(filenameExtension: "tar") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await ad.exportImage(to: url) }
    }

    private func importImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "tar") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await ad.importImage(from: url) }
    }
}

private func adStatus(_ label: String, _ value: String, ok: Bool) -> some View {
    adField(label) {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(ok ? Theme.ok : Theme.warn)
            Text(value)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.text2)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

/// The streamed-output card the Homebrew installer uses, reused for `container build`.
struct ADStreamedCommand: View {
    let title: String
    let run: () -> Void
    @ObservedObject var process: ServerProcess

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(title, action: run)
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(process.isRunning)
                if process.isRunning {
                    ProgressView().controlSize(.small)
                    Text("This takes a few minutes.").hint()
                }
                Spacer()
            }
            .controlSize(.small)
            if !process.log.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(process.log) { line in
                                Text(line.text)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.text2)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                            }
                        }
                        .padding(8)
                    }
                    .frame(height: 150)
                    .background(RoundedRectangle(cornerRadius: Metrics.field).fill(Theme.well))
                    .onChange(of: process.log.count) {
                        if let last = process.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }
}

// MARK: - Device settings, AD mode

/// What to type on the device, in the order the first real join proved matters.
///
/// The ordering is the content. A Windows 11 notebook failed to join twice: once because the
/// controller's name was typed into the Domain field, and once because the adapter was still
/// using the router's DNS. So the domain name comes first and largest, the controller is a
/// separate row that says what it is *not* for, and DNS comes before anything else.
struct ADDeviceSections: View {
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var ad = AppModel.shared.ad

    private var settings: ADSettings { model.doc.settings.ad }
    /// What the tables are built from. The **applied** settings, because they describe a domain
    /// that is actually running under those names — the edit boxes on Directory ▸ Server can
    /// say anything until Apply.
    private var appliedSettings: ADSettings { model.applied.settings.ad }
    private var address: String { ad.isRunning ? ad.hostIP : model.primaryAddress }

    var body: some View {
        Group {
            identity
            dns
            credentials
            directory
            perDeviceTables
            cheatSheets
        }
    }

    private var perDeviceTables: some View {
        adCard("Field names by product") {
            // The build-17 "there are unapplied user/group/OU edits" warning went in build 21:
            // those three are the read-only seed now, so the condition could never be true.
            // An unapplied *domain setting* still shows through the ordinary ApplyBar.
            DeviceProfileTable(profiles: DeviceProfiles.activeDirectory(
                settings: appliedSettings, address: address,
                caPath: model.tools.openssl == nil ? nil : model.env.caPEM.path))
        }
    }

    private var identity: some View {
        adCard("The two names, and which is which") {
            ADCopyField(label: "Domain to join", value: settings.realm, prominent: true)
            Divider().opacity(0.5).padding(.vertical, 4)
            ADCopyField(label: "Domain controller", value: "\(settings.dcFQDN) (\(address))",
                        note: "NOT the domain name — ClearPass's join form wants this one, Windows never does.")
        }
    }

    private var dns: some View {
        adCard("Point the device's DNS here first", help: """
        Do this before anything else. A device still using the router's DNS cannot resolve \
        \(settings.realm) at all, and the error it shows never mentions DNS. Remove the \
        alternate DNS server as well — one lookup going to the router is enough to break \
        discovery — and watch for an IPv6 DNS server the router hands out separately, which \
        silently wins over IPv4.
        """) {
            ADCopyField(label: "DNS server", value: address, prominent: true)
            Divider().opacity(0.5).padding(.vertical, 4)
            Text("Then check it from the device:").hint()
            ForEach(ADDeviceGuide.verificationCommands(realm: settings.realm), id: \.label) { item in
                ADCopyField(label: item.label, value: item.command)
            }
            Text("Both must answer, or DNS is the problem.").hint()
        }
    }

    private var credentials: some View {
        adCard("Join account") {
            ADCopyField(label: "Username", value: "Administrator")
            ADCopyField(label: "Password", value: settings.administratorPassword.isEmpty ? "— not set —" : settings.administratorPassword)
            ADCopyField(label: "Or, as a UPN", value: "Administrator@\(settings.realm)")
            // verbatim: Text(_:) parses Markdown, which swallows the backslash in DOMAIN\\user.
            Text(verbatim: "Test users sign in as \(settings.netbiosDomain)\\<username>.").hint()
        }
    }

    private var directory: some View {
        adCard("Directory details (for a NAC's LDAP source)") {
            ADCopyField(label: "NetBIOS name", value: settings.netbiosDomain)
            ADCopyField(label: "Base DN", value: settings.baseDN)
            ADCopyField(label: "Managed OU", value: settings.managedRootDN,
                        note: "Where this app's users, groups and OUs live. Anything outside it — the built-in containers, machine accounts, objects made by hand — is never modified or deleted by a sync.")
            ADCopyField(label: "LDAP", value: "ldap://\(address):389")
            ADCopyField(label: "LDAPS", value: "ldaps://\(address):636")
            ADCopyField(label: "Global catalog", value: "ldap://\(address):3268")
            ADCopyField(label: "GC over TLS", value: "ldaps://\(address):3269")
            ADCopyField(label: "User filter", value: "(sAMAccountName=%s)")
            ADCopyField(label: "Bind DN", value: "Administrator@\(settings.realm)")
            if model.tools.openssl != nil {
                ADCopyField(label: "CA to import on the device", value: model.env.caPEM.path,
                            note: "The domain controller's certificate is issued by this lab's own test CA — the same one RADIUS uses, so a device that already trusts this lab needs nothing new.")
            }
            if settings.allowSimpleBind {
                Text("A plain bind sends that password across the LAN in the clear.").hint()
            }
        }
    }

    private var cheatSheets: some View {
        adCard("Per-device steps") {
            ForEach(ADDeviceGuide.sheets(settings: settings, hostIP: address)) { sheet in
                VStack(alignment: .leading, spacing: 5) {
                    Text(sheet.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                    ForEach(Array(sheet.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1).")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.faintText)
                                .frame(width: 16, alignment: .trailing)
                            Text(step).font(.system(size: 11.5)).foregroundStyle(Theme.text2).textSelection(.enabled)
                        }
                    }
                    if let caveat = sheet.caveat {
                        Label(caveat, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundStyle(Theme.warn)
                    }
                }
                .padding(.bottom, 8)
            }
            Divider().opacity(0.5)
            // Build 22: this said iMaster had not been tested against the domain, which stopped
            // being true on 18 Sep 2026 — three nodes of a real cluster joined it and the
            // AD/LDAP Synchronization connection test passed. ClearPass is still the untested
            // one, and the OU-based sync is still the part nobody has watched to the end.
            Label("A Windows 11 Pro notebook has joined this domain over the LAN and logged in as a domain user, and a three-node iMaster NCE-Campus cluster joined it on 18 Sep 2026 with its AD/LDAP Synchronization connection test passing. The user list after an OU-based synchronisation has not been watched through, and ClearPass has not been tested against this domain at all — its LDAP side is proven, its Join AD Domain button is not.",
                  systemImage: "checkmark.seal")
                .font(.system(size: 11)).foregroundStyle(Theme.dimText)
        }
    }
}

/// The sidebar row, in the shape `ServerRow` uses. It observes the controller directly for
/// the same reason `ServerRow` observes its `ServerProcess`: `AppModel` does not republish its
/// children, so a row bound only to the model would show a stale dot.
/// The LDAP row in Samba AD mode. Same shape and the same name as the OpenLDAP one: which of
/// the two is selected is the control under the row, not the name of it (build 21, §18).
struct ADServerRow: View {
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var ad = AppModel.shared.ad
    /// Observed, for the same reason `ServerRow` observes it (build 23): `model.radius` is not
    /// republished by `AppModel`, so a hint computed from it in a body that watches only the
    /// model is a value nobody is watching, and the switch stayed live over a running RADIUS.
    @ObservedObject private var radius = AppModel.shared.radius

    var body: some View {
        SidebarServerRow(name: "LDAP", detail: detail, dot: dotColour,
                         running: ad.isRunning,
                         available: model.tools.containerTool != nil,
                         busy: ad.state.isBusy,
                         lockedHint: ServerPair.directorySwitchLockedHint(
                            radiusRunning: radius.isRunning),
                         onUnavailable: { model.openEnvironment(for: .container) },
                         isOn: Binding(
                            get: { ServerPair.directorySwitchIsOn(directoryRunning: ad.isRunning,
                                                                  directoryStarting: model.directoryStarting) },
                            set: { on in
                                Task {
                                    on ? await model.startAD() : await model.stopDirectoryFromSwitch()
                                }
                            }))
    }

    private var detail: String {
        switch ad.state {
        case .running: model.applied.settings.ad.realm
        case .starting(let step): step
        case .failed: "failed"
        case .stopped: model.tools.containerTool == nil ? "not installed" : "off"
        }
    }

    private var dotColour: Color {
        switch ad.state {
        case .running: Theme.live
        case .starting: Theme.warn
        case .failed: Theme.err
        case .stopped: Theme.faintText
        }
    }
}
