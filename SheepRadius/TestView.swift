import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TestView: View {
    @ObservedObject private var model = AppModel.shared

    /// Which check is selected. Remembered on its own rather than derived from the form: the
    /// form holds a RADIUS method *and* an LDAP transport at all times, so it cannot say which
    /// of the two was last asked for.
    @AppStorage("TestPaneCheck") private var checkRaw = TestCheck.radiusPAP.rawValue
    @State private var form = TestForm.load()
    @State private var wrongPassword = false
    @State private var manualPassword = ""          // never persisted, anywhere
    /// The password of a `.p12` chosen as the EAP-TLS credential. `@State`, never in
    /// `TestForm`: that one is written to disk, and this unlocks a private key.
    @State private var p12Password = ""
    @State private var sharedSecret = ""
    @State private var bindPassword = ""
    @State private var revealSecret = false
    @State private var revealPassword = false
    @State private var showOptions = false
    @State private var showDetails = false

    @State private var output = ""
    @State private var command = ""
    @State private var outcome: RadiusOutcome?
    @State private var eapOutcome: EAPOutcome?
    @State private var ldapVerdict: Bool?
    @State private var diagnosis = ""
    @State private var elapsed = 0
    @State private var running = false
    /// Which Policy ▸ Rules radiusd said it fired for the last test against this Mac. Read
    /// out of our own server's debug stream, so it is only ever available for `.thisMac`.
    @State private var rulesFired: [String] = []
    @State private var recent: [TestRun] = []
    @State private var nextRunID = 0

    /// `-demoTestCheck ldapsBind` — pick a check **without touching the saved preference**
    /// (build 25). The pane's choice and its form live in `UserDefaults`, which is the
    /// person's, not a screenshot's; a capture run reads them and writes nothing back.
    private static let demoCheck = CommandLine.value(after: "-demoTestCheck")
        .flatMap(TestCheck.init(rawValue:))

    private var check: TestCheck { Self.demoCheck ?? TestCheck(rawValue: checkRaw) ?? .radiusPAP }

    /// True while this process is drawing itself for a screenshot or was pointed at a check
    /// from the command line. Nothing it does reaches the saved preferences.
    private var isDemo: Bool { Chrome.isCapturing || Self.demoCheck != nil }

    private var username: String { form.manualUsername }

    private var password: String {
        wrongPassword ? manualPassword + "-wrong" : manualPassword
    }

    private var radiusTool: String? {
        form.method.needsEAPClient ? model.tools.radeapclient : model.tools.radclient
    }

    private var radiusHost: String {
        form.target == .thisMac ? "127.0.0.1" : form.radiusHost.trimmingCharacters(in: .whitespaces)
    }

    private var radiusPort: Int {
        if form.target == .thisMac {
            return form.exchange.usesAccountingPort ? model.applied.settings.acctPort : model.applied.settings.authPort
        }
        return form.exchange.usesAccountingPort ? form.radiusAcctPort : form.radiusPort
    }

    /// The Keychain account this target's shared secret is filed under, so several servers can
    /// each keep their own.
    private var secretAccount: String {
        TestSecretAccount.name(host: radiusHost, port: form.radiusPort)
    }

    private var hasResult: Bool {
        outcome != nil || eapOutcome != nil || ldapVerdict != nil || !output.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneBody {
                PaneHeader(eyebrow: PaneHeadline.block(for: "test").eyebrow,
                           heading: PaneHeadline.block(for: "test").heading,
                           subtitle: PaneHeadline.block(for: "test").subtitle) {
                    if running { ProgressView().controlSize(.small) }
                }
                whatToTest
                if showOptions { options }
                if hasResult { result }
                recentGroup
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
        }
        .onAppear {
            // Build 17 could leave `credentials` on "user from table"; the pane types its
            // credentials now, so the form is normalised once on the way in.
            form.credentials = .manual
            if form.manualUsername.isEmpty, !isDemo {
                form.manualUsername = model.directory.users.first?.username
                    ?? model.applied.users.first?.username ?? ""
            }
            sharedSecret = TestSecretAccount.secret(for: secretAccount) { SecretStore.load(account: $0) }
            if form.ldapBaseDN.isEmpty { form.ldapBaseDN = model.applied.settings.ldapSuffix }
            check.apply(to: &form)
        }
        // **The secret belongs to the server, so it follows the server** (build 25, QA H-7).
        // `secretAccount` has always been per host and port; the field was loaded in
        // `.onAppear` and nowhere else, so retargeting the pane sent the *first* server's
        // secret — "no response", which the pane's own diagnosis then blamed on a firewall —
        // and **Remember** filed that wrong secret under the new host.
        .onChange(of: secretAccount) { _, account in
            sharedSecret = TestSecretAccount.secret(for: account) { SecretStore.load(account: $0) }
        }
        .onChange(of: form) { if !isDemo { form.save() } }
    }

    // MARK: What to test

    private var whatToTest: some View {
        // The title names the packet the Exchange picker has chosen (QA M-10).
        PaneGroup(["What to test", check.headerNote(exchange: form.exchange)]
            .compactMap { $0 }.joined(separator: " · "), help: """
        This Mac uses the applied configuration: the ports, the base DN and the built-in \
        127.0.0.1 client this app generated. Another server aims the bundled radclient and \
        OpenLDAP tools somewhere else — this Mac's own servers do not even have to be running.

        A password typed here is never written anywhere: not to lab.json, not to preferences, \
        not to the Keychain. It lives until this window closes. The username is remembered.
        """) {
            KeyValueRow("Check") {
                Picker("", selection: Binding(
                    get: { check },
                    set: { value in checkRaw = value.rawValue; value.apply(to: &form); reset() })) {
                    ForEach(TestCheck.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().valueControl()
            }
            KeyValueRow("Server") {
                Picker("", selection: $form.target) {
                    Text("This Mac (\(model.primaryAddress))").tag(TestTarget.thisMac)
                    Text("Another server…").tag(TestTarget.other)
                }
                .labelsHidden().valueControl()
            }
            if form.target == .other {
                if check.isLDAP {
                    KeyValueRow("Server or URL") {
                        TextField("ldaps://dc1.example.com", text: $form.ldapHost).valueControl()
                    }
                    KeyValueRow("Port") {
                        TextField("", value: $form.ldapPort, format: .number.grouping(.never))
                            .valueNumber()
                    }
                } else {
                    KeyValueRow("Server") {
                        TextField("10.0.0.10", text: $form.radiusHost).valueControl()
                    }
                    KeyValueRow("Auth / accounting port") {
                        HStack(spacing: 8) {
                            TextField("", value: $form.radiusPort, format: .number.grouping(.never)).valueNumber()
                            Text("/").foregroundStyle(Theme.faintText)
                            TextField("", value: $form.radiusAcctPort, format: .number.grouping(.never)).valueNumber()
                        }
                    }
                    KeyValueRow("Shared secret") {
                        HStack(spacing: 6) {
                            Group {
                                if revealSecret { TextField("", text: $sharedSecret) }
                                else { SecureField("", text: $sharedSecret) }
                            }
                            .valueControl()
                            Button { revealSecret.toggle() } label: {
                                Image(systemName: revealSecret ? "eye.slash" : "eye").font(.system(size: 10))
                            }
                            .buttonStyle(.borderless).foregroundStyle(Theme.dimText)
                            .help(revealSecret ? "Hide the shared secret" : "Show the shared secret")
                            .accessibilityLabel(revealSecret ? "Hide the shared secret" : "Show the shared secret")
                            Button("Remember") { SecretStore.save(sharedSecret, account: secretAccount) }
                                .buttonStyle(.bordered)
                                .help("Stored in the login Keychain, per server and port — never in lab.json or preferences.")
                        }
                    }
                }
            }
            KeyValueRow("Username") {
                HStack(spacing: 6) {
                    TextField("alice", text: $form.manualUsername).valueControl()
                    // **From the directory, which is the only set of accounts there is**
                    // (build 21). The password comes with it only when this app set it —
                    // a directory will not give one back — so an account changed in ADUC
                    // fills in the name and leaves the password to be typed.
                    if !model.directory.users.isEmpty {
                        Menu {
                            ForEach(model.directory.users) { user in
                                Button(user.username) {
                                    form.manualUsername = user.username
                                    // **`applied`, not `doc`** (build 25, QA M-9). The menu
                                    // pre-fills the password radiusd is actually serving, not
                                    // one typed into the inspector a moment ago and not yet
                                    // written into `authorize` — which filled in a password
                                    // the running server did not have and reported the
                                    // resulting reject as the server's answer.
                                    manualPassword = model.appliedDirectoryPasswords[
                                        user.username.lowercased()] ?? ""
                                }
                            }
                        } label: { Image(systemName: "list.bullet") }
                            .menuStyle(.borderlessButton)
                            .frame(width: 26)
                            .help("Fill in an account from the directory")
                    }
                }
            }
            if check.usesPassword {
                KeyValueRow("Password") {
                    HStack(spacing: 6) {
                        Group {
                            if revealPassword { TextField("", text: $manualPassword) }
                            else { SecureField("", text: $manualPassword) }
                        }
                        .valueControl()
                        Button { revealPassword.toggle() } label: {
                            Image(systemName: revealPassword ? "eye.slash" : "eye").font(.system(size: 10))
                        }
                        .buttonStyle(.borderless).foregroundStyle(Theme.dimText)
                        .help(revealPassword ? "Hide the password" : "Show the password")
                        .accessibilityLabel(revealPassword ? "Hide the password" : "Show the password")
                    }
                }
            } else {
                // EAP-TLS has no password. The certificate's CN has to be the username above:
                // the generated `tls-config` sets `check_cert_cn = %{User-Name}`, so a
                // mismatch comes back as an Access-Reject from the server.
                KeyValueRow("Client certificate") {
                    filePicker($form.eapClientCertificate, CertificateFileTypes.certificate)
                }
                KeyValueRow("Private key or .p12") {
                    filePicker($form.eapClientKey, CertificateFileTypes.keyOrBundle)
                }
                if form.eapClientKey.hasSuffix(".p12") || form.eapClientKey.hasSuffix(".pfx") {
                    KeyValueRow("Bundle password") {
                        SecureField("", text: $p12Password).valueControl()
                    }
                }
            }
            PlainRow {
                Button("Run") { Task { await run() } }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(running || !canRun)
                    .keyboardShortcut(.defaultAction)
                Button(showOptions ? "Options ▾" : "Options ▸") { showOptions.toggle() }
                    .buttonStyle(.bordered)
                Text(optionsSummary).hint()
                Spacer(minLength: 0)
            }
            // **Every reason Run is off, and everything the app already knows** (build 25,
            // QA M-5 and M-11) — one list, from `TestBlocker`.
            if let hint = blocker {
                NoteRow(text: hint, systemImage: "exclamationmark.triangle.fill", tint: Theme.warn)
            }
            if let warning = TestBlocker.warning(blockerInputs) {
                NoteRow(text: warning, systemImage: "exclamationmark.circle.fill", tint: Theme.warn)
            }
        }
    }

    private var optionsSummary: String {
        check.isLDAP ? "base DN, filter, certificate" : "NAS-IP, SSID, MAC, certificate"
    }

    /// **Every input the refusal depends on, in one value** (build 25 — `TestBlocker`).
    ///
    /// `canRun` had nine conditions and `blocker` explained five of them, which is how an
    /// empty username, an empty external host and "a key with no certificate" came to disable
    /// the button in silence (QA M-5). One pure rule answers both questions now, so they
    /// cannot disagree, and the sentences have a unit test.
    private var blockerInputs: TestBlocker.Inputs {
        TestBlocker.Inputs(
            check: check,
            targetIsThisMac: form.target == .thisMac,
            exchange: form.exchange,
            username: username,
            radiusHost: radiusHost,
            ldapHost: form.ldapHost,
            clientCertificate: form.eapClientCertificate,
            clientKey: form.eapClientKey,
            availableTransports: model.applied.settings.availableTransports,
            hasRadiusTool: radiusTool != nil,
            hasEAPTool: model.tools.eapolTest != nil,
            eapToolHint: model.tools.eapolTestHint,
            hasLDAPTools: model.tools.ldapsearch != nil && model.tools.ldapwhoami != nil,
            radiusRunning: model.radius.isRunning,
            directoryRunning: model.directoryIsLive,
            hasUnappliedChanges: model.hasUnappliedChanges)
    }

    private var canRun: Bool { TestBlocker.canRun(blockerInputs) }

    /// The one line that says why Run will not work, or nil.
    private var blocker: String? { TestBlocker.reason(blockerInputs) }

    private func run() async {
        check.apply(to: &form)
        if check.isLDAP { await runLDAP() }
        else if check.isEAP { await runEAP() }
        else { await runRadius() }
    }

    // MARK: Options

    private var options: some View {
        PaneGroup("Options") {
            if check.isLDAP {
                KeyValueRow("Base DN") {
                    TextField("dc=lab,dc=local", text: $form.ldapBaseDN).valueControl()
                }
                KeyValueRow("Filter") {
                    HStack(spacing: 8) {
                        TextField("(sAMAccountName=<user>)", text: $form.ldapFilter).valueControl()
                        Button("uid") { form.ldapFilter = "(uid=<user>)" }.buttonStyle(.bordered)
                        Button("sAM") { form.ldapFilter = "(sAMAccountName=<user>)" }.buttonStyle(.bordered)
                    }
                }
                KeyValueRow("Attributes") {
                    TextField("dn cn mail memberOf", text: $form.ldapAttributes).valueControl()
                }
                if form.target == .other {
                    KeyValueRow("Transport") {
                        Picker("", selection: $form.ldapTransport) {
                            ForEach(LDAPTransport.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().valueControl()
                    }
                    PlainRow {
                        Toggle("Search anonymously", isOn: $form.ldapAnonymous).toggleStyle(.checkbox)
                        Spacer(minLength: 0)
                    }
                    if !form.ldapAnonymous {
                        KeyValueRow("Search bind DN or user@domain") {
                            TextField("Administrator@lab.sheep", text: $form.ldapBindDN).valueControl()
                        }
                        KeyValueRow("Search bind password") {
                            SecureField("", text: $bindPassword).valueControl()
                        }
                        NoteRow(text: "This account is used only to find the user's DN. Leave it empty to search anonymously.")
                    }
                }
                KeyValueRow("Certificate") {
                    Picker("", selection: $form.ldapVerification) {
                        ForEach(LDAPVerification.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().valueControl()
                }
                if form.ldapVerification == .file {
                    KeyValueRow("CA file") { filePicker($form.ldapCAPath, CertificateFileTypes.certificate) }
                }
                if form.ldapVerification == .none, form.ldapTransport != .plain {
                    NoteRow(text: "Without validation any host on the network can impersonate the directory server undetected. Acceptable for a quick check, never acceptable as a conclusion.",
                            systemImage: "exclamationmark.triangle.fill", tint: Theme.warn)
                }
                NoteRow(text: "`<user>` is replaced with the username above, escaped.")
            } else {
                KeyValueRow("NAS-IP-Address") {
                    TextField("optional", text: $form.nasIPAddress).valueControl()
                }
                KeyValueRow("SSID / Called-Station-Id") {
                    TextField("AP-GROUP:SSID or AP MAC:SSID", text: $form.calledStationID).valueControl()
                }
                KeyValueRow("Client MAC / Calling-Station-Id") {
                    TextField("client MAC", text: $form.callingStationID).valueControl()
                }
                KeyValueRow("NAS-Identifier") {
                    TextField("optional", text: $form.nasIdentifier).valueControl()
                }
                KeyValueRow("NAS-Port-Type") {
                    TextField("Ethernet / Wireless-802.11", text: $form.nasPortType).valueControl()
                }
                if check.isEAP {
                    KeyValueRow("Server certificate", help: """
                    Without validation any host on the network can impersonate the \
                    authentication server, capture the inner MSCHAPv2 exchange and attack it \
                    offline. This is how production Wi-Fi credentials are compromised. \
                    Acceptable to isolate a fault, never acceptable as a reported result.
                    """) {
                        Picker("", selection: $form.eapValidation) {
                            ForEach(EAPServerValidation.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().valueControl()
                    }
                    if form.eapValidation == .caFile {
                        KeyValueRow("CA file") { filePicker($form.eapCAPath, CertificateFileTypes.certificate) }
                    }
                    KeyValueRow("Expected server name") {
                        TextField("optional — e.g. radius.lab.local", text: $form.eapExpectedServerName)
                            .valueControl()
                    }
                    KeyValueRow("Outer identity", help: """
                    This is what the outer exchange shows. The real username only exists inside \
                    the tunnel — which is exactly where a Policy rule's group and OU conditions \
                    are evaluated. Empty sends the real identity outside too.
                    """) {
                        TextField("anonymous@lab", text: $form.eapAnonymousIdentity).valueControl()
                    }
                    PlainRow {
                        Toggle("Offer TLS 1.3", isOn: $form.eapAllowTLS13).toggleStyle(.checkbox)
                        HelpDot(text: """
                        wpa_supplicant keeps TLS 1.3 switched off for EAP unless it is asked, \
                        because PEAP over 1.3 is not standardised — so the handshake lands on \
                        1.2 however high RADIUS ▸ Server's “TLS max version” is set.
                        """)
                        Spacer(minLength: 0)
                    }
                    KeyValueRow("Timeout") {
                        HStack(spacing: 8) {
                            TextField("", value: $form.eapTimeout, format: .number.grouping(.never)).valueNumber()
                            Text("s").foregroundStyle(Theme.faintText)
                        }
                    }
                } else {
                    KeyValueRow("Exchange") {
                        Picker("", selection: $form.exchange) {
                            ForEach(RadiusExchange.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().valueControl()
                    }
                    KeyValueRow("Timeout / retries") {
                        HStack(spacing: 8) {
                            TextField("", value: $form.timeout, format: .number.grouping(.never)).valueNumber()
                            Text("s ·").foregroundStyle(Theme.faintText)
                            TextField("", value: $form.retries, format: .number.grouping(.never)).valueNumber()
                        }
                    }
                }
                KeyValueRow("Extra attributes") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextEditor(text: $form.extraAttributes)
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(width: Metrics.control, height: 54, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: Metrics.field).fill(Theme.well))
                        Text("One `Name = value` per line.").hint()
                    }
                }
            }
            PlainRow {
                Toggle("Send a wrong password", isOn: $wrongPassword).toggleStyle(.checkbox)
                Spacer(minLength: 0)
            }
        }
    }

    private func filePicker(_ path: Binding<String>, _ kinds: [UTType] = CertificateFileTypes.any) -> some View {
        HStack(spacing: 8) {
            Text(path.wrappedValue.isEmpty ? "none chosen" : path.wrappedValue)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.faintText)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 200, alignment: .leading)
            Button("Choose…") { chooseFile(into: path, kinds) }.buttonStyle(.bordered)
        }
    }

    // MARK: Result

    private var result: some View {
        PaneGroup("Result") {
            KeyValueRow("Verdict") {
                HStack(spacing: 10) {
                    verdictPill
                    if elapsed > 0 {
                        Text("\(elapsed) ms")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.dimText)
                    }
                    Text(verdictDetail).hint()
                }
            }
            KeyValueRow("Reply") {
                Text(replyLine)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(replyLine == "—" ? Theme.faintText : Theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if form.target == .thisMac, !check.isLDAP,
               !model.applied.rules.filter({ $0.enabled }).isEmpty {
                KeyValueRow("Rule fired") {
                    Text(rulesFired.isEmpty ? "none" : rulesFired.joined(separator: " → "))
                        .font(.system(size: 12))
                        .foregroundStyle(rulesFired.isEmpty ? Theme.faintText : Theme.accent)
                        .textSelection(.enabled)
                }
            }
            PlainRow {
                Button(showDetails ? "Details ▾" : "Details ▸") { showDetails.toggle() }
                    .buttonStyle(.bordered)
                Spacer(minLength: 0)
            }
            if showDetails { details }
        }
    }

    @ViewBuilder private var verdictPill: some View {
        if let outcome {
            StatusPill(text: outcome.verdict.label,
                       kind: outcome.verdict.isGood ? .ok
                             : outcome.verdict == .noResponse ? .warn : .bad)
        } else if let eapOutcome {
            StatusPill(text: eapOutcome.verdict.label,
                       kind: eapOutcome.verdict.isGood ? .ok
                             : eapOutcome.verdict == .timeout ? .warn : .bad)
        } else if let ldapVerdict {
            StatusPill(text: ldapVerdict ? "Bind succeeded" : "Bind failed",
                       kind: ldapVerdict ? .ok : .bad)
        } else {
            StatusPill(text: "No verdict")
        }
    }

    /// The short second half of the verdict line: what was negotiated, and whose certificate.
    private var verdictDetail: String {
        var parts: [String] = []
        if let eapOutcome {
            if let method = eapOutcome.negotiatedMethod { parts.append(method) }
            if let version = eapOutcome.tlsVersion { parts.append("TLS \(version)") }
            if let suite = eapOutcome.cipherSuite { parts.append(suite) }
            switch eapOutcome.validationPassed {
            case true: parts.append("certificate verified")
            case false: parts.append("certificate refused")
            default: if form.eapValidation == .none { parts.append("certificate not validated") }
            }
            if eapOutcome.verdict == .accept, !eapOutcome.mppeKeysPresent {
                parts.append("no MPPE keys — 802.1X would still fail")
            }
        } else {
            parts.append(check.shortLabel)
        }
        return parts.joined(separator: " · ")
    }

    /// The reply, as one line: the VLAN first because that is what a lab is usually checking.
    private var replyLine: String {
        var parts: [String] = []
        if let vlan = outcome?.vlan ?? eapOutcome?.vlan { parts.append(vlan) }
        let attributes = (eapOutcome?.attributes ?? []) + (outcome?.attributes ?? [])
        parts += attributes.map { "\($0.name) = \($0.value)" }
        if parts.isEmpty, ldapVerdict == true { return diagnosis.isEmpty ? "bound" : diagnosis }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    @ViewBuilder private var details: some View {
        if !diagnosis.isEmpty {
            NoteRow(text: diagnosis, tint: Theme.text2)
        }
        if let eapOutcome, !eapOutcome.certificates.isEmpty {
            ForEach(eapOutcome.certificates) { certificate in
                PlainRow {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(certificate.isLeaf ? "leaf" : "depth \(certificate.depth)")  \(certificate.subject)")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.text).textSelection(.enabled)
                        if !certificate.issuer.isEmpty {
                            Text("issuer  \(certificate.issuer)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.faintText).textSelection(.enabled)
                        }
                        if !certificate.notAfter.isEmpty {
                            Text("expires  \(certificate.notAfter)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.faintText).textSelection(.enabled)
                        }
                        if !certificate.subjectAlternativeNames.isEmpty {
                            Text("SAN  \(certificate.subjectAlternativeNames.joined(separator: ", "))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.faintText).textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        PlainRow {
            VStack(alignment: .leading, spacing: 6) {
                if !command.isEmpty {
                    // Build 20, audit N-4: the same mask the Log pane applies, for the same
                    // reason — this is the half of the pane that gets pasted into a ticket.
                    // Log ▸ Show passwords turns it off for both.
                    Text(LogRedaction.redact(command, show: model.showPasswordsInLogs))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.faintText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ScrollView {
                    Text(output.isEmpty ? "No output." : redactedOutput)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.text2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 170)
                .background(RoundedRectangle(cornerRadius: Metrics.field).fill(Theme.well))
            }
            Spacer(minLength: 0)
        }
    }

    /// The client's raw output with credentials masked, line by line so a `LazyVStack`-free
    /// `Text` still only pays for what is on screen once.
    private var redactedOutput: String {
        guard !model.showPasswordsInLogs else { return output }
        return output.split(separator: "\n", omittingEmptySubsequences: false)
            .map { LogRedaction.redact(String($0)) }
            .joined(separator: "\n")
    }

    // MARK: Recent

    private var recentGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Recent", note: "this session only · nothing is written to disk")
            Table(recent) {
                TableColumn("Time") { run in
                    Text(LogTime.clock(run.time))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.dimText)
                }
                .width(min: 66, ideal: 70, max: 80)
                TableColumn("Check") { run in
                    Text(run.method).font(.system(size: 11.5)).foregroundStyle(Theme.text2).lineLimit(1)
                }
                .width(min: 90, ideal: 130, max: 190)
                TableColumn("User") { run in
                    Text(run.user).font(.system(size: 11.5)).foregroundStyle(Theme.text2).lineLimit(1)
                }
                .width(min: 74, ideal: 110, max: 170)
                TableColumn("Server") { run in
                    Text(run.target)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.dimText)
                        .lineLimit(1).truncationMode(.middle)
                }
                .width(min: 90, ideal: 150, max: 240)
                TableColumn("Result") { run in
                    HStack(spacing: 8) {
                        StatusPill(text: run.verdict, kind: run.good ? .ok : .bad)
                        Text("\(run.milliseconds) ms")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.faintText)
                    }
                }
                .width(min: 100, ideal: 170)
            }
            .plainTable()
            .frame(height: min(max(CGFloat(recent.count) * 26 + 40, 110), 330))
            .tablePanel()
            .overlay {
                if recent.isEmpty {
                    TableEmptyOverlay("Nothing run yet. This session only — nothing here is written to disk.")
                }
            }
        }
    }

    // MARK: Running RADIUS

    private func runRadius() async {
        var request = RadiusRequest()
        request.username = username
        request.password = password
        request.method = form.method
        request.exchange = form.exchange
        request.nasIPAddress = form.nasIPAddress
        request.nasIdentifier = form.nasIdentifier
        request.nasPortType = form.nasPortType
        request.calledStationID = form.calledStationID
        request.callingStationID = form.callingStationID
        request.extra = form.extraAttributes

        let problems = request.problems
        guard problems.isEmpty else { model.report(problems.joined(separator: "\n")); return }

        running = true
        defer { running = false }
        reset()

        let runner = TestRunner(tools: model.tools, env: model.env)
        let secret = form.target == .thisMac ? localTestSecret : sharedSecret
        let target = "\(radiusHost):\(radiusPort)"
        let result = await runner.radius(request, host: radiusHost, port: radiusPort, secret: secret,
                                         timeout: form.timeout, retries: form.retries)
        command = result.command
        output = result.output
        elapsed = result.milliseconds
        outcome = result.outcome
        if result.outcome.verdict == .noResponse {
            diagnosis = RadiusReplyParser.noResponseExplanation
            showDetails = true
            if form.target == .thisMac, !model.radius.isRunning {
                diagnosis = "The RADIUS server is not running on this host — start it in the sidebar.\n\n" + diagnosis
            }
        }
        // The rule tags arrive on the debug stream a moment after radclient has its reply, so
        // give the reader a beat before asking what fired.
        if form.target == .thisMac, !username.isEmpty {
            try? await Task.sleep(for: .milliseconds(300))
            rulesFired = model.recentRules(for: username)
        }
        record(target: targetLabel(target), user: username.isEmpty ? "—" : username,
               method: form.exchange == .authentication ? check.shortLabel : form.exchange.label,
               verdict: result.outcome.verdict.label, good: result.outcome.verdict.isGood)
    }

    // MARK: Running tunnelled EAP

    private func runEAP() async {
        var request = EAPTestRequest()
        request.method = form.eapMethod
        request.identity = username
        request.password = password
        request.anonymousIdentity = form.eapAnonymousIdentity
        request.validation = form.eapValidation
        request.caFile = form.eapCAPath
        request.expectedServerName = form.eapExpectedServerName
        request.clientCertificate = form.eapClientCertificate
        request.clientKey = form.eapClientKey
        request.clientKeyPassword = p12Password
        request.allowTLS13 = form.eapAllowTLS13
        request.nasIPAddress = form.nasIPAddress
        request.nasIdentifier = form.nasIdentifier
        request.nasPortType = form.nasPortType
        request.calledStationID = form.calledStationID
        request.callingStationID = form.callingStationID
        request.timeout = form.eapTimeout

        let problems = request.problems
        guard problems.isEmpty else { model.report(problems.joined(separator: "\n")); return }

        running = true
        defer { running = false }
        reset()

        let caPath: String? = switch form.eapValidation {
        case .labCA: model.env.caPEM.path
        case .caFile: form.eapCAPath
        case .none: nil
        }
        let runner = TestRunner(tools: model.tools, env: model.env)
        let secret = form.target == .thisMac ? localTestSecret : sharedSecret
        let target = "\(radiusHost):\(radiusPort)"
        let result = await runner.eap(request, host: radiusHost, port: radiusPort,
                                      secret: secret, caPath: caPath)
        command = result.command
        output = result.output
        elapsed = result.milliseconds
        var parsed = result.outcome
        diagnosis = parsed.explanation ?? ""
        if parsed.verdict != .accept { showDetails = true }
        if form.target == .thisMac, !model.radius.isRunning {
            diagnosis = "The RADIUS server is not running on this host — start it in the sidebar.\n\n" + diagnosis
        }
        // Same beat as runRadius: the debug stream arrives a moment after the child exits.
        if form.target == .thisMac, !username.isEmpty {
            try? await Task.sleep(for: .milliseconds(300))
            rulesFired = model.recentRules(for: username)
            parsed.cipherSuite = model.recentCipherSuite()
        }
        eapOutcome = parsed
        record(target: targetLabel(target), user: username.isEmpty ? "—" : username,
               method: check.shortLabel, verdict: parsed.verdict.label,
               good: parsed.verdict.isGood)
    }

    // MARK: Running LDAP

    private func runLDAP() async {
        running = true
        defer { running = false }
        reset()

        let settings = model.applied.settings
        let uri: String
        let tls: [String]
        var searchBindDN = ""
        var searchPassword = ""

        if form.target == .thisMac {
            // **The check's transport, never a substitute** (build 25, QA H-6). Build 24 read
            // `available.contains(form.ldapTransport) ? … : (available.first ?? .plain)`, so
            // with LDAPS switched off the check labelled **LDAPS bind** bound over `ldap://`,
            // reported "Bind succeeded" and filed "LDAPS bind" in the Recent table. A test
            // that quietly runs a different test is worse than one that refuses, and
            // `TestBlocker` refuses before Run is even enabled; this is the belt to that brace.
            let available = settings.availableTransports
            let mode = check.transport ?? form.ldapTransport
            guard available.contains(mode) else {
                ldapVerdict = false
                diagnosis = TestBlocker.offlineTransport(mode)
                output = diagnosis
                record(target: targetLabel(check.shortLabel), user: username.isEmpty ? "—" : username,
                       method: check.shortLabel, verdict: "refused", good: false)
                return
            }
            // 127.0.0.1, not localhost: OpenLDAP's client rejects that literal name over TLS
            // even when the certificate lists it (ConfigGenerator.ldapsHostNote).
            uri = mode == .ldaps ? "ldaps://127.0.0.1:\(settings.ldapsPort)" : "ldap://127.0.0.1:\(settings.ldapPort)"
            tls = LDAPTransport.tlsArguments(mode: mode, caPath: model.env.caPEM.path)
            if settings.directoryBackend == .activeDirectory {
                searchBindDN = "Administrator@\(settings.ad.realm)"
                searchPassword = settings.ad.administratorPassword
            } else {
                searchBindDN = settings.ldapAdminDN
                searchPassword = settings.ldapAdminPassword
            }
        } else {
            uri = form.ldapURI
            tls = verificationArguments()
            if !form.ldapAnonymous, !form.ldapBindDN.isEmpty {
                searchBindDN = form.ldapBindDN
                searchPassword = bindPassword
            }
        }

        let base = form.ldapBaseDN.isEmpty ? settings.ldapSuffix : form.ldapBaseDN
        let filter = LDAPDiagnosis.filter(form.ldapFilter, user: username)
        let attributes = form.ldapAttributes.split(separator: " ").map(String.init)

        let runner = TestRunner(tools: model.tools, env: model.env)
        let result = await runner.ldap(uri: uri, searchBindDN: searchBindDN,
                                       searchPassword: searchPassword, userPassword: password,
                                       base: base, filter: filter, attributes: attributes,
                                       tls: tls, timeout: form.timeout)
        command = result.command
        output = result.output
        elapsed = result.milliseconds
        ldapVerdict = result.bound
        diagnosis = result.diagnosis
        if !result.bound {
            showDetails = true
            if form.target == .thisMac, !model.directoryIsLive {
                diagnosis = "The directory server is not running on this host — start it in the sidebar.\n\n" + diagnosis
            }
            record(target: targetLabel(uri), user: username,
                   method: check.shortLabel, verdict: "failed", good: false)
            return
        }
        record(target: targetLabel(uri), user: username,
               method: check.shortLabel, verdict: "Bind succeeded", good: true)
    }

    private func verificationArguments() -> [String] {
        var out: [String] = []
        if form.ldapTransport == .startTLS { out.append("-ZZ") }   // -Z would carry on in the clear
        switch form.ldapVerification {
        case .system: break
        case .labCA: out += ["-o", "TLS_CACERT=\(model.env.caPEM.path)"]
        case .file where !form.ldapCAPath.isEmpty: out += ["-o", "TLS_CACERT=\(form.ldapCAPath)"]
        case .file: break
        case .none: out += ["-o", "TLS_REQCERT=never"]
        }
        return out
    }

    /// **The panel says what it will take** (build 25, QA L-6). All four Choose… panels set no
    /// `allowedContentTypes`, so a person looking for a `.p12` was offered every file on the
    /// Mac and found out which ones were wrong from openssl.
    private func chooseFile(into path: Binding<String>, _ kinds: [UTType]) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = kinds
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path.wrappedValue = url.path
    }

    // MARK: Plumbing

    /// "This Mac" in the Recent table, the address anywhere else.
    private func targetLabel(_ raw: String) -> String {
        form.target == .thisMac ? "This Mac" : raw
    }

    private func reset() {
        outcome = nil
        eapOutcome = nil
        ldapVerdict = nil
        diagnosis = ""
        output = ""
        command = ""
        elapsed = 0
        showDetails = false
        rulesFired = []
    }

    private func record(target: String, user: String, method: String, verdict: String, good: Bool) {
        recent.insert(TestRun(id: nextRunID, time: Date(), target: target, user: user,
                              method: method, verdict: verdict, good: good, milliseconds: elapsed), at: 0)
        nextRunID += 1
        if recent.count > 10 { recent.removeLast(recent.count - 10) }
    }

}
