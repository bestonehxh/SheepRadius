import AppKit
import SwiftUI

/// Whether this process is drawing itself for `-demoShot`.
enum Chrome {
    static let isCapturing = CommandLine.value(after: "-demoShot") != nil
}

/// Family shell (SheepDrop design v2): a fixed 240pt sidebar that owns the traffic-light row,
/// and a main column showing the selected pane.
struct ContentView: View {
    @ObservedObject private var model = AppModel.shared
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 212)
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 0.5)
            VStack(spacing: 0) {
                // **The title-bar band, in the main column too** (build 22). The sidebar has
                // always reserved it — it owns the traffic lights — and the main column had
                // not, so a pane's title was drawn *inside* the title bar and sat 40 pt above
                // the sidebar's first heading. Same constant, same fullscreen exception, so
                // the two columns cannot drift apart.
                Color.clear
                    .frame(height: model.isFullScreen ? Metrics.titleBarFullScreen : Metrics.titleBar)
                // …or when the document as loaded is not valid, even with nothing edited.
                // Build 15: a lab.json written before the built-in-group names were refused
                // carries a group called "Guests", and the owner has to be told *before* he
                // presses Sync now — not only if he happens to make an unrelated edit first.
                if model.showsApplyBar || !model.problems.isEmpty { ApplyBar() }
                mainColumn
            }
            // The main column is solid so a grouped list reads as a panel raised off it; the
            // sidebar keeps the window's vibrancy, the way every system app's does.
            .background(Theme.content)
        }
        .background {
            // `-demoShot` draws the window itself, and `cacheDisplay` cannot render
            // behind-window vibrancy — it comes out black. The material resolves to very
            // nearly `Theme.sidebar` over an ordinary desktop, so a captured window shows
            // that instead of a hole.
            if Chrome.isCapturing {
                Theme.sidebar.ignoresSafeArea()
            } else {
                VisualEffectBackground(material: .sidebar).ignoresSafeArea()
            }
        }
        .frame(minWidth: 980, minHeight: 620)
        .modifier(FullscreenSync())
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: errorBinding) {
            ErrorSheet(message: model.lastError ?? "", detail: model.lastErrorDetail) {
                model.clearError()
            }
        }
        .onAppear(perform: Self.reportFirstWindow)
        // A shell-launched instance cannot make itself key, so a `-demoShot` capture would
        // otherwise show every accent control in its inactive grey.
        .environment(\.controlActiveState, Chrome.isCapturing ? .key : controlActiveState)
    }

    /// `Tests/perf.sh` takes the wall clock before it execs the app and subtracts this, which
    /// is time-to-first-window. Printed once, only under `-perfProbe`.
    nonisolated(unsafe) private static var firstWindowReported = false
    private static func reportFirstWindow() {
        guard CommandLine.value(after: "-perfProbe") != nil, !firstWindowReported else { return }
        firstWindowReported = true
        setvbuf(stdout, nil, _IONBF, 0)
        print(String(format: "[perf] first-window-epoch %.3f", Date().timeIntervalSince1970))
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.lastError != nil }, set: { if !$0 { model.clearError() } })
    }

    @ViewBuilder
    private var mainColumn: some View {
        switch model.mainPane {
        case .status: StatusView()
        case .test: TestView()
        case .log: LogView()
        case .users: UsersView()
        case .groups: GroupsView()
        case .clients: ClientsView()
        case .policy: PolicyView()
        case .radiusServer: RadiusServerView()
        case .ldapServer: LDAPServerView()
        case .devices: DeviceSettingsView()
        case .certificates: CertificatesView()
        case .settings: SettingsView()
        }
    }
}

/// Edits are inert until applied — the servers read generated files, not the table.
///
/// **Build 25 (QA H-3, M-19, M-27).** Three corrections:
///
/// - the three processes are `@ObservedObject` here, as they are in `SidebarView`. Reading
///   `model.radius.isRunning` out of an `@ObservedObject` that is only `AppModel.shared` is the
///   staleness build 23 fixed in the sidebar and left standing here: `AppModel` does not
///   republish its children, so the button's label changed only when some *other* `@Published`
///   happened to fire. `ad.isRunning` counts too — `applyLocked`'s AD branch restarts radiusd;
/// - the message is every problem, not `problems.first` truncated to one line, and it is the
///   **blocking** ones that disable Apply (`ApplyScope`), so a half-typed new client no longer
///   locks the button on every pane;
/// - Revert asks, and says what it will discard. It is clickable only when there is something
///   to discard and never while an Apply is in flight.
struct ApplyBar: View {
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var radius = AppModel.shared.radius
    @ObservedObject private var ldap = AppModel.shared.ldap
    @ObservedObject private var ad = AppModel.shared.ad
    @State private var confirmRevert = false

    private var blocking: [String] { model.blockingProblems }

    /// The bar's own line. A blocking problem first, because that is what the button is
    /// waiting on; then a draft row's, said as the draft it is.
    private var message: String {
        if let first = blocking.first {
            return blocking.count > 1 ? "\(first) (+\(blocking.count - 1) more)" : first
        }
        let all = model.problems
        if let first = all.first {
            return all.count > 1
                ? "\(first) (+\(all.count - 1) more — not applied yet)"
                : "\(first) — not applied yet."
        }
        return "Unapplied changes — the servers still use the previous configuration."
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: blocking.isEmpty ? "pencil.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(blocking.isEmpty ? Theme.warn : Theme.err)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
                .help(model.problems.isEmpty ? message : model.problems.joined(separator: "\n"))
            Spacer(minLength: 0)
            Button("Revert") { confirmRevert = true }
                .buttonStyle(.bordered)
                .disabled(model.busy || model.revertSummary == nil)
            Button(ApplyBarGate.applyButtonTitle(radiusRunning: radius.isRunning,
                                                 directoryRunning: ldap.isRunning,
                                                 adRunning: ad.isRunning)) {
                Task { await model.apply() }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(!blocking.isEmpty || model.busy)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairlineSoft).frame(height: 0.5) }
        .confirmationDialog("Revert these changes?", isPresented: $confirmRevert) {
            Button("Revert", role: .destructive) { model.revert() }
            Button("Cancel", role: .cancel) { }
                .keyboardShortcut(.cancelAction)
        } message: {
            Text(model.revertSummary ?? "")
        }
    }
}

/// Every pane's top strip: title, one short line about the pane, then its controls. The
/// hairline under it is the only rule in a pane that is not part of a group.
///
/// **`maxWidth` keeps the title over the content** (build 21, owner: "จัด UI ให้กึ่งกลางด้วย").
/// A pane whose body is a `PaneBody` is one column filling the pane between its gutters, and
/// a title pinned to the window's left edge while its own groups sat in the middle of a 2000 pt
/// window read as two unrelated things. Passing the same bound puts them in one column. The
/// panes that are a full-width table — Users, Groups, Clients, Log — pass nothing and stay
/// edge to edge, because a table's columns *are* the layout. The hairline always spans the
/// window: it separates the strip from the pane, not the column from its margins.
///
/// **Build 22**: the column is `PaneColumnFrame`, the same modifier `PaneBody` wears, rather
/// than a second copy of the arithmetic. Two copies is exactly how the strip came to be 24 pt
/// to the right of the groups under it on a window narrower than `readable` + two gutters.
struct PaneStrip<Content: View>: View {
    var maxWidth: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            content
        }
        .paneColumn(maxWidth: maxWidth ?? .infinity)
        .frame(height: 48)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }
}

extension View {
    func paneTitle() -> some View {
        font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
    }

    func paneSubtitle() -> some View {
        font(.system(size: 12)).foregroundStyle(Theme.faintText).lineLimit(1)
    }

    func cardTitle() -> some View {
        font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
    }

    /// A one-line explanation under a control. **Bounded at `Metrics.prose`** from build 24:
    /// the column is fluid now, and a hint set across a 2360 pt window is a line the eye
    /// cannot find its way back along.
    func hint() -> some View {
        font(.system(size: 11.5))
            .foregroundStyle(Theme.faintText)
            .lineSpacing(2)
            .frame(maxWidth: Metrics.prose, alignment: .leading)
    }
}

/// **The "?" that replaced the paragraphs** (PROJECT-STATUS §14.1).
///
/// Every pane used to carry its own explanation under the controls — why a realm cannot end in
/// `.local`, what `container system start --enable-kernel-install` fetches, which of the
/// self-test's steps actually binds. All of it was true and none of it was readable: a pane a
/// person opens twenty times a day should be the controls, not the manual. The words are not
/// thrown away, they move in here and into the README; what is left beside a control is at most
/// one short line.
///
/// A popover rather than a tooltip because a tooltip cannot be selected, cannot be read on a
/// touch-free screenshot, and has no size a paragraph fits into. `.help` is set as well, so
/// hovering still says something.
struct HelpDot: View {
    let text: String
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.faintText)
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            Text(text)
                .font(.system(size: 12))
                .lineSpacing(3)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .frame(width: 340, alignment: .leading)
                .padding(16)
        }
    }
}

/// A card title with its explanation behind a "?" — the shape every pane's cards now use.
struct CardTitle: View {
    let title: String
    var help: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(title).cardTitle()
            if let help { HelpDot(text: help) }
            Spacer(minLength: 0)
        }
    }
}

/// What replaced the error alert in build 12.
///
/// An `Alert` renders whatever it is given as one block of text, which is fine for
/// "udp/1812 is already in use by nc (pid 18418)" and useless for a `radiusd -CX` dump. A user
/// hit exactly that: Apply on a lab whose servers had never started produced seventeen lines of
/// parser narration in an alert, with the one line that mattered in the middle of it. Now the
/// message is a sentence and the dump is behind a disclosure, with a button to copy it.
struct ErrorSheet: View {
    let message: String
    let detail: String?
    let dismiss: () -> Void

    /// **Open** (build 25, QA L-18). The sheet exists to show a `radiusd -CX` dump; collapsing
    /// the dump by default put the one thing it is for behind a second click.
    @State private var showDetail = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.warn)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Something went wrong")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let detail, !detail.isEmpty, detail != message {
                DisclosureGroup("Details", isExpanded: $showDetail) {
                    ScrollView {
                        Text(detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.dimText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 180)
                    .background(RoundedRectangle(cornerRadius: Metrics.field).fill(Theme.well))
                }
                .font(.system(size: 12))
                .tint(Theme.accent)
            }

            HStack {
                if let detail, !detail.isEmpty {
                    CopyButton("Copy details", value: "\(message)\n\n\(detail)", bordered: true)
                }
                Spacer(minLength: 0)
                Button("OK", action: dismiss)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.small)
        .padding(18)
        .frame(width: 520)
        // The only button here is the default one, so the cancel key needs its own (M-3).
        .sheetCancel(dismiss)
    }
}
