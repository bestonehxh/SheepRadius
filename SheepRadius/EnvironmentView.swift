import SwiftUI

/// **Every install in the app, on one page** (build 32). The bundled servers, Homebrew's
/// `brew install` for a development build that lacks them, Apple's `container` tool and the
/// Samba AD image all live here; Status and Directory ▸ Server only point at it.
///
/// A start that fails because one of these is missing — or a launch that finds one missing —
/// lands here through `AppModel.openEnvironment(for:)`, with the reason at the top and the
/// group it names drawn in the warning colour.
struct EnvironmentView: View {
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var ad = AppModel.shared.ad

    var body: some View {
        PaneBody {
            PaneHeader(PaneHeadline.block(for: "environment"))
            if let focus = model.environmentFocus {
                PaneGroup("Needs attention") {
                    NoteRow(text: focus.reason, systemImage: "exclamationmark.triangle.fill", tint: Theme.warn)
                }
            }
            servers
            if !model.tools.missingFormulae.isEmpty || model.tools.openssl == nil { install }
            ADPrerequisitesCard()
                .overlay(focusRing(model.environmentFocus == .container || model.environmentFocus == .adImage))
            files
        }
        .font(.system(size: 12.5))
        .controlSize(.small)
        .task { await ad.refreshPrerequisites() }
        // The highlight answers one failed start; it is not a state the pane lives in.
        .onDisappear { model.environmentFocus = nil }
    }

    // MARK: Servers

    private var servers: some View {
        PaneGroup("Servers") {
            NoteRow(text: "FreeRADIUS, OpenLDAP and OpenSSL are bundled inside SheepRadius.app. Samba AD also needs Apple's container runtime, below.")
            component("RADIUS server", model.radiusDescription, model.tools.radiusd)
            component("RADIUS client", model.radiusDescription, model.tools.radclient)
            component("LDAP server", model.ldapDescription, model.tools.slapd)
            component("LDAP client", model.ldapClientDescription, model.tools.ldapsearch)
            component("TLS", model.opensslDescription, model.tools.openssl)
        }
        .overlay(focusRing(model.environmentFocus == .radius || model.environmentFocus == .ldap))
    }

    // MARK: Install (development builds only)

    /// Only reachable on a build without the bundled FreeRADIUS or OpenLDAP (or with
    /// `-demoNoRadius 1` / `-demoNoLDAP 1`): a release .app carries its own copy.
    private var install: some View {
        PaneGroup("Install", help: """
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
    }

    // MARK: Files

    private var files: some View {
        PaneGroup("Files") {
            KeyValueRow("Dictionaries") { path(model.tools.dictionaryDir) }
            KeyValueRow("LDAP schemas") { path(model.tools.schemaDir) }
            KeyValueRow("Lab folder") {
                HStack(spacing: 8) {
                    path(model.env.base.path)
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([model.env.base]) }
                        .buttonStyle(.borderless)
                }
            }
            NoteRow(text: "Lab use only. Passwords are stored in cleartext because PEAP-MSCHAPv2 needs them.", systemImage: "info.circle")
        }
    }

    // MARK: Pieces

    /// The official one-liner from brew.sh. Copied, never executed by the app.
    static let homebrewInstallCommand =
        "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""

    static func describe(_ formulae: [String]) -> String {
        let names = formulae.map { $0 == "freeradius-server" ? "FreeRADIUS" : "OpenLDAP" }
        return names.count == 1 ? "\(names[0]) was" : "\(names.joined(separator: " and ")) were"
    }

    private func focusRing(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: Metrics.card)
            .strokeBorder(Theme.warn, lineWidth: on ? 1.5 : 0)
            .allowsHitTesting(false)
    }

    private func path(_ value: String?) -> some View {
        Text(value ?? "not found")
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(value == nil ? Theme.err : Theme.text2)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func component(_ name: String, _ description: String, _ value: String?) -> some View {
        KeyValueRow(name) {
            VStack(alignment: .leading, spacing: 1) {
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(value == nil ? Theme.err : Theme.text2)
                path(value)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.faintText)
            }
        }
    }
}

/// `brew install <formulae>`, streamed live. Observes the ServerProcess directly so the
/// output appears as it arrives instead of all at once at the end.
struct InstallButton: View {
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
