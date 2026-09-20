import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Grouped lists
//
// Build 18's one structural idea: **a pane is groups of rows, not a stack of cards.** A group
// is a title plus a panel with hairlines between its rows — the shape System Settings uses, and
// the shape the redesign mock (`Screenshots/redesign-mock.html`, layout A) draws. Everything
// that used to be a floating glass card with its own padding is one of these now, so a value
// lines up with the value three groups below it instead of each card inventing its own column.

/// A panel with a hairline between every child. Children are laid out by `_VariadicView`, so a
/// caller writes plain rows — `GroupedList { row; row; ForEach… }` — and the separators appear
/// between them, never above the first or below the last.
struct GroupedList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        _VariadicView.Tree(SeparatedRows()) { content }
            .background(RoundedRectangle(cornerRadius: Metrics.card).fill(Theme.panel))
            .clipShape(RoundedRectangle(cornerRadius: Metrics.card))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.card)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SeparatedRows: _VariadicView_MultiViewRoot {
    @ViewBuilder func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(alignment: .leading, spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != last {
                    Rectangle().fill(Theme.hairlineSoft).frame(height: 0.5)
                }
            }
        }
    }
}

/// A titled group: the small uppercase-ish caption, then the panel. The caption is the only
/// heading a pane has below its title strip.
struct PaneGroup<Content: View>: View {
    let title: String
    var help: String?
    /// A control that belongs to the group rather than to a row — "Clear", "Refresh".
    var accessory: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String, help: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.help = help
        self.accessory = nil
        self.content = content()
    }

    init(_ title: String, help: String? = nil, accessory: some View,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.help = help
        self.accessory = AnyView(accessory)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).groupTitle()
                if let help { HelpDot(text: help) }
                Spacer(minLength: 0)
                if let accessory { accessory.controlSize(.small) }
            }
            .padding(.horizontal, 2)
            GroupedList { content }
        }
    }
}

/// One `key — value` row. The key column is a fixed width across the whole app, so the values
/// of two different groups sit on the same line.
struct KeyValueRow<Value: View>: View {
    let key: String
    var help: String?
    var keyWidth: CGFloat = Metrics.key
    @ViewBuilder var value: Value

    init(_ key: String, help: String? = nil, keyWidth: CGFloat = Metrics.key,
         @ViewBuilder value: () -> Value) {
        self.key = key
        self.help = help
        self.keyWidth = keyWidth
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 4) {
                Text(key)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                if let help { HelpDot(text: help) }
                Spacer(minLength: 0)
            }
            .frame(width: keyWidth, alignment: .leading)
            value
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row that is one sentence wide — a note under a group's rows, an inline warning.
struct NoteRow: View {
    let text: String
    var systemImage: String?
    var tint: Color = Theme.faintText

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 11)).foregroundStyle(tint)
            }
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(tint == Theme.faintText ? Theme.faintText : Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
                .proseWidth()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row whose content is laid out by the caller but that still gets the group's insets.
struct PlainRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) { content }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Copying, and saying so

/// **The one copy control** (build 24). Icon-only in a row, or a bordered button with a word.
///
/// The value is a closure rather than a string because three callers generate theirs at press
/// time — the whole device table as tab-separated rows, the generated unlang, an error and its
/// details — and capturing that at build time would copy whatever the pane held when it was
/// last laid out.
struct CopyButton: View {
    private let value: () -> String
    private let title: String?
    private let bordered: Bool
    /// nil inherits the surrounding font, which is what the AD rows and the device table want.
    private let iconSize: CGFloat?
    private let help: String

    @State private var copied = false
    /// The revert, held so a second press restarts the clock instead of letting the first
    /// press's timer cut the second one short.
    @State private var revert: Task<Void, Never>?

    init(_ title: String? = nil, value: @autoclosure @escaping () -> String,
         bordered: Bool = false, iconSize: CGFloat? = 10, help: String = "Copy") {
        self.value = value
        self.title = title
        self.bordered = bordered
        self.iconSize = iconSize
        self.help = help
    }

    private var isCopied: Bool { copied || CopyFeedback.demoHeld }

    @ViewBuilder
    var body: some View {
        if bordered {
            Button(action: copy) { label }.buttonStyle(.bordered).help(help)
        } else {
            Button(action: copy) { label }.buttonStyle(.borderless).help(help)
        }
    }

    private var label: some View {
        HStack(spacing: 4) {
            Image(systemName: CopyFeedback.symbol(copied: isCopied))
                .font(iconSize.map { Font.system(size: $0) })
                // The two glyphs are not the same width, so anything beside the icon would
                // shift by a point or two as it changed. A fixed slot keeps the row still.
                .frame(width: iconSize.map { $0 + 4 })
            if let title = CopyFeedback.title(title, copied: isCopied) {
                Text(title)
            }
        }
        .foregroundStyle(isCopied ? Theme.accent : (bordered ? Color.primary : Theme.dimText))
        .accessibilityLabel(isCopied ? CopyFeedback.word : (title ?? "Copy"))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value(), forType: .string)
        copied = true
        // Cancelled and restarted rather than left to run, so a second press gets its own
        // 1.2 s instead of being cut short by the first press's timer.
        revert?.cancel()
        revert = Task {
            try? await Task.sleep(for: .seconds(CopyFeedback.hold))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

// MARK: - Values

/// A monospaced value with a copy button. Everything in this app is something that gets pasted
/// into a device's form, so selecting it by hand is the failure mode to design out.
struct CopyableValue: View {
    let value: String
    var mono = true
    var prominent = false
    /// A filesystem path is one line with its middle elided — it is copied, not read, and a
    /// four-line wrap of `~/Library/Application Support/…` pushes everything under it down.
    var path = false

    var body: some View {
        HStack(spacing: 8) {
            Text(value)
                .font(.system(size: prominent ? 15 : 12,
                              weight: prominent ? .medium : .regular,
                              design: mono ? .monospaced : .default))
                .foregroundStyle(prominent ? Theme.text : Theme.text2)
                .textSelection(.enabled)
                .lineLimit(path ? 1 : nil)
                .truncationMode(.middle)
                .help(path ? value : "")
                .fixedSize(horizontal: false, vertical: !path)
            CopyButton(value: value, help: "Copy \(value)")
        }
    }
}

/// A read-only monospaced value, no copy button.
struct MonoValue: View {
    let value: String
    var tint: Color = Theme.text2

    var body: some View {
        Text(value)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(tint)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Accept / Reject / On / Off — the only place colour means anything in a table.
struct StatusPill: View {
    enum Kind { case ok, bad, warn, neutral }
    let text: String
    var kind: Kind = .neutral

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(background))
            .fixedSize()
    }

    private var foreground: Color {
        switch kind {
        case .ok: Theme.ok
        case .bad: Theme.err
        case .warn: Theme.warn
        case .neutral: Theme.dimText
        }
    }

    private var background: Color {
        switch kind {
        case .ok: Theme.ok.opacity(0.13)
        case .bad: Theme.err.opacity(0.13)
        case .warn: Theme.warn.opacity(0.13)
        case .neutral: Theme.control
        }
    }
}

/// A Status tile: caption, a big number or word, one line under it.
struct StatTile: View {
    let caption: String
    let value: String
    var valueTint: Color = Theme.text
    var mono = false
    var detail: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.faintText)
            Text(value)
                .font(.system(size: mono ? 16 : 19, weight: .semibold,
                              design: mono ? .monospaced : .default))
                .foregroundStyle(valueTint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .textSelection(.enabled)
            Text(detail.isEmpty ? " " : detail)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.dimText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: Metrics.card).fill(Theme.panel))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.card).strokeBorder(Theme.hairline, lineWidth: 0.5)
        }
    }
}

// MARK: - Pane frames

/// **The pane column, in one place** (build 24 — `PaneColumn` has the arithmetic and the two
/// bugs it has closed).
///
/// Build 22's order stands and is the fix for the overflow: the padding is **outside** the
/// width bound, so the content sees `available − 2 · gutter` rather than fighting it. Build 24
/// removes the bound and makes the gutter a function of the pane instead, so the column is
/// simply everything that is not gutter.
///
/// The width is measured rather than assumed: `.onGeometryChange` reports the frame of the
/// *modified* view, which is always the full pane (the outer frame is `.infinity`), so there
/// is no feedback loop between the padding and the measurement. The first layout pass draws at
/// `minGutter` and the second at the real one — one frame, invisible, and correct at the 980 pt
/// minimum either way.
///
/// A pane's title strip and its body both wear this, which is what keeps the title above its
/// own groups at every width.
struct PaneColumnFrame: ViewModifier {
    /// Kept for the table panes, which pass `.infinity` and always did. Nothing else bounds
    /// its column any more.
    var maxWidth: CGFloat = .infinity

    @State private var available: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PaneColumn.gutter(available: available))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
    }
}

extension View {
    /// **One truncation strategy per kind of value** (build 26, QA L-9 / L-10).
    ///
    /// The sweep found both strategies in one table: `Settings ▸ Components` wrapped some long
    /// paths to two lines and middle-elided another, and the OU tree cut names at the **tail**
    /// so `Domain Controllers` and `Domain Computers` were both `Domain C…`. The rule is one
    /// line: **a name, a path or a DN elides in the middle**, because both ends identify it and
    /// the middle does not; **prose elides at the tail**, because a sentence is read from the
    /// front; and prose that has room simply wraps.
    func identifierText() -> some View { lineLimit(1).truncationMode(.middle) }

    /// A sentence on one line: cut at the end, which is where a reader stops anyway.
    func proseText() -> some View { lineLimit(1).truncationMode(.tail) }

    /// The pane column every pane shares.
    func paneColumn(maxWidth: CGFloat = .infinity) -> some View {
        modifier(PaneColumnFrame(maxWidth: maxWidth))
    }

    /// **A paragraph inside a row** (build 24). The column is fluid, so the one thing that
    /// still needs a bound is prose — ~80 characters, after which a line is hard to come back
    /// from. Left-aligned inside whatever the row gives it.
    func proseWidth() -> some View {
        frame(maxWidth: Metrics.prose, alignment: .leading)
    }

    /// **A control in a grouped row's value column** (build 22).
    ///
    /// `alignment: .leading` is the whole of it. A menu `Picker` on macOS is as wide as its
    /// longest title and no wider, so a bare `.frame(width: 260)` *centred* it: the Test
    /// pane's Check and Server popups came out 181 pt and 158 pt wide, both centred on
    /// 602 pt, which is two controls in one group agreeing about nothing. Left-aligned, they
    /// start at the same x whatever they are showing, and a text field beside them fills the
    /// whole slot so the right edges line up too.
    func valueControl(_ width: CGFloat = Metrics.control) -> some View {
        frame(width: width, alignment: .leading)
    }

    /// A number in the same column: its own shared width, the same left edge.
    func valueNumber(_ width: CGFloat = Metrics.numberField) -> some View {
        frame(width: width, alignment: .leading)
    }
}

/// A pane's scrolling body: one column of groups, 18 pt apart, filling the pane between its
/// gutters (build 24 — until build 23 it was bounded at 900 pt and centred, which on a 2360 pt
/// window left more empty pane than column).
struct PaneBody<Content: View>: View {
    var spacing: CGFloat = 18
    var maxWidth: CGFloat = .infinity
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) { content }
                .padding(.vertical, 18)
                .paneColumn(maxWidth: maxWidth)
        }
    }
}

/// The right-hand column on Users / Groups / Clients: select a row on the left, edit here, and
/// the save indicator appears as it always has (`DirectoryBanner` / the pane's own line).
struct Inspector<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                    if let subtitle, !subtitle.isEmpty {
                        HStack(spacing: 6) {
                            Text(subtitle)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.faintText)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            CopyButton(value: subtitle, iconSize: 9)
                        }
                    }
                }
                content
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: Metrics.inspector)
        .background(Theme.content)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.hairline).frame(width: 0.5) }
    }
}

/// A labelled control inside an inspector: caption above, control below, full width.
struct InspectorField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.faintText)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The placeholder where an inspector would be, so the column does not appear and disappear as
/// rows are selected — that jump is what made the old bottom-mounted Properties panel jarring.
struct InspectorPlaceholder: View {
    let text: String

    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.faintText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Spacer()
        }
        .frame(width: Metrics.inspector)
        .background(Theme.content)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.hairline).frame(width: 0.5) }
    }
}

// MARK: - Table chrome

extension View {
    /// A `Table` sitting in a group: panel fill, hairline border, clipped corners. `Table`
    /// draws its own header strip and row separators, so it does not go inside a `GroupedList`.
    func tablePanel(minHeight: CGFloat = 120) -> some View {
        frame(minHeight: minHeight)
            .background(RoundedRectangle(cornerRadius: Metrics.card).fill(Theme.panel))
            .clipShape(RoundedRectangle(cornerRadius: Metrics.card))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.card)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            }
    }

    /// What `glassCard()` was: a self-contained block with its own padding. Kept for the few
    /// places a group of mixed controls is not a list of rows (the AD sections, mostly).
    func panelCard(cornerRadius: CGFloat = Metrics.card) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius).fill(Theme.panel))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            }
    }

    /// A group caption.
    func groupTitle() -> some View {
        font(.system(size: 11.5, weight: .semibold))
            .kerning(0.2)
            .foregroundStyle(Theme.faintText)
    }
}

/// An empty table's message, shown over the panel rather than instead of it, so the column
/// headings stay readable.
struct TableEmpty: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.faintText)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Every sheet answers the cancel key

/// **⌘. must not reach the menu bar from inside a sheet** (build 25, QA M-3).
///
/// A SwiftUI `.sheet` is window-modal, and a window-modal sheet with no `.cancelAction` in it
/// passes ⌘. and Esc straight through to the app's own commands — where, until this build,
/// ⌘. was **Stop All Servers**. So a ⌘. meant to dismiss the password sheet, the error sheet or
/// the import sheet stopped both servers instead, behind the sheet, with nothing on screen to
/// say it had happened. Stop All has moved to ⌘⇧. as well; this is the other half, so that
/// pressing the key in a sheet does the ordinary thing rather than nothing.
///
/// A hidden button rather than `role: .cancel` on the visible one: every one of these sheets
/// has a prominent default button, and a `Button` carries one `keyboardShortcut`.
private struct SheetCancelKey: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content.background {
            Button("Cancel", action: action)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// Bind Esc and ⌘. inside a sheet that has no visible Cancel to bind them.
    func sheetCancel(_ action: @escaping () -> Void) -> some View {
        modifier(SheetCancelKey(action: action))
    }
}

// MARK: - What a Choose… panel will take

/// **Every `NSOpenPanel` in the app says what it is looking for** (build 25, QA L-6).
///
/// All four Choose… panels set no `allowedContentTypes`, so somebody hunting for a `.p12`
/// was offered every file on the Mac and learned which ones were wrong from an openssl error
/// two steps later. `allowsOtherFileTypes` stays on: a PEM saved with an unusual extension is
/// a perfectly good certificate, and a filter that refuses one is worse than none.
enum CertificateFileTypes {
    /// `.pem`, `.crt`, `.cer`, `.der` — anything that could hold a certificate.
    static let certificate: [UTType] = [.x509Certificate, .pem, .data]
    /// A private key, or a `.p12` / `.pfx` that carries the key and the certificate together.
    static let keyOrBundle: [UTType] = [.pkcs12, .pem, .data]
    static let any: [UTType] = [.data]
}

extension UTType {
    /// There is no system type for a PEM file, and `public.x509-certificate` does not claim
    /// `.pem` — which is the extension this app writes every certificate it makes with.
    static let pem = UTType(filenameExtension: "pem") ?? .data
}

// MARK: - Validation, beside the control it is about

/// **What `problems.first` on one truncated line could never say** (build 25, QA M-19).
///
/// The five CIDR rules, the shared-secret rule, the reply-attribute parser and all twenty-one
/// rule-condition checks produce good, specific sentences, and until this build every one of
/// them reached the person the same way: `Validation.problems(in: doc).first`, `lineLimit(1)`,
/// in a bar at the top of whichever pane happened to be open. A rule with two faults showed
/// one of them, half of it, somewhere else.
///
/// `Validation.Site` carries the row each sentence came out of; this draws them where the row
/// is. Nothing else changed — same checks, same words, same order.
struct ValidationNotes: View {
    let problems: [String]

    var body: some View {
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(problems, id: \.self) { problem in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.warn)
                            .padding(.top, 1)
                        Text(problem)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: Metrics.prose, alignment: .leading)
        }
    }
}

// MARK: - A save panel opened from inside a sheet

/// **`runModal()` from inside a presented sheet is the wrong call** (build 25, QA L-16).
///
/// `ClientCertificateSheet` runs a save panel while it is itself a window-modal sheet, so
/// AppKit is asked to run a second modal session on top of one that is already up. What it
/// does with that is version-dependent — on this macOS the panel appears, detached from the
/// window it belongs to, and the sheet behind it stops drawing its hover states; the tidy
/// answer has always been to attach the panel to the window as a sheet of its own.
///
/// Used only where a panel really is opened from inside a sheet. A panel opened from a pane —
/// Certificates ▸ Export, Settings ▸ Export lab, Log ▸ Save — has no modal session over it and
/// `runModal()` there is correct and stays.
enum SheetSavePanel {
    /// Present `panel` as a sheet on the front window and call back with the chosen URL, or
    /// with nil when it was cancelled. Falls back to `runModal()` when there is no window to
    /// hang it on, which is the case under `-demoShot`.
    static func present(_ panel: NSSavePanel, completion: @escaping (URL?) -> Void) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            completion(panel.runModal() == .OK ? panel.url : nil)
            return
        }
        panel.beginSheetModal(for: window) { response in
            completion(response == .OK ? panel.url : nil)
        }
    }
}

/// `.sheeplab` — a zip by construction, and the extension the Export panel offers and the
/// Import panel filters on (build 25, QA L-6).
enum LabFileTypes {
    static let lab: [UTType] = [UTType(filenameExtension: "sheeplab") ?? .zip, .zip]
}

// MARK: - The editorial heading block (build 26, the owner-approved mock)

/// **An eyebrow, a heading that states the state, a subtitle** — what replaced the 15 pt pane
/// title as the first thing on a pane.
///
/// The words come from `PaneHeadline`, which is pure and is what the unit suite pins; this is
/// only their typography. Three sizes, from the mock: 11 pt letter-spaced and muted, ~30 pt
/// semibold, 12.5 pt secondary.
///
/// The heading is bounded at `headingMeasure`, which is this file's version of
/// `text-wrap: balance` — SwiftUI has no such thing, and a 30 pt line allowed to run across a
/// 2019 pt column is the same mistake `Metrics.prose` exists to stop one size down. Everything
/// else in the pane is still fluid.
struct PaneHeader<Actions: View>: View {
    let eyebrow: String
    let heading: String
    var subtitle: String = ""
    @ViewBuilder var actions: Actions

    /// Two short lines of a 30 pt heading, which is what "balance" means here.
    static var headingMeasure: CGFloat { 620 }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(eyebrow.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(1.3)
                    .foregroundStyle(Theme.faintText)
                Text(heading)
                    .font(.system(size: 29, weight: .semibold))
                    .kerning(-0.3)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Self.headingMeasure, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.top, 1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 720, alignment: .leading)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 12)
            // **The controls are not negotiable and the heading is** (build 26). Without
            // this the `HStack` shared the squeeze evenly and a 980 pt Users pane came out
            // with three buttons reading "Refr…", "New…" and "New…" — the one thing a control
            // strip may never do. `fixedSize` gives them their natural width and leaves the
            // heading block, which wraps, to take what is left.
            HStack(spacing: 8) { actions }
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension PaneHeader where Actions == EmptyView {
    init(_ block: PaneHeadline.Block) {
        self.init(eyebrow: block.eyebrow, heading: block.heading,
                  subtitle: block.subtitle) { EmptyView() }
    }

    init(eyebrow: String, heading: String, subtitle: String = "") {
        self.init(eyebrow: eyebrow, heading: heading, subtitle: subtitle) { EmptyView() }
    }
}

/// **A section title with a right-hand note** (build 26, the mock): "Joined computers" and,
/// level with it on the right, "from the domain controller".
///
/// Bigger than `groupTitle()` — 16.5 pt against 11.5 — because in the mock these are the only
/// headings a pane has below its own, and the note is what the old `PaneGroup` help dot said
/// in a popover nobody opened.
struct SectionTitle<Accessory: View>: View {
    let title: String
    var note: String = ""
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 16.5, weight: .semibold))
                .foregroundStyle(Theme.text)
            if !note.isEmpty {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faintText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            accessory.controlSize(.small)
        }
        .padding(.horizontal, 2)
    }
}

extension SectionTitle where Accessory == EmptyView {
    init(_ title: String, note: String = "") {
        self.init(title: title, note: note) { EmptyView() }
    }
}

/// A section: its title, the note on the right, and whatever it contains.
struct PaneSection<Content: View, Accessory: View>: View {
    let title: String
    var note: String = ""
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: title, note: note) { accessory }
            content
        }
    }
}

extension PaneSection where Accessory == EmptyView {
    init(_ title: String, note: String = "", @ViewBuilder content: () -> Content) {
        self.init(title: title, note: note, accessory: { EmptyView() }, content: content)
    }
}

/// **A read-only fact: the key on the left, the value hard against the right, the copy button
/// at the end of the value** (build 26, the mock).
///
/// Not a variant of `KeyValueRow`, which holds *controls* — a popup or a text field pushed to
/// the right edge of a 2019 pt column would be a control nobody can find, and `valueControl()`
/// exists precisely to keep those at one left edge. Two different rows because they are two
/// different things.
struct FactRow: View {
    let key: String
    let value: String
    var help: String?
    var mono = true
    var copyable = true
    /// Give a group a shared label column when its values are meant to be read beside their
    /// labels rather than compared at the far edge of the pane. nil keeps the mock's
    /// edge-to-edge fact layout used by short summary cards.
    var keyWidth: CGFloat? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            HStack(spacing: 4) {
                Text(key)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                if let help { HelpDot(text: help) }
            }
            .frame(width: keyWidth, alignment: .leading)
            if keyWidth == nil { Spacer(minLength: 12) }
            // A DN, a URL and an address are identifiers: one line, elided in the middle, the
            // whole of it in the tooltip and on the pasteboard (L-10).
            Text(value)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(keyWidth == nil ? .trailing : .leading)
                .textSelection(.enabled)
                .modifier(FactValueTruncation(mono: mono))
                .help(value)
            if copyable { CopyButton(value: value, help: "Copy \(value)") }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FactValueTruncation: ViewModifier {
    let mono: Bool

    func body(content: Content) -> some View {
        if mono {
            content.identifierText()
        } else {
            content.fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The same row with a pill instead of a value — "RADIUS uses this directory · Yes".
struct FactPillRow: View {
    let key: String
    let text: String
    var kind: StatusPill.Kind = .neutral

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(key)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
            Spacer(minLength: 12)
            StatusPill(text: text, kind: kind)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Tables: plain rows, hairlines, and one sentence when there is nothing in them

extension View {
    /// **No alternating row stripes, anywhere** (build 26, QA L-5 / L-7; the owner: *"สีสลับ 2 สี
    /// ไม่สวย"*).
    ///
    /// `alternatesRowBackgrounds: true` was on every table in the app, and it does two bad
    /// things at once. It paints the whole table's width — at 2360 that was 1738 pt of stripe
    /// with 942 pt of columns in it — and it goes on painting *below the last row*, so three
    /// real rows were followed by twenty-five empty ones filling the pane, which reads as
    /// content that failed to load rather than as an empty area. At 1180 and wider the inset
    /// style draws them as rounded pills with gaps, which makes it worse.
    ///
    /// Plain rows separated by the style's own hairlines is what replaced it, and it is what
    /// every table in this app now uses: Users, Groups, Clients, Recent authentications, Test's
    /// Recent, and Joined computers.
    func plainTable() -> some View {
        tableStyle(.inset(alternatesRowBackgrounds: false))
    }
}

/// **An empty table is one centred sentence** (build 26, QA L-7).
///
/// Build 25 hung the sentence 20–30 pt below the header and left the striped placeholder rows
/// behind it — on Status that produced a header, two empty pill rows, and the words "No
/// authentications recorded…" floating between them. With the stripes gone the area is plain,
/// and the sentence belongs in the middle of it.
struct TableEmptyOverlay<Extra: View>: View {
    let text: String
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(spacing: 10) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.faintText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: Metrics.prose)
                .padding(.horizontal, 24)
            extra
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The heading strip stays readable: the sentence is centred in what is left under it.
        .padding(.top, Metrics.tableHeader)
    }
}

extension TableEmptyOverlay where Extra == EmptyView {
    init(_ text: String) { self.init(text: text) { EmptyView() } }
}
