import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var model = AppModel.shared
    @State private var backups: [LabBackup] = []

    var body: some View {
        VStack(spacing: 0) {
            PaneBody {
                PaneHeader(PaneHeadline.block(for: "settings"))
                PaneGroup("Move this lab", help: """
                Export stops the servers, writes a .sheeplab file and starts them again. The \
                domain's state volume is what carries the domain SID, the computer accounts and \
                the passwords, so a Mac that has imported it is the same domain — every machine \
                that joined stays joined. Re-provisioning instead would give a new SID and every \
                one of them would have to rejoin.

                Import on the other Mac loads the image, creates the volume, restores the files, \
                and takes a backup of whatever was here first.

                Only one of the two Macs may run the domain controller at a time. Stop it on the \
                old one before starting it on the new one — the app refuses to start a controller \
                when another one on the network is already answering for the realm, but it cannot \
                stop the other Mac for you.
                """) {
                    NoteRow(text: "One file with everything: lab.json, raddb, certificates, the directory — and in AD mode the container image and the domain's state volume.")
                    PlainRow {
                        Button("Export lab…") { exportLab() }
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                        Button("Import lab…") { importLab() }
                            .buttonStyle(.bordered)
                        Spacer(minLength: 0)
                    }
                    .disabled(model.transferStatus != nil)
                    if let status = model.transferStatus {
                        PlainRow {
                            ProgressView().controlSize(.small)
                            Text(status).font(.system(size: 11.5)).foregroundStyle(Theme.dimText)
                            Spacer(minLength: 0)
                        }
                    } else if let export = model.lastExport {
                        PlainRow {
                            Text("Last written: \(export.url.lastPathComponent) · \(LabManifest.bytes(export.bytes))")
                                .font(.system(size: 11.5)).foregroundStyle(Theme.dimText)
                            Button("Reveal") {
                                NSWorkspace.shared.activateFileViewerSelecting([export.url])
                            }
                            .buttonStyle(.borderless)
                            Spacer(minLength: 0)
                        }
                    }
                }

                PaneGroup("Backups",
                          accessory: Button("Backup now") {
                              Task {
                                  if let problem = await model.backupNow(.manual) { model.report(problem) }
                                  backups = model.listBackups()
                              }
                          }
                          .buttonStyle(.bordered)
                          .disabled(model.transferStatus != nil)) {
                    NoteRow(text: "The same file, kept here. The last \(BackupRotation.limit) are kept; one is taken automatically before an import, a rebuild or a backend switch.")
                    if backups.isEmpty {
                        NoteRow(text: "No backups yet.")
                    } else {
                        ForEach(backups) { backup in
                            PlainRow {
                                Text(backup.label)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(Theme.text2)
                                Spacer(minLength: 0)
                                Button("Restore…") { restore(backup) }
                                    .buttonStyle(.bordered)
                                    .disabled(model.transferStatus != nil)
                            }
                        }
                    }
                }

                PaneGroup("Components") {
                    // A release build carries all of these, so "bundled" is the normal answer
                    // and "Homebrew" means this is a development build.
                    component("RADIUS server", model.radiusDescription, model.tools.radiusd)
                    component("RADIUS client", model.radiusDescription, model.tools.radclient)
                    component("LDAP server", model.ldapDescription, model.tools.slapd)
                    component("LDAP client", model.ldapClientDescription, model.tools.ldapsearch)
                    component("TLS", model.opensslDescription, model.tools.openssl)
                    KeyValueRow("Dictionaries") { path(model.tools.dictionaryDir) }
                    KeyValueRow("LDAP schemas") { path(model.tools.schemaDir) }
                    KeyValueRow("Lab folder") {
                        HStack(spacing: 8) {
                            path(model.env.base.path)
                            Button("Reveal") {
                                NSWorkspace.shared.activateFileViewerSelecting([model.env.base])
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    // Build 18: this sentence used to sit under every pane of the app, in the
                    // sidebar's footer. It is true, it is worth saying once, and it is not
                    // worth a permanent strip of the window.
                    NoteRow(text: "Lab use only. Passwords are stored in cleartext because PEAP-MSCHAPv2 needs them.",
                            systemImage: "info.circle")
                }
            }
            .font(.system(size: 12.5))
            .controlSize(.small)
        }
        .onAppear { backups = model.listBackups() }
        .sheet(item: $model.importPreview) { preview in
            LabImportSheet(preview: preview) { backups = model.listBackups() }
        }
    }

    private func path(_ value: String?) -> some View {
        Text(value ?? "not found")
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(value == nil ? Theme.err : Theme.text2)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    /// Name, "<product> <version> · bundled|Homebrew", and the path it resolved to.
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

    // MARK: Export / Import / Restore
    //
    // `NSSavePanel` / `NSOpenPanel` rather than SwiftUI's `.fileExporter`: the archive is
    // written by `ditto` into a path, not produced as a `FileDocument`, and pretending
    // otherwise would mean holding a 112 MB lab in memory to hand it back to the framework.

    private func exportLab() {
        let panel = NSSavePanel()
        panel.title = "Export lab"
        panel.nameFieldStringValue = LabManifest.suggestedFilename()
        // The lab's own type, so the panel names it and Import below can filter on it (L-6).
        panel.allowedContentTypes = LabFileTypes.lab
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if let problem = await model.exportLab(to: url) { model.report(problem) }
            backups = model.listBackups()
        }
    }

    private func importLab() {
        let panel = NSOpenPanel()
        panel.title = "Import lab"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = LabFileTypes.lab
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { model.importPreview = await model.previewLab(at: url) }
    }

    private func restore(_ backup: LabBackup) {
        Task { model.importPreview = await model.previewLab(at: backup.url) }
    }
}
