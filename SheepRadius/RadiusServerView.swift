import AppKit
import SwiftUI

struct RadiusServerView: View {
    @ObservedObject private var model = AppModel.shared
    /// Observed directly, not through `model`: `AppModel` does not republish its children, so
    /// a state row read off `model.radius` would be whatever it was when the pane was opened.
    @ObservedObject private var radius = AppModel.shared.radius

    var body: some View {
        VStack(spacing: 0) {
            PaneBody {
                PaneHeader(PaneHeadline.block(for: "radiusServer"))
                // **The pane says whether radiusd is running, and can start it** (build 25,
                // QA M-24). Every other server has a state row where it is configured — the
                // AD card has had one since build 16, the sidebar has both switches — and the
                // one pane actually called "RADIUS server" showed only the *directory's*
                // state, under "Accounts come from".
                PaneGroup("Server") {
                    PlainRow {
                        Circle().fill(dotColour).frame(width: 9, height: 9)
                        Text(stateLine)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.text2)
                        if model.busy { ProgressView().controlSize(.small) }
                        Spacer(minLength: 0)
                        Button(radius.isRunning ? "Stop" : "Start") {
                            Task {
                                // The same door the sidebar switch uses, so LDAP still comes
                                // up first and every refusal still applies (ServerPair).
                                radius.isRunning ? await model.stopRadius() : await model.startRadius()
                            }
                        }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                        // Not disabled for a missing radiusd (build 32): the press opens
                        // Environment, the same as every other start control.
                        .disabled(model.busy)
                    }
                    if model.tools.radiusd == nil {
                        NoteRow(text: Toolchain.missingServerMessage(server: "RADIUS", binary: "radiusd"),
                                systemImage: "exclamationmark.triangle.fill", tint: Theme.warn)
                    } else if !radius.isRunning {
                        NoteRow(text: "Starting RADIUS starts the LDAP directory first — radiusd reads its accounts from it.")
                    }
                }

                PaneGroup("Accounts", help: """
                There is one set of accounts and the LDAP directory owns it. radiusd's user \
                list is written from the directory's snapshot and reloaded (HUP, no restart) \
                after every change, so a password set in the Users pane works on the next \
                login.

                An account whose password this app set is written with its cleartext password, \
                so every method works. An account changed somewhere else — in ADUC, on a joined \
                PC — is known only by the NT hash pulled out of the directory: \
                \(RadiusAuthorize.chapNeedsCleartext)
                """) {
                    KeyValueRow("Accounts come from") { MonoValue(value: sourceLine) }
                    if model.radiusHasNoDirectory {
                        NoteRow(text: "LDAP is off, so every login is rejected until it is started.",
                                systemImage: "exclamationmark.triangle.fill", tint: Theme.warn)
                    }
                }

                PaneGroup("Listeners") {
                    KeyValueRow("Auth port") { number($model.doc.settings.authPort) }
                    KeyValueRow("Accounting port") { number($model.doc.settings.acctPort) }
                }

                PaneGroup("EAP", help: """
                The default EAP type is only the server's first offer — clients can still \
                negotiate any of PEAP, TTLS, TLS or MD5. Changing the certificate name takes \
                effect after Reissue under Certificates.
                """) {
                    KeyValueRow("Default EAP type") {
                        Picker("", selection: $model.doc.settings.defaultEAP) {
                            ForEach(EAPType.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().valueControl()
                    }
                    KeyValueRow("TLS max version") {
                        Picker("", selection: $model.doc.settings.tlsMaxVersion) {
                            Text("1.2 (most compatible)").tag("1.2")
                            Text("1.3").tag("1.3")
                        }
                        .labelsHidden().valueControl()
                    }
                    KeyValueRow("Server certificate name") {
                        TextField("radius.lab.local", text: $model.doc.settings.serverCertName)
                            .valueControl()
                    }
                }
            }
            .font(.system(size: 12.5))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
        }
    }

    private var dotColour: Color {
        radius.isRunning ? Theme.ok : Theme.dimmedControl
    }

    private var stateLine: String {
        guard radius.isRunning else { return "Stopped" }
        return "Running · udp \(model.applied.settings.authPort) · \(model.applied.settings.acctPort)"
    }

    private var sourceLine: String {
        model.directoryIsLive
            ? "\(model.directoryLabel) · \(model.directory.users.count) account(s)"
            : "\(model.directoryLabel) · not running"
    }

    private func number(_ value: Binding<Int>) -> some View {
        TextField("", value: value, format: .number.grouping(.never)).valueNumber()
    }
}
