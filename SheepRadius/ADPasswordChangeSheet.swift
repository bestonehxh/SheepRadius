import SwiftUI

/// **Changing the domain's Administrator password, in one step** (owner request, build 17).
///
/// Before this the field in Directory ▸ Server changed a *setting* and nothing else: on a
/// running domain the controller kept the password it already had, and the only thing that
/// ever noticed the disagreement was a device failing to join, days later, with a message that
/// named neither. Here the domain is changed first and the setting is written only if that
/// succeeded — so the settings can never claim a password the domain does not have.
///
/// The password reaches `samba-tool` through **stdin and a 0600 file inside the container**
/// (`ADCommands.setAdministratorPasswordScript`), never as an argument.
struct ADPasswordChangeSheet: View {
    @ObservedObject private var model = AppModel.shared
    let isRunning: Bool
    let realm: String
    let dismiss: () -> Void

    @State private var password = ""
    @State private var confirmation = ""
    @State private var reveal = false
    @State private var failure: String?
    @State private var working = false

    private var problem: String? {
        if password.isEmpty { return nil }
        if !confirmation.isEmpty, password != confirmation { return "The two entries do not match." }
        // Samba's default complexity rules, stated here rather than left to a refusal from the
        // domain that arrives after the sheet has closed.
        if password.count < 7 { return "Active Directory's default policy wants at least 7 characters." }
        return nil
    }

    private var canCommit: Bool {
        !password.isEmpty && password == confirmation && problem == nil && !working
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change the Administrator password")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            Text(isRunning
                 ? "This sets it in the domain \(realm) and in this app's settings together."
                 : "The domain controller is not running, so this only records the password the domain will be provisioned with.")
                .hint()

            field("New password") {
                Group {
                    if reveal { TextField("", text: $password) } else { SecureField("", text: $password) }
                }
                .frame(width: 220)
            }
            field("Repeat") {
                Group {
                    if reveal { TextField("", text: $confirmation) } else { SecureField("", text: $confirmation) }
                }
                .frame(width: 220)
            }
            HStack(spacing: 8) {
                Spacer().frame(width: 110)
                Button(reveal ? "Hide" : "Show") { reveal.toggle() }
                    .buttonStyle(.bordered).controlSize(.small)
                Button("Generate") {
                    password = ADSettings.generatedPassword()
                    confirmation = password
                    reveal = true
                }
                .buttonStyle(.bordered).controlSize(.small)
                Spacer(minLength: 0)
            }

            if let problem {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(Theme.err)
            }
            if let failure {
                Text(failure).font(.system(size: 11.5)).foregroundStyle(Theme.err)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isRunning {
                Text("Anything holding the old password — a joined computer's cached credentials, a NAC's bind account — has to be updated afterwards.")
                    .hint()
            }

            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Change") { commit() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(!canCommit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12.5))
        .controlSize(.small)
        .padding(20)
        .frame(width: 460)
    }

    private func commit() {
        working = true
        failure = nil
        let secret = password
        Task {
            let problem = await model.changeDomainAdministratorPassword(to: secret)
            working = false
            if let problem { failure = problem } else { dismiss() }
        }
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(label).foregroundStyle(Theme.dimText).frame(width: 110, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}
