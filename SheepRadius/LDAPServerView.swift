import AppKit
import SwiftUI

struct LDAPServerView: View {
    @ObservedObject private var model = AppModel.shared
    /// Observed directly — `AppModel` does not republish its children, and the lock below has
    /// to be true the moment radiusd is up rather than one unrelated redraw later.
    @ObservedObject private var radius = AppModel.shared.radius
    /// **M-17.** The AD Administrator's password has had a reveal button since build 19; the
    /// OpenLDAP one was a plain `TextField`, permanently legible to anyone looking at the
    /// screen, with no way to cover it.
    @State private var revealAdminPassword = false

    /// Locked for exactly the reason, and with exactly the sentence, the sidebar's LDAP
    /// switch is (build 25, QA H-8 — see `ServerPair`).
    private var runLocked: String? {
        ServerPair.directorySwitchLockedHint(radiusRunning: radius.isRunning)
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneBody {
                PaneHeader(eyebrow: PaneHeadline.block(for: "ldapServer").eyebrow,
                           heading: PaneHeadline.block(for: "ldapServer").heading,
                           subtitle: model.doc.settings.directoryBackend == .openLDAP
                           ? "Listeners, base DN and the administrator account"
                           : "The Samba domain controller, its container and what it needs")
                ADBackendCard()
                if model.doc.settings.directoryBackend == .activeDirectory {
                    ADServerSections()
                } else {
                    PaneGroup("Listeners") {
                        PlainRow {
                            // **Locked while radiusd runs** (build 25, QA H-8). Without this
                            // the toggle could be switched off under a running RADIUS and
                            // **Apply & Restart** pressed — which took both servers down and
                            // reported that "OpenLDAP could not start", about a server nothing
                            // had asked to start. Reproduced live on port set A.
                            Toggle("Run the LDAP server", isOn: $model.doc.settings.ldapEnabled)
                                .disabled(runLocked != nil)
                                .help(runLocked ?? "")
                            Spacer(minLength: 0)
                        }
                        if let runLocked {
                            Text(runLocked).hint()
                        }
                        // Two independent listeners: plain only, LDAPS only, or both.
                        PlainRow {
                            Toggle("LDAP (plain) on port", isOn: $model.doc.settings.ldapPlainEnabled)
                            number($model.doc.settings.ldapPort)
                                .disabled(!model.doc.settings.ldapPlainEnabled)
                            Spacer(minLength: 0)
                        }
                        PlainRow {
                            Toggle("LDAPS on port", isOn: $model.doc.settings.ldapsEnabled)
                            number($model.doc.settings.ldapsPort)
                                .disabled(!model.doc.settings.ldapsEnabled)
                            Spacer(minLength: 0)
                        }
                        NoteRow(text: model.doc.settings.offersStartTLS
                                ? "StartTLS comes with LDAPS — slapd's TLS context is global."
                                : model.doc.settings.ldapsEnabled
                                  ? "LDAPS only — nothing will listen on the plain port."
                                  : "Plain LDAP only — no TLS at all, so no LDAPS and no StartTLS. Passwords cross the network in the clear.")
                    }

                    // **One name for the whole lab** (build 24). The base DN is not typed any
                    // more: it is the lab domain with a `dc=` per label, which is the same
                    // name Samba AD's realm carries — so a device configured against one
                    // backend is configured against the other. Editable only while the
                    // directory is stopped, because renaming a live database is not a thing to
                    // do under a bind in flight; the rename itself happens at the next start.
                    PaneGroup("Directory tree") {
                        KeyValueRow("Lab domain") {
                            TextField("lab.sheep", text: $model.doc.settings.labDomain)
                                .valueControl()
                                .disabled(model.directoryIsLive)
                        }
                        KeyValueRow("Base DN") {
                            CopyableValue(value: model.doc.settings.ldapSuffix)
                        }
                        if model.directoryIsLive {
                            NoteRow(text: "Stop the directory to change the lab domain.")
                        }
                        if model.doc.settings.ldapSuffixDiffersFromLabDomain {
                            NoteRow(text: "This base DN was set by hand and does not match the lab domain, "
                                    + "which would give \(model.doc.settings.labDomainSuffix). Samba AD "
                                    + "answers for \(model.doc.settings.labDomain), so the two backends "
                                    + "are different directories to a device.",
                                    systemImage: "exclamationmark.triangle", tint: Theme.warn)
                        }
                        KeyValueRow("Admin DN") {
                            CopyableValue(value: model.doc.settings.ldapAdminDN)
                        }
                        KeyValueRow("Admin password") {
                            HStack(spacing: 6) {
                                Group {
                                    if revealAdminPassword {
                                        TextField("", text: $model.doc.settings.ldapAdminPassword)
                                    } else {
                                        SecureField("", text: $model.doc.settings.ldapAdminPassword)
                                    }
                                }
                                .valueControl()
                                Button { revealAdminPassword.toggle() } label: {
                                    Image(systemName: revealAdminPassword ? "eye.slash" : "eye")
                                        .font(.system(size: 10))
                                }
                                .buttonStyle(.borderless).foregroundStyle(Theme.dimText)
                                .help(revealAdminPassword ? "Hide the admin password" : "Show the admin password")
                                .accessibilityLabel(revealAdminPassword ? "Hide the admin password" : "Show the admin password")
                            }
                        }
                        if model.doc.settings.needsTLS {
                            NoteRow(text: "The device must trust this lab's CA — export it under Certificates.")
                        }
                    }
                }
            }
            .font(.system(size: 12.5))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
        }
    }

    private func number(_ value: Binding<Int>) -> some View {
        TextField("", value: value, format: .number.grouping(.never)).valueNumber()
    }
}
