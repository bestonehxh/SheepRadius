import AppKit
import SwiftUI

/// Devices — what to type into each product's own form. (Called "Device settings" up to build
/// 17; the sidebar row is **Devices** now, and `-demoPane deviceSettings` still opens it.)
struct DeviceSettingsView: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        VStack(spacing: 0) {
            PaneBody {
                PaneHeader(eyebrow: PaneHeadline.block(for: "devices").eyebrow,
                           heading: PaneHeadline.block(for: "devices").heading,
                           subtitle: model.doc.settings.directoryBackend == .openLDAP
                           ? "What to enter on a switch, access point, firewall or NAC"
                           : "What to enter to join a workstation or a NAC")
                if model.doc.settings.directoryBackend == .activeDirectory {
                    ADDeviceSections()
                } else {
                    PaneGroup("Connection details") {
                        // Only the URLs that actually exist.
                        if model.doc.settings.ldapPlainEnabled {
                            KeyValueRow(model.doc.settings.offersStartTLS
                                        ? "Server URL (plain / StartTLS)" : "Server URL") {
                                CopyableValue(value: "ldap://\(model.primaryAddress):\(model.doc.settings.ldapPort)")
                            }
                        }
                        if model.doc.settings.ldapsEnabled {
                            KeyValueRow("Server URL (LDAPS)") {
                                CopyableValue(value: "ldaps://\(model.primaryAddress):\(model.doc.settings.ldapsPort)")
                            }
                        }
                        if model.doc.settings.needsTLS {
                            KeyValueRow("CA to import on the device") {
                                CopyableValue(value: model.env.caPEM.path, path: true)
                            }
                        }
                        KeyValueRow("Search base") { CopyableValue(value: model.doc.settings.ldapSuffix) }
                        KeyValueRow("User filter (AD style)") { CopyableValue(value: "(sAMAccountName=%s)") }
                        KeyValueRow("User filter (POSIX style)") { CopyableValue(value: "(uid=%s)") }
                        KeyValueRow("Bind DN pattern") {
                            CopyableValue(value: "uid=<user>,ou=<OU path, leaf first>,\(model.doc.settings.ldapSuffix)")
                        }
                        KeyValueRow("Group attribute") { CopyableValue(value: "memberOf") }
                        KeyValueRow("Sample group DN") {
                            CopyableValue(value: "cn=\(sampleGroupName),\(model.doc.settings.groupsDN)")
                        }
                        KeyValueRow("Admin bind DN") { CopyableValue(value: model.doc.settings.ldapAdminDN) }
                        if model.doc.settings.publishNTHashes {
                            KeyValueRow("Password attribute (NAC)") { CopyableValue(value: "sambaNTPassword") }
                        }
                        NoteRow(text: "Every user is also in cn=\(LabGroup.everyoneName).")
                    }

                    PaneGroup("NT hashes for NAC servers", help: """
                    Adds sambaNTPassword (the MD4 “NT hash” of the password) to every user. On \
                    the NAC: add a generic LDAP authentication source, bind as the admin DN \
                    above, set the password attribute to sambaNTPassword and the password type \
                    to “NT hash”.

                    The attribute is password-equivalent and is protected exactly like \
                    userPassword — only the admin DN can read it.
                    """) {
                        PlainRow {
                            Toggle("Publish NT hashes (ClearPass / iMaster NCE generic-LDAP source)",
                                   isOn: $model.doc.settings.publishNTHashes)
                            Spacer(minLength: 0)
                        }
                        NoteRow(text: "Allows a NAC to perform PEAP-MSCHAPv2 without a domain join.")
                    }

                    perDeviceTables
                }
            }
            .font(.system(size: 12.5))
            .controlSize(.small)
        }
    }

    /// The same two-column tables AD mode has, for the products that talk to this directory
    /// without a domain: a plain LDAP form, a FortiGate, an iMaster and a ClearPass source.
    /// Built from the **applied** settings, because a listener that has not been applied is not
    /// listening.
    private var perDeviceTables: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Field names by product").groupTitle().padding(.horizontal, 2)
            if model.hasUnappliedDirectoryChanges {
                Label("These are the applied settings — there are edits that have not been applied yet.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(Theme.warn)
                    .padding(.horizontal, 2)
            }
            DeviceProfileTable(profiles: DeviceProfiles.openLDAP(
                settings: model.applied.settings, address: model.primaryAddress,
                caPath: model.tools.openssl == nil ? nil : model.env.caPEM.path))
        }
    }

    private var sampleGroupName: String {
        model.doc.groups.first(where: { !$0.name.isEmpty })?.name ?? LabGroup.everyoneName
    }
}
