import AppKit
import SwiftUI

/// What importing a `.sheeplab` would do to **this** Mac, before it does any of it.
///
/// The three things a person needs in front of them: which lab it is, what happens to the lab
/// that is here, and — the one that actually costs a day when it is missed — whether the
/// domain controller is still running on the Mac it came from.
struct LabImportSheet: View {
    @ObservedObject private var model = AppModel.shared
    let preview: LabImportPreview
    var afterwards: () -> Void = {}

    /// AD only: import the state under a different volume name, which is what lets a lab be
    /// brought onto a Mac that already has one (and what `./Tests/run.sh ad` does).
    @State private var volumeName = ""
    @State private var useOtherVolume = false

    /// The volume the import would use, so the refusal and the run agree (L-17).
    private var chosenVolume: String? {
        let trimmed = volumeName.trimmingCharacters(in: .whitespaces)
        return useOtherVolume && !trimmed.isEmpty ? trimmed : nil
    }

    private var running: Bool { model.transferStatus != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import this lab").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(preview.manifest.lines, id: \.self) { line in
                    Text(line).font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.text2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: Metrics.field).fill(Theme.well))

            if let warning = preview.warning {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: preview.canImport(volumeName: chosenVolume)
                          ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(preview.canImport(volumeName: chosenVolume) ? Theme.warn : Theme.err)
                    Text(warning.replacingOccurrences(of: "**", with: ""))
                        .font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // **What the file will run here** (build 20, audit N-1). A `.sheeplab` carrying a
            // domain is not data: the image inside it is loaded and then started with
            // `--cap-add CAP_SYS_ADMIN` and thirteen published host ports. The digest is shown
            // so it can be compared with the one the sender read off their own export; the
            // import refuses anything that does not match it.
            if preview.manifest.carriesContainerImage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "shippingbox").foregroundStyle(Theme.warn)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("""
                        This archive contains a domain-controller container image. Importing it \
                        loads that image on this host, and starting the domain runs it with \
                        elevated capabilities and published network ports.
                        """)
                            .font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("SHA-256 " + (preview.manifest.digests[LabArchiveEntry.image] ?? "not recorded"))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Theme.dimText)
                            .textSelection(.enabled)
                    }
                }
            }

            if preview.manifest.backend == .activeDirectory {
                Toggle("Import the domain under another volume name", isOn: $useOtherVolume)
                    .toggleStyle(.checkbox).font(.system(size: 11.5))
                if useOtherVolume {
                    TextField(preview.manifest.volumeName, text: $volumeName)
                        .textFieldStyle(.roundedBorder).frame(width: 240)
                }
            }

            // **What it is doing, while it does it** (build 25, QA M-26). The status line
            // was here already; what was missing is that it is the *only* thing on screen
            // once the sheet is dismissed — so the sheet stays, and says so.
            if let status = model.transferStatus {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(status).font(.system(size: 11.5)).foregroundStyle(Theme.dimText)
                    }
                    Text("""
                    This replaces lab.json, raddb/, certs/ and ldap/ on this Mac. It cannot be \
                    stopped once it has started.
                    """)
                        .hint()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                // **Cancel is disabled while the import runs** (build 25, QA M-26). Import
                // beside it already was; pressing Cancel hid the sheet while the detached task
                // went on replacing the lab, with no progress anywhere and no result.
                Button("Cancel", role: .cancel) { model.importPreview = nil }
                    .buttonStyle(.bordered)
                    .disabled(running)
                    .keyboardShortcut(.cancelAction)
                Button("Import") { runImport() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(!preview.canImport(volumeName: chosenVolume) || running)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.small)
        .padding(18)
        .frame(width: 540)
        // Nothing to interrupt while it runs, so the cancel key must not look like an escape.
        .interactiveDismissDisabled(running)
        .onAppear { volumeName = preview.manifest.volumeName }
    }

    private func runImport() {
        let name = chosenVolume
        Task {
            let problem = await model.importLab(preview, volumeName: name)
            model.importPreview = nil
            if let problem { model.report(problem, detail: model.transferDetail) }
            afterwards()
        }
    }
}
