import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// **One** certificates pane (build 18).
///
/// Build 17 had two, one under RADIUS and one under Directory, and the CA card at the top of
/// each was the same card — same CA, same buttons, same words. A person who reissued it in one
/// place could not tell whether the other one still meant anything. There is one pane now: the
/// CA, then each leaf the CA has signed, in the order they matter.
///
/// Which leaves exist depends on what is configured, not on which pane you opened: the RADIUS
/// certificate is always there, the domain controller's is there in AD mode, and the slapd one
/// is there when OpenLDAP is set up for TLS.
struct CertificatesView: View {
    @ObservedObject private var model = AppModel.shared
    @State private var caInfo = "—"
    @State private var serverInfo = "—"
    @State private var ldapInfo = "—"
    @State private var ldapSAN = ""
    @State private var adInfo = "—"
    @State private var adSAN = ""
    /// **Every button that replaces a certificate confirms, and says what restarts**
    /// (build 25, QA M-25 — `CertificateReissue` has the sentences). Build 24 confirmed only
    /// the New CA, while the two far quieter-looking **Reissue…** buttons took a server down
    /// and broke every device that had pinned the old leaf without a word.
    @State private var pending: CertificateReissue.Leaf?

    var body: some View {
        VStack(spacing: 0) {
            PaneBody {
                PaneHeader(PaneHeadline.block(for: "certificates"))
                PaneGroup("Certificate authority", help: """
                Windows, recent Android and managed Apple devices need this CA installed and \
                trusted, with the expected server name set to \
                “\(model.doc.settings.serverCertName)”. An iPhone or Mac joining by hand just \
                shows a trust prompt.

                The CA is created once and kept, so reissuing a leaf below does not break a \
                device that already trusts it.
                """) {
                    certificateRow(caInfo)
                    KeyValueRow("File") { CopyableValue(value: model.env.caPEM.path, path: true) }
                    PlainRow {
                        Button("Export (.pem)…") { export(model.env.caPEM, as: "SheepRadius-CA.pem") }
                        Button("Export (.der / .cer)…") { export(model.env.caDER, as: "SheepRadius-CA.cer") }
                        Spacer(minLength: 0)
                        Button("New CA…", role: .destructive) { pending = .ca }
                    }
                    NoteRow(text: "Install this CA on any device that validates the server.")
                }

                PaneGroup("RADIUS server certificate", help: """
                Apple supplicants pin this certificate when the user taps Trust, so changing it \
                because the Mac moved network would break every device that already trusts it. \
                The directory certificate below is reissued, because devices point at an IP and \
                validate it.
                """) {
                    certificateRow(serverInfo)
                    KeyValueRow("Presented for") { MonoValue(value: "PEAP · TTLS · EAP-TLS") }
                    KeyValueRow("Name") { MonoValue(value: model.doc.settings.serverCertName) }
                    PlainRow {
                        Button("Reissue…") { pending = .radius }
                        Spacer(minLength: 0)
                    }
                    NoteRow(text: "825 days, serverAuth. Not reissued when this Mac's addresses change.")
                }

                if model.doc.settings.directoryBackend == .activeDirectory {
                    PaneGroup("Domain controller certificate", help: """
                    Issued to \(model.doc.settings.ad.dcFQDN) by the CA above, with the realm and \
                    every current address in its SAN, and handed to the container at start. A \
                    device that already trusts this lab's CA needs nothing new for LDAPS. It is \
                    reissued automatically when this Mac's addresses change.
                    """) {
                        certificateRow(adInfo)
                        KeyValueRow("Served on") { MonoValue(value: "636 · 3269") }
                        if !adSAN.isEmpty {
                            KeyValueRow("Valid for") { MonoValue(value: adSAN) }
                        }
                        // **A control, at last** (build 25, QA H-9). The card was display-only
                        // and `ensureADCertificate` was reachable from nowhere but the DC's own
                        // start with `force: false`, so after a New CA the domain controller
                        // served a leaf signed by a CA that no longer existed — and the note
                        // below said it was reissued automatically, which was never true of
                        // that case.
                        PlainRow {
                            Button("Reissue…") { pending = .domainController }
                                .disabled(model.busy)
                            Spacer(minLength: 0)
                        }
                        NoteRow(text: "Reissued when this Mac's addresses change, and by a new CA.")
                    }
                } else if model.doc.settings.needsTLS {
                    PaneGroup("LDAP server certificate", help: """
                    Devices point at an IP and do validate it, so this certificate is reissued \
                    when this Mac's addresses change. Import the same CA above on the device, or \
                    turn certificate validation off there for a quick test.

                    \(ConfigGenerator.ldapsHostNote)
                    """) {
                        certificateRow(ldapInfo)
                        KeyValueRow("Served on") { MonoValue(value: "LDAPS · StartTLS") }
                        if !ldapSAN.isEmpty {
                            KeyValueRow("Valid for") { MonoValue(value: ldapSAN) }
                        }
                        PlainRow {
                            Button("Reissue…") { pending = .directory }
                            Spacer(minLength: 0)
                        }
                        NoteRow(text: "Lists every address this Mac has, and follows them.")
                    }
                } else {
                    PaneGroup("LDAP server certificate") {
                        NoteRow(text: "No TLS is configured for the directory, so it presents no certificate. Turn LDAPS on under Directory ▸ Server.")
                    }
                }
                ClientCertificateList()
            }
            .controlSize(.small)
        }
        .task(id: model.certRevision) {
            caInfo = await model.env.describeCertificate(model.env.caPEM)
            serverInfo = await model.env.describeCertificate(model.env.serverPEM)
            ldapInfo = await model.env.describeCertificate(model.env.ldapPEM)
            ldapSAN = await model.env.describeSAN(model.env.ldapPEM)
            adInfo = await model.env.describeCertificate(model.env.adPEM)
            adSAN = await model.env.describeSAN(model.env.adPEM)
        }
        .confirmationDialog(CertificateReissue.title(pending ?? .ca), isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button(pending == .ca ? "Create New CA" : "Reissue", role: .destructive) {
                let leaf = pending
                pending = nil
                Task { await reissue(leaf) }
            }
            Button("Cancel", role: .cancel) { pending = nil }
                .keyboardShortcut(.cancelAction)
        } message: {
            Text(confirmationMessage)
        }
    }

    /// The New CA's message counts the client certificates it is about to invalidate (H-4):
    /// they were signed by the CA being replaced, and until this build the table went on
    /// calling every one of them "Valid" afterwards.
    private var confirmationMessage: String {
        guard let pending else { return "" }
        var out = CertificateReissue.restartNote(pending)
        if pending == .ca {
            out = model.env.loadClientIndex().newCAWarning() + "\n\n" + out
            let leaves = CertificateReissue.leavesOfNewCA(
                backend: model.doc.settings.directoryBackend,
                directoryNeedsTLS: model.doc.settings.needsTLS)
            if leaves.contains(.domainController) {
                out += " The domain controller's certificate is reissued with it."
            }
        }
        return out
    }

    private func reissue(_ leaf: CertificateReissue.Leaf?) async {
        switch leaf {
        case .ca: await model.regenerateCertificates(includingCA: true)
        case .radius: await model.regenerateCertificates(includingCA: false)
        case .directory: await model.regenerateLDAPCertificate()
        case .domainController: await model.regenerateADCertificate()
        case nil: break
        }
    }

    /// **"Not generated yet" is only true when there is something to generate it with**
    /// (build 25, QA L-15). With `openssl` missing the pane promised a certificate at the next
    /// start and the buttons then failed into the bare string `openssl not found`.
    private func certificateRow(_ info: String) -> some View {
        KeyValueRow("Certificate") {
            MonoValue(value: info == "—" ? missingLine : info,
                      tint: info == "—" ? Theme.faintText : Theme.text2)
        }
    }

    private var missingLine: String {
        model.tools.openssl == nil
            ? "`openssl` is not in this build, so no certificate can be made."
            : "Not generated yet — created the first time the server starts."
    }

    private func export(_ source: URL, as name: String) {
        guard FileManager.default.fileExists(atPath: source.path) else {
            model.report(model.tools.openssl == nil
                         ? "There is no CA to export: `openssl` is not in this build, so this "
                           + "lab has never been able to make one."
                         : "No certificate yet — start RADIUS once to generate it.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = CertificateFileTypes.certificate
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            model.report(error.localizedDescription)
        }
    }
}
