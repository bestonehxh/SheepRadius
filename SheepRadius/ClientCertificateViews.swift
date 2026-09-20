import AppKit
import SwiftUI

/// **Issue one client certificate** — the sheet the Users pane's button opens (build 20).
///
/// Nothing on it is a choice except the validity and the bundle's password. The common name
/// and the UPN are shown rather than offered: the generated `tls-config` sets
/// `check_cert_cn = %{User-Name}`, so a certificate whose CN is anything but the account's
/// name is one the server will refuse, and a field that can only be filled in one way is a
/// field that should not be a field.
struct ClientCertificateSheet: View {
    @ObservedObject private var model = AppModel.shared
    let username: String
    var afterwards: () -> Void = {}

    @State private var days = ClientCertificateCommands.defaultDays
    @State private var password = ""
    @State private var confirmation = ""
    @State private var working = false

    private var principal: String {
        ClientCertificateNames.principal(
            username: username,
            domain: model.doc.settings.directoryBackend == .activeDirectory
                ? model.doc.settings.ad.realm : model.doc.settings.dnsDomain)
    }

    private var problem: String? {
        if let problem = ClientCertificateNames.problem(with: username) { return problem }
        if days < 1 || days > ClientCertificateCommands.maxDays {
            return "Validity has to be between 1 and \(ClientCertificateCommands.maxDays) days."
        }
        if !password.isEmpty, !confirmation.isEmpty, password != confirmation {
            return "The two passwords are not the same."
        }
        return nil
    }

    private var canIssue: Bool {
        !working && problem == nil && !password.isEmpty && password == confirmation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Issue a client certificate")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)

            field("Common name") {
                Text(username).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.text2).textSelection(.enabled)
            }
            field("Principal name") {
                Text(principal).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.text2).textSelection(.enabled)
            }
            field("Valid for") {
                HStack(spacing: 8) {
                    TextField("", value: $days, format: .number.grouping(.never)).frame(width: 70)
                    Text("days").foregroundStyle(Theme.faintText)
                }
            }
            field("Password") {
                SecureField("for the .p12 file", text: $password).frame(width: 220)
            }
            field("Repeat") {
                SecureField("", text: $confirmation).frame(width: 220)
            }

            Text("""
            The private key is not kept here. The .p12 you save is the only copy, and it \
            carries this lab's CA as well as the certificate.
            """)
                .font(.system(size: 11.5)).foregroundStyle(Theme.dimText)
                .fixedSize(horizontal: false, vertical: true)

            if let problem {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(Theme.err)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text("Issuing…").font(.system(size: 11.5)).foregroundStyle(Theme.dimText)
                }
                Spacer()
                Button("Cancel", role: .cancel) { afterwards() }
                    .buttonStyle(.bordered)
                    .disabled(working)
                    .keyboardShortcut(.cancelAction)
                Button("Issue…") { issue() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(!canIssue)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12.5))
        .controlSize(.small)
        .padding(20)
        .frame(width: 420)
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(label).foregroundStyle(Theme.dimText).frame(width: 110, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func issue() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(ClientCertificateNames.fileSafe(username)).p12"
        panel.title = "Save the client certificate"
        panel.allowedContentTypes = CertificateFileTypes.keyOrBundle
        panel.allowsOtherFileTypes = true
        let secret = password
        let validity = days
        // **A sheet of the sheet, not a second modal session** (build 25, QA L-16).
        SheetSavePanel.present(panel) { destination in
            guard let destination else { return }
            working = true
            Task {
                let problem = await model.issueClientCertificate(username: username, days: validity,
                                                                 password: secret, to: destination)
                working = false
                if let problem { model.report(problem, detail: model.transferDetail) }
                afterwards()
            }
        }
    }
}

// MARK: - The Certificates pane's list

/// Every client certificate this lab has issued, and the one thing that can be done to it.
///
/// A real `Table`, like Users, Groups and Clients — the minimum widths add up to 352 pt, which
/// fits the pane's column at the 980 pt window (see CLAUDE.md on what a `Table` does to a
/// column it cannot fit).
struct ClientCertificateList: View {
    @ObservedObject private var model = AppModel.shared
    @State private var selected: String?
    @State private var confirmRevoke = false
    @State private var working = false

    private var rows: [ClientCertificate] { model.clientCertificates }

    private var chosen: ClientCertificate? {
        rows.first { $0.serial == selected }
    }

    var body: some View {
        PaneGroup("Client certificates", help: """
        For EAP-TLS, which has no password: the certificate is the credential. The server \
        checks that its common name is the user name being claimed.
        """) {
            if rows.isEmpty {
                NoteRow(text: "None issued yet. Issue one from a user's Properties in Users.")
            } else {
                PlainRow {
                    Table(rows, selection: $selected) {
                        TableColumn("User") { row in
                            Text(row.username).font(.system(size: 12.5)).lineLimit(1)
                        }
                        .width(min: 80, ideal: 120, max: 200)
                        TableColumn("Serial") { row in
                            Text(String(row.serial.prefix(16)))
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Theme.dimText).lineLimit(1)
                        }
                        .width(min: 110, ideal: 150)
                        TableColumn("Issued") { row in
                            Text(LabManifest.dayStamp(row.issued))
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Theme.text2)
                        }
                        .width(min: 78, ideal: 88, max: 110)
                        TableColumn("Expires") { row in
                            Text(LabManifest.dayStamp(row.expires))
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Theme.text2)
                        }
                        .width(min: 78, ideal: 88, max: 110)
                        // **"Superseded by a new CA" is its own status** (build 25, QA H-4).
                        // The table used to render from the dates alone, so a certificate that
                        // had stopped authenticating the moment the CA was replaced went on
                        // reading **Valid**.
                        TableColumn("Status") { row in
                            StatusPill(text: row.status().label,
                                       kind: row.status() == .valid ? .ok
                                             : row.status() == .revoked ? .bad : .warn)
                                .help(row.status() == .superseded
                                      ? "Signed by a CA this lab has replaced. It cannot be "
                                        + "revoked — the CA that issued it no longer exists — "
                                        + "and it will not authenticate. Issue a new one."
                                      : "")
                        }
                        .width(min: 66, ideal: 150, max: 190)
                    }
                    .plainTable()
                    .frame(height: min(240, CGFloat(rows.count) * 26 + 34))
                }
                PlainRow {
                    Button("Revoke…") { confirmRevoke = true }
                        .buttonStyle(.bordered)
                        .disabled(working || revokeBlocker != nil)
                    if working {
                        ProgressView().controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
                // **All three reasons, said** (build 25, QA M-7). The button was `.disabled`
                // for three different things and showed none of them, so "nothing happens
                // when I click Revoke" was the whole of the feedback.
                if let revokeBlocker {
                    NoteRow(text: revokeBlocker)
                }
                NoteRow(text: "Revoking restarts the RADIUS server: it reads the revocation list when it starts and not on a reload.")
            }
        }
        .confirmationDialog("Revoke this certificate?", isPresented: $confirmRevoke) {
            Button("Revoke", role: .destructive) { revoke() }
        } message: {
            Text(chosen.map { "\($0.username) — serial \($0.serial.prefix(16)). The device holding it stops authenticating, and the RADIUS server restarts." } ?? "")
        }
    }

    /// Why Revoke is off, or nil.
    private var revokeBlocker: String? {
        guard let chosen else { return "Select a certificate to revoke it." }
        if chosen.revoked != nil { return "That certificate is already revoked." }
        if chosen.supersededAt != nil {
            return "That certificate was signed by a CA this lab has replaced, so there is "
                + "nothing left to revoke it with. It already fails to authenticate."
        }
        return nil
    }

    private func revoke() {
        guard let serial = chosen?.serial else { return }
        working = true
        Task {
            let problem = await model.revokeClientCertificate(serial: serial)
            working = false
            if let problem { model.report(problem) }
        }
    }
}
