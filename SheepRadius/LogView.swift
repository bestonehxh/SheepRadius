import AppKit
import UniformTypeIdentifiers
import SwiftUI

struct LogView: View {
    @ObservedObject private var model = AppModel.shared
    /// What is in the box. `applied` is what actually filters — see the debounce below.
    @State private var filter = ""
    @State private var applied = ""
    /// AD DC only: keep just the domain controller's `Auth:` lines. A DC at
    /// `log level = 1 auth_audit:3` still prints plenty that is not an authentication, and
    /// this is the pane a person opens when a Wi-Fi client will not log in.
    @State private var authOnly = false

    /// The feed lives in the model, not here: starting a server moves it. See `LogSourcePolicy`.
    private var source: LogSource { model.logSource }

    /// **What Copy and Save… put on the clipboard or on disk** (build 25, QA M-6).
    ///
    /// The **visible** feed, exactly as it is drawn: the filter applied, the AD pane's Auth
    /// only applied, the clock localised and the passwords masked unless Show passwords is on.
    /// Anything else would be a second, silently different rendering of the same log — and
    /// masking that the pane applies and the file does not is how a cleartext password ends up
    /// in an attachment.
    private var visibleText: String {
        var lines: [LogLine]
        switch source {
        case .adDC:
            lines = model.ad.log
            if authOnly { lines = lines.filter { ADAuthAudit.isAuthLine($0.text) } }
        case .ldap: lines = model.ldap.log
        case .radius: lines = model.radius.log
        }
        if !applied.isEmpty { lines = lines.filter { matches($0.text, applied) } }
        return lines
            .map { LogRedaction.redact(LogTime.localized($0.text), show: model.showPasswordsInLogs) }
            .joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(PaneHeadline.block(for: "log"))
                .paneColumn()
                .padding(.top, 18)
                .padding(.bottom, 12)

            PaneStrip {
                Picker("", selection: Binding(get: { model.logSource },
                                              set: { model.chooseLogSource($0) })) {
                    ForEach(LogSource.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 230)
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                Spacer(minLength: 0)
                if source == .radius { debugToggle }
                if source == .adDC { authOnlyToggle }
                showPasswordsToggle
                // **A log you can take away** (build 25, QA M-6). There was no copy button,
                // no context menu and no Save on any of the three feeds — the one pane whose
                // whole product is text a person sends to somebody else.
                CopyButton("Copy", value: visibleText, bordered: true)
                    .disabled(visibleText.isEmpty)
                Button("Save…") { save() }
                    .buttonStyle(.bordered)
                    .disabled(visibleText.isEmpty)
                Button("Clear") { clear() }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)

            // The DC is not a ServerProcess — it is a container this app does not own — so its
            // log is rendered from the controller's own buffer, in the same shape.
            switch source {
            case .adDC:
                ADLogLines(filter: applied, authOnly: authOnly,
                           showPasswords: model.showPasswordsInLogs).id(source)
            case .ldap:
                LogLines(server: model.ldap, filter: applied,
                         showPasswords: model.showPasswordsInLogs).id(source)
            case .radius:
                LogLines(server: model.radius, filter: applied,
                         showPasswords: model.showPasswordsInLogs).id(source)
            }
        }
        // Filtering re-scans every line in the ring, so it must not run on every keystroke:
        // thousands of lines × one search each, per character typed, on the main actor.
        .task(id: filter) {
            guard filter != applied else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            applied = filter
        }
    }

    private var debugToggle: some View {
        Toggle("Debug (-xx)", isOn: Binding(
            get: { model.applied.settings.radiusDebug },
            set: { on in Task { await model.setRadiusDebug(on) } }))
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .help("Full per-condition tracing and TLS session details. It roughly halves the request rate radiusd can sustain, so it is off unless a fault is being traced. Turning it on or off restarts the RADIUS server.")
    }

    /// Build 20, audit N-4. The mask is applied where the row is drawn, so this only
    /// re-renders — nothing has been thrown away and nothing has to be re-read.
    private var showPasswordsToggle: some View {
        Toggle("Show passwords", isOn: $model.showPasswordsInLogs)
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .help("Show the cleartext credentials the servers print. Off for every new session.")
    }

    private var authOnlyToggle: some View {
        Toggle("Auth only", isOn: $authOnly)
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .help("Only the domain controller's authentication lines. NT_STATUS_OK is green, any other NT_STATUS_ is red. Authorisation (“AuthZ”) lines are left out: Samba prints one for each successful authentication it has already reported.")
    }

    /// The visible feed, as a `.log` file. Named after the source and the day, because the
    /// first thing anybody does with one of these is put it beside another one.
    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "log") ?? .plainText, .plainText]
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = "SheepRadius-\(source.rawValue)-\(LabManifest.dayStamp(Date())).log"
        panel.title = "Save the log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(visibleText.utf8).write(to: url, options: .atomic)
        } catch {
            model.report(error.localizedDescription)
        }
    }

    private func clear() {
        switch source {
        case .radius: model.radius.clearLog()
        case .ldap: model.ldap.clearLog()
        case .adDC: model.ad.clearLog()
        }
    }
}

/// A case-insensitive substring test that is **not** locale-aware.
///
/// `localizedCaseInsensitiveContains` runs the full ICU collation for every line of the ring;
/// this is the same answer for a log filter and is measurably cheaper.
private func matches(_ text: String, _ filter: String) -> Bool {
    text.range(of: filter, options: .caseInsensitive) != nil
}

private struct ADLogLines: View {
    @ObservedObject private var ad = AppModel.shared.ad
    let filter: String
    let authOnly: Bool
    let showPasswords: Bool

    private var lines: [LogLine] {
        var out = ad.log
        if authOnly { out = out.filter { ADAuthAudit.isAuthLine($0.text) } }
        if !filter.isEmpty { out = out.filter { matches($0.text, filter) } }
        return out
    }

    var body: some View {
        LogScroll(lines: lines, showPasswords: showPasswords, empty: ad.log.isEmpty
                  ? "No output yet — start the domain controller."
                  // Plain prose: a ternary of two literals is a String, not a literal, so
                  // Text would draw any Markdown markup instead of applying it.
                  : "No authentication lines yet. The domain controller records them only at log level 1 auth_audit:3.")
    }
}

private struct LogLines: View {
    @ObservedObject var server: ServerProcess
    let filter: String
    let showPasswords: Bool

    private var lines: [LogLine] {
        filter.isEmpty ? server.log : server.log.filter { matches($0.text, filter) }
    }

    var body: some View {
        LogScroll(lines: lines, showPasswords: showPasswords,
                  empty: "No output yet — start the server.")
    }
}

/// **The scrolling half, shared by all three feeds** (PROJECT-STATUS §14.3).
///
/// Opening the pane puts you at the newest line, Follow is on, scrolling up turns it off, and a
/// "Jump to latest" pill turns it back on. Three details are load-bearing:
///
/// - The initial scroll is a `.task`, not an `onChange`: a pane opened onto a log that is
///   already full gets no change to react to, which is why it used to open at line 1 — the
///   owner's complaint in §14.3.
/// - It follows the **filtered** list's last line, not the ring's. With a filter in the box the
///   newest line in the ring is usually not on screen at all, and `scrollTo` on an id that is
///   not in the stack does nothing at all, silently.
/// - Follow is turned off by *where the view is*, not by guessing at gestures: any scroll that
///   leaves the bottom pauses it and returning to the bottom resumes it, so the wheel, the
///   scrollbar, a trackpad flick and the pill all behave the same way.
private struct LogScroll: View {
    let lines: [LogLine]
    let showPasswords: Bool
    let empty: String
    @State private var follow = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(lines) { line in
                        LogRow(line: line, showPasswords: showPasswords)
                    }
                }
                .padding(14)
            }
            // A log is read full-bleed, like Console's — but on the panel fill, so the strip
            // above it and the window behind it are visibly not part of the output.
            .background(Theme.panel)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // Within a line and a half of the bottom counts as "at the bottom": the
                // content grows under the scroller, and an exact comparison would drop Follow
                // on its own the first time a line arrived.
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - 24
            } action: { _, atBottom in
                follow = atBottom
            }
            .task {
                // One runloop turn for the LazyVStack to build its rows, then land on the end.
                try? await Task.sleep(for: .milliseconds(50))
                if let last = lines.last?.id { proxy.scrollTo(last, anchor: .bottom) }
            }
            .onChange(of: lines.last?.id) { _, last in
                if follow, let last { proxy.scrollTo(last, anchor: .bottom) }
            }
            .overlay(alignment: .bottom) {
                if !follow, !lines.isEmpty {
                    Button {
                        follow = true
                        if let last = lines.last?.id {
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                            .font(.system(size: 11.5))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .controlSize(.small)
                    .padding(.bottom, 12)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: follow)
        }
        .overlay {
            if lines.isEmpty { Text(empty).hint() }
        }
    }
}

/// One line. The colour comes from `LogLine.kind` and the clock from `LogTime` — both computed
/// here rather than stored when the line arrived, because a `LazyVStack` only ever builds the
/// rows that are on screen (about forty) while the ring holds thousands, and build 12 measured
/// what doing this work per *arriving* line costs: five times slower per RADIUS request.
private struct LogRow: View {
    let line: LogLine
    let showPasswords: Bool

    var body: some View {
        Text(LogRedaction.redact(LogTime.localized(line.text), show: showPasswords).nonEmpty ?? " ")
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(Self.color(line.kind))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(line.id)
    }

    static func color(_ kind: LogLine.Kind) -> Color {
        switch kind {
        case .accept: Theme.ok
        case .reject: Theme.err
        case .note: Theme.accent
        case .plain: Theme.text2
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
