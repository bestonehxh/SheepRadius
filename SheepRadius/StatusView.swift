import SwiftUI

/// Status, build 18 (PROJECT-STATUS §15): **four tiles, the addresses, the authentications**.
///
/// Build 17 answered "is it up?" with two tall cards of monospaced lines, and the thing a
/// person actually came for — the address to type into a switch — was below them. The tiles say
/// the state in one glance each, the addresses are a copyable key–value group, and the feed is a
/// real table so Time / Result / User / Method line up down the column.
struct StatusView: View {
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var ad = AppModel.shared.ad
    /// getifaddrs is a syscall — resolve once per appearance, not per body render.
    ///
    /// **Empty, not `LocalNetwork.allIPv4()`.** A `@State` default is evaluated every time the
    /// `View` *struct* is initialised and SwiftUI then throws all but the first away — and
    /// `ContentView` rebuilds this struct on every body pass, which under a flood is ten times
    /// a second. So the old default ran getifaddrs plus a getnameinfo per interface, on the
    /// main actor, ten times a second, and discarded the answer. `onAppear` and the
    /// `onChange` below already keep this current.
    @State private var addresses: [(name: String, ip: String)] = []

    var body: some View {
        PaneBody {
            header
            if !model.tools.radiusReady || !model.tools.ldapReady { missingTools }
            tiles
            // Build 21's "LDAP is off, so RADIUS rejects every login" notice is gone:
            // build 22 made the two switches a pair, so that state is not reachable from
            // the UI at all — stopping LDAP under a running radiusd stops both.
            if let change = model.addressChange { addressChange(change) }
            addressGroup
            authentications
        }
        .onAppear { addresses = LocalNetwork.allIPv4() }
        // The list above is a snapshot, so without this it keeps showing the address the Mac
        // had when the pane opened — right next to a card saying it changed.
        .onChange(of: model.primaryAddress) { addresses = LocalNetwork.allIPv4() }
    }

    /// **The heading says whether the lab is up** (build 26, the owner-approved mock).
    ///
    /// Build 25 answered that with a tile: "RADIUS — Running", "LDAP — Running", and the
    /// person had to read two of them and combine the answer themselves. The words are
    /// `PaneHeadline.status`, which is pure and is what the unit suite pins, so the four
    /// combinations cannot each grow a sentence of their own in a different file.
    private var header: some View {
        PaneHeader(eyebrow: "Lab",
                   heading: PaneHeadline.status(labDomain: model.applied.settings.labDomain,
                                                radiusRunning: model.radius.isRunning,
                                                directoryRunning: directoryIsUp),
                   subtitle: PaneHeadline.statusSubtitle(directoryLabel: model.directoryLabel,
                                                         address: model.primaryAddress,
                                                         accepted: today.accepted,
                                                         rejected: today.rejected)) {
            if model.busy { ProgressView().controlSize(.small) }
            Button("Stop all") { Task { await model.stopAll() } }
                .buttonStyle(.bordered)
            Button("Start all") { Task { await model.startAll() } }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
        }
    }

    /// Whichever directory the lab is configured for.
    private var directoryIsUp: Bool {
        model.applied.settings.directoryBackend == .activeDirectory ? ad.isRunning : model.ldap.isRunning
    }

    // MARK: Tiles

    /// **Four readouts in one panel, not four cards** (build 26, QA M-4).
    ///
    /// The complaint was that a bordered, tinted card with a value in it and no gesture reads
    /// as a control — "RADIUS · Stopped" invited a click that did nothing, four times over.
    /// Either they start the thing they name or they stop looking like buttons, and starting
    /// servers from four places is not what this pane is for: **Start all** is eight points
    /// away in the heading and the sidebar's switches are the real control.
    ///
    /// So they are one panel divided by hairlines, the same shape as every other group in the
    /// app. The numbers, the captions and the accent on a running server are unchanged — what
    /// went is the four separate raised surfaces.
    private var tiles: some View {
        HStack(spacing: 0) {
            readout(caption: "RADIUS", value: radiusState.0, tint: radiusState.1,
                    detail: model.radius.isRunning
                    ? "auth \(model.applied.settings.authPort) · acct \(model.applied.settings.acctPort)"
                    : model.tools.radiusReady ? "not running" : "FreeRADIUS not found")
            readoutDivider
            readout(caption: directoryCaption, value: directoryState.0, tint: directoryState.1,
                    detail: directoryDetail)
            readoutDivider
            readout(caption: "Authentications today", value: "\(today.total)", tint: Theme.text,
                    detail: today.total == 0 ? "none yet"
                    : "\(today.accepted) accepted · \(today.rejected) rejected")
            readoutDivider
            readout(caption: "This Mac", value: model.primaryAddress, tint: Theme.text, mono: true,
                    detail: addresses.first(where: { $0.ip == model.primaryAddress })?.name
                    ?? "\(addresses.count) address(es)")
        }
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Metrics.card).fill(Theme.panel))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.card))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.card).strokeBorder(Theme.hairline, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private var readoutDivider: some View {
        Rectangle().fill(Theme.hairlineSoft).frame(width: 0.5).padding(.vertical, 10)
    }

    private func readout(caption: String, value: String, tint: Color,
                         mono: Bool = false, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.faintText)
                .lineLimit(1)
            Text(value)
                .font(.system(size: mono ? 16 : 19, weight: .semibold,
                              design: mono ? .monospaced : .default))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .textSelection(.enabled)
            Text(detail.isEmpty ? " " : detail)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.dimText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // A readout, said so: VoiceOver reads it as text and nothing offers to be pressed.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }

    /// "LDAP" is what the sidebar's switch is called, and on a domain the backend has a name.
    private var directoryCaption: String {
        model.applied.settings.directoryBackend == .activeDirectory ? "LDAP · Samba AD" : "LDAP · OpenLDAP"
    }

    private var radiusState: (String, Color) {
        switch model.radius.state {
        case .running: ("Running", Theme.ok)
        case .failed: ("Failed", Theme.err)
        case .stopped: ("Stopped", Theme.dimText)
        }
    }

    private var directoryState: (String, Color) {
        if model.applied.settings.directoryBackend == .activeDirectory {
            switch ad.state {
            case .running: return ("Running", Theme.ok)
            case .starting: return ("Starting", Theme.warn)
            case .failed: return ("Failed", Theme.err)
            case .stopped: return ("Stopped", Theme.dimText)
            }
        }
        switch model.ldap.state {
        case .running: return ("Running", Theme.ok)
        case .failed: return ("Failed", Theme.err)
        case .stopped: return ("Stopped", Theme.dimText)
        }
    }

    private var directoryDetail: String {
        if model.applied.settings.directoryBackend == .activeDirectory {
            guard ad.isRunning else { return model.applied.settings.ad.realm }
            let joined = ad.computers.count
            return "\(model.applied.settings.ad.dcFQDN) · \(joined) joined"
        }
        return model.ldap.isRunning
            ? model.applied.settings.listenerSummary
            : model.applied.settings.ldapSuffix
    }

    /// Only the listeners that are actually configured, as URLs a device's form will take.
    private var directoryURLs: String {
        let settings = model.applied.settings
        var out: [String] = []
        if settings.ldapPlainEnabled { out.append("ldap://\(model.primaryAddress):\(settings.ldapPort)") }
        if settings.ldapsEnabled { out.append("ldaps://\(model.primaryAddress):\(settings.ldapsPort)") }
        return out.isEmpty ? "no listener is switched on" : out.joined(separator: "  ·  ")
    }

    /// Accepts and rejects since midnight, this Mac's clock — the same clock `LogTime` prints.
    private var today: (total: Int, accepted: Int, rejected: Int) {
        let midnight = Calendar.current.startOfDay(for: Date())
        var accepted = 0
        var rejected = 0
        for event in model.events where event.time >= midnight {
            if event.accepted { accepted += event.repeats } else { rejected += event.repeats }
        }
        return (accepted + rejected, accepted, rejected)
    }

    // MARK: Addresses

    /// The addresses to configure on a NAS or a directory client.
    ///
    /// Named for the **service**, not for the gesture: a network engineer configuring a switch,
    /// an access point or a NAC is looking for the field called "RADIUS server address" or
    /// "LDAP server address" on the other device, and the group should say the same words.
    /// (Build 21 renamed the second from "Directory server address" — the app calls the thing
    /// LDAP everywhere now, and so does iMaster's own form.)
    private var addressGroup: some View {
        PaneSection("Enter on devices", note: "copies exactly what the form wants") {
            GroupedList {
                if addresses.isEmpty {
                    NoteRow(text: "No network interface with an IPv4 address.",
                            systemImage: "exclamationmark.triangle", tint: Theme.warn)
                }
                FactRow(key: "RADIUS server",
                        value: "\(model.primaryAddress):\(model.applied.settings.authPort)",
                        help: """
                        RADIUS identifies a client by the source IP of its packets. On a \
                        multi-VLAN switch that is the interface it routes out of (or its \
                        configured `ip radius source-interface`), not necessarily its \
                        management IP. A request from an unlisted IP is dropped without a \
                        reply and shows up in the Log as \u{201C}Ignoring request … from \
                        unknown client\u{201D}.
                        """, keyWidth: 190)
                if model.applied.settings.directoryBackend == .activeDirectory {
                    FactRow(key: "LDAP server", value: "ldap://\(model.primaryAddress):389",
                            keyWidth: 190)
                    // **New in build 26** (the owner-approved mock): the two rows a person
                    // joining a machine or pointing a NAC at the domain had to go and find
                    // under Directory ▸ Devices.
                    FactRow(key: "Domain / NetBIOS",
                            value: "\(model.applied.settings.ad.realm) / \(model.applied.settings.ad.netbiosDomain)",
                            keyWidth: 190)
                    FactRow(key: "DNS for domain join", value: model.primaryAddress, keyWidth: 190)
                    FactRow(key: "Administrator", value: model.applied.settings.ldapAdminDN,
                            keyWidth: 190)
                } else {
                    FactRow(key: "LDAP server", value: directoryURLs, keyWidth: 190)
                    FactRow(key: "Domain / base DN",
                            value: "\(model.applied.settings.labDomain) / \(model.applied.settings.ldapSuffix)",
                            keyWidth: 190)
                    FactRow(key: "Administrator", value: model.applied.settings.ldapAdminDN,
                            keyWidth: 190)
                }
                if addresses.count > 1 {
                    FactRow(key: "Other addresses on this Mac",
                            value: addresses.filter { $0.ip != model.primaryAddress }
                                .map { "\($0.ip) (\($0.name))" }.joined(separator: "  "),
                            copyable: false, keyWidth: 190)
                }
                NoteRow(text: model.applied.clients.isEmpty
                        ? "No NAS clients are configured — RADIUS accepts requests from 127.0.0.1 only."
                        : "RADIUS accepts requests from \(model.applied.clients.count) NAS client(s) and 127.0.0.1.")
            }
        }
    }

    /// "This Mac's address changed from A to B."
    ///
    /// Nothing else in the lab notices. Every device was pointed at the old address **by hand**
    /// — a notebook's DNS server, iMaster's *Primary server address*, a NAS entry under
    /// Clients — and they all simply stop working, each with an error that blames something
    /// else. Kept until it is dismissed rather than fading, because the retyping it asks for
    /// happens on other machines and may take a while.
    private func addressChange(_ change: AddressChange) -> some View {
        PaneGroup("This Mac's address changed", help: """
        A device's DNS server, iMaster's Primary server address, a NAS entry under Clients, and \
        any LDAP or RADIUS server address typed into a switch, AP or firewall. Directory ▸ \
        Devices already shows the new address.

        In AD mode the domain's own DNS records are re-pointed automatically while the \
        controller runs — a machine account and its keytab do not depend on the address. \
        Devices pointed at the old one are not.
        """, accessory: Button("Dismiss") { model.dismissAddressChange() }.buttonStyle(.bordered)) {
            PlainRow {
                Text(change.from)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.dimText)
                    .strikethrough()
                    .textSelection(.enabled)
                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Theme.faintText)
                Text(change.to)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                    .textSelection(.enabled)
                Text(LogTime.clock(change.at))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.faintText)
                Spacer(minLength: 0)
            }
            NoteRow(text: "Every NAS, supplicant and directory client configured with \(change.from) must be reconfigured.",
                    systemImage: "exclamationmark.triangle.fill", tint: Theme.warn)
        }
    }

    // MARK: Recent authentications

    private var authentications: some View {
        PaneSection(title: "Recent authentications", note: "last 40 · Log has everything", accessory: {
            if !model.events.isEmpty {
                Button("Clear") { model.clearEvents() }.buttonStyle(.bordered)
            }
        }, content: {
            Table(Array(model.events.prefix(40))) {
                TableColumn("Time") { event in
                    // `LogTime.clock`, not `.dateTime`: the Log pane's lines and this column
                    // are read together, so they use one renderer — and a system format on a
                    // Thai-locale Mac is free to print Thai digits here.
                    Text(LogTime.clock(event.time))
                        .font(.system(size: 11.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Theme.dimText)
                }
                .width(min: 66, ideal: 70, max: 80)
                TableColumn("Result") { event in
                    StatusPill(text: event.accepted ? "Accept" : "Reject",
                               kind: event.accepted ? .ok : .bad)
                }
                .width(min: 62, ideal: 66, max: 76)
                TableColumn("User") { event in
                    Text(event.username)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .width(min: 90, ideal: 130, max: 220)
                TableColumn("Method") { event in
                    Text(event.detail.isEmpty ? "—" : event.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                        .help(event.detail)
                }
                .width(min: 110, ideal: 200, max: 360)
                TableColumn("Via") { event in
                    Text(event.client)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.dimText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .width(min: 80, ideal: 120, max: 200)
                TableColumn("Source") { event in
                    HStack(spacing: 6) {
                        Text(event.source.tag ?? "RADIUS")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.faintText)
                        // Identical events folded into this row — iMaster's thirty-second
                        // re-bind, mostly. The time shown is the newest of them.
                        if event.repeats > 1 {
                            Text("\u{00D7}\(event.repeats)")
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.faintText)
                        }
                        // Which Policy ▸ Rules fired, scraped out of radiusd's own debug
                        // stream — nothing extra goes on the wire to make this possible.
                        if !event.rules.isEmpty {
                            Text("rule \(event.rules.joined(separator: "\u{2192}"))")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.accent)
                                .lineLimit(1)
                        }
                    }
                }
                .width(min: 70, ideal: 110, max: 190)
            }
            .plainTable()
            .frame(height: tableHeight)
            .tablePanel()
            .overlay {
                if model.events.isEmpty {
                    TableEmptyOverlay("No authentications recorded. Run a check under Test, or authenticate a device.")
                }
            }
        })
    }

    private var tableHeight: CGFloat {
        // 28 pt per row plus the header, floored so an empty table still shows its headings and
        // capped so the group above it never scrolls off the top of a 620 pt window.
        min(max(CGFloat(model.events.count) * 26 + 40, 120), 420)
    }

    // MARK: Missing components (development builds only)

    /// Only reachable on a build without the bundled FreeRADIUS (or with `-demoNoRadius 1`):
    /// a release .app carries its own copy and never shows this.
    private var missingTools: some View {
        PaneGroup("Missing components", help: """
        A release build carries its own copy of every server, so a missing one means this is a \
        development build (or the bundled copy was stripped).

        Homebrew can fix it from here: it runs as you — no administrator password, and nothing \
        outside Homebrew's own prefix. Homebrew's own installer is the one thing that cannot be \
        run from here, because it needs an administrator password and the Xcode command line \
        tools.
        """) {
            let missing = model.tools.missingFormulae
            if !missing.isEmpty {
                NoteRow(text: "\(Self.describe(missing)) not found.",
                        systemImage: "exclamationmark.triangle.fill", tint: Theme.warn)
                if model.tools.brew != nil {
                    PlainRow { InstallButton(formulae: missing) }
                } else {
                    NoteRow(text: "Homebrew was not found either — run these two in Terminal, in order.")
                    PlainRow {
                        CopyButton("Copy Homebrew install command",
                                   value: Self.homebrewInstallCommand, bordered: true)
                        CopyButton("Copy \(missing.joined(separator: " + ")) command",
                                   value: "brew install \(missing.joined(separator: " "))",
                                   bordered: true)
                        Button("Open Terminal") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                        }
                        .buttonStyle(.bordered)
                        Spacer(minLength: 0)
                    }
                }
            }
            if model.tools.openssl == nil {
                NoteRow(text: "openssl was not found — macOS normally ships LibreSSL at /usr/bin/openssl.")
            }
        }
        .controlSize(.small)
    }

    /// The official one-liner from brew.sh. Copied, never executed by the app.
    private static let homebrewInstallCommand =
        "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""

    private static func describe(_ formulae: [String]) -> String {
        let names = formulae.map { $0 == "freeradius-server" ? "FreeRADIUS" : "OpenLDAP" }
        return names.count == 1 ? "\(names[0]) was" : "\(names.joined(separator: " and ")) were"
    }
}

// Status' own `CopyButton(title, value)` shorthand is gone (build 24): the shared
// `CopyButton` in Components.swift is what every copy control in the app is now, so the
// confirmation cannot be in one of them and not another.

/// `brew install <formulae>`, streamed live. Observes the ServerProcess directly so the
/// output appears as it arrives instead of all at once at the end.
private struct InstallButton: View {
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var installer = AppModel.shared.installer
    let formulae: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button("Install \(formulae.joined(separator: " + ")) with Homebrew") {
                    model.installWithHomebrew(formulae)
                }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(installer.isRunning)
                if installer.isRunning {
                    ProgressView().controlSize(.small)
                    Text("This takes a few minutes.").hint()
                }
                Spacer(minLength: 0)
            }

            if !installer.log.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(installer.log) { line in
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
                    .onChange(of: installer.log.count) {
                        if let last = installer.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
