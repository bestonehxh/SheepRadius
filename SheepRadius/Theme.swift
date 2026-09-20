import AppKit
import SwiftUI

/// Sheep-family tokens, lifted from SheepDrop's Theme.swift (design v2) so the apps read as
/// siblings. Only the accent differs per app.
///
/// **Build 18** drops Liquid Glass and goes back to the macOS system look: a vibrant sidebar,
/// a solid content ground, and grouped lists on a panel fill with hairlines — the shape System
/// Settings uses. The palette is unchanged; what went away is the glass, not the colours.
enum Theme {
    // Surfaces
    /// The ground the panes are drawn on — solid, so a grouped list reads as a raised panel
    /// against it. (Before build 18 every pane sat straight on the window's vibrancy.)
    static let content = dynamic(light: 0xF7F7F8, dark: 0x232326)
    /// A grouped list, a tile, a table body: the raised surface on top of `content`.
    static let panel = dynamic(light: 0xFFFFFF, dark: 0x2A2A2E)
    /// A table's header strip and other very light fills over `panel`.
    static let header = dynamicAlpha(light: (0x000000, 0.03), dark: (0xFFFFFF, 0.04))
    static let sidebar = dynamic(light: 0xF6F6F8, dark: 0x2C2C2E)
    static let well = dynamicAlpha(light: (0x000000, 0.045), dark: (0xFFFFFF, 0.08))

    // Text
    static let text = dynamic(light: 0x1D1D1F, dark: 0xF5F5F7)          // primary
    static let text2 = dynamic(light: 0x3A3A3C, dark: 0xD1D1D6)         // secondary
    static let dimText = dynamic(light: 0x6E6E73, dark: 0xAEAEB2)       // tertiary
    static let faintText = dynamic(light: 0x86868B, dark: 0x8E8E93)     // quaternary
    static let disabledText = dynamic(light: 0xA1A1A6, dark: 0x636366)
    /// **The tint a control wears while it cannot be used** (build 23). Plain grey, which is
    /// what an untinted disabled control looks like on macOS anyway.
    ///
    /// Build 22 relied on `.disabled` alone, and a `.switch` toggle carrying an explicit
    /// `.tint` goes on drawing that tint while disabled — measured on this Mac at
    /// `controlSize(.mini)`, a locked LDAP switch came out a slightly paler green than the
    /// live RADIUS switch above it, which in a 212 pt sidebar is not a difference anybody
    /// reads as "you cannot touch this". The owner: *"Dim เป็นเทาเลย ไม่ต้องเขียวจางๆ"*. So the tint
    /// itself goes grey.
    ///
    /// **Not `.opacity`**, which was the first attempt: it forces an AppKit-backed control
    /// into a compositing layer of its own, and the switch then drew its *off* appearance —
    /// grey track, knob on the left — over a server that was running. Caught in the build-23
    /// capture against the same shot taken from build 22.
    static let dimmedControl = dynamic(light: 0xA1A1A6, dark: 0x636366)

    // Lines / fills
    static let hairline = dynamicAlpha(light: (0x000000, 0.10), dark: (0xFFFFFF, 0.14))
    static let hairlineSoft = dynamicAlpha(light: (0x000000, 0.07), dark: (0xFFFFFF, 0.10))
    static let hover = dynamicAlpha(light: (0x000000, 0.04), dark: (0xFFFFFF, 0.07))
    static let control = dynamicAlpha(light: (0x000000, 0.055), dark: (0xFFFFFF, 0.12))
    static let selectedRow = dynamicAlpha(light: (0x000000, 0.075), dark: (0xFFFFFF, 0.10))
    /// The accent-tinted selection a sidebar row and a selected table row use.
    static let selectedAccent = dynamicAlpha(light: (0x23853D, 0.13), dark: (0x5FCB7C, 0.18))

    // Accent + status — green, matched to the app icon tile (#24883E → #196C30, hue 145°).
    static let accent = dynamic(light: 0x23853D, dark: 0x5FCB7C)
    static let ok = dynamic(light: 0x30A46C, dark: 0x4ED48A)
    static let warn = dynamic(light: 0xB8451F, dark: 0xFF8A5C)
    static let err = dynamic(light: 0xB8451F, dark: 0xFF8A5C)
    static let live = dynamic(light: 0x30D158, dark: 0x30D158)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return nsColor(isDark ? dark : light)
        })
    }

    static func dynamicAlpha(light: (UInt32, CGFloat), dark: (UInt32, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let pick = isDark ? dark : light
            return nsColor(pick.0).withAlphaComponent(pick.1)
        })
    }

    private static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// The radii and the two fixed widths every pane shares, so a grouped list, a tile and a text
/// well cannot drift apart. (`Glass` before build 18.)
enum Metrics {
    /// A grouped list, a tile, a table container.
    static let card: CGFloat = 10
    /// A text well, an inline code block, a small inset control.
    static let field: CGFloat = 8
    /// A sidebar row, a tree row, a selected table row.
    static let row: CGFloat = 6
    /// The key column of a `KeyValueRow`. Wide enough for "Synchronization account".
    static let key: CGFloat = 200
    /// The inspector column on Users / Groups / Clients. **300 from build 26** (QA L-4), and
    /// it becomes a toolbar toggle below `PaneTable.inspectorCollapseBelow` of pane rather than
    /// holding 300 pt of "Select a user to edit it." beside a table that is short of room.
    static let inspector: CGFloat = PaneTable.inspector
    /// **The height of a `Table`'s heading strip** (build 26, QA L-2d / L-9).
    ///
    /// SwiftUI will not say what it drew, so this is measured off the captures and then *given*
    /// to the one thing that has to match it — the OU tree's own header. Build 25 had the tree
    /// 22 pt out of phase with the table it was filtering, permanently, at every width; one
    /// shared constant is what stops that coming back.
    static let tableHeader: CGFloat = PaneTable.tableHeader
    /// One row of a table, and of the tree beside it.
    static let tableRow: CGFloat = PaneTable.rowPitch
    /// **One width for every control in a grouped row's value column** (build 22, owner: the
    /// Check and Server popups on the Test pane had different widths *and* different left
    /// edges). A popup hugs its longest title and a `.frame(width:)` centres it, so two rows
    /// of one group came out centred on the same point and starting nowhere near each other.
    /// `valueControl()` is that frame with `alignment: .leading`, so every popup, text field
    /// and secure field in a group starts at the same x whatever it is showing.
    static let control: CGFloat = 260
    /// A number in a grouped row — a port, a timeout, a VLAN. Narrower than `control`, and
    /// the same left edge, so a group of ports still reads as a column.
    static let numberField: CGFloat = 90
    /// A control in a sheet or in the Policy editor, where a row is nested two levels deep
    /// and 260 pt does not fit.
    static let sheetField: CGFloat = 220
    /// The label column of a sheet's rows.
    static let sheetLabel: CGFloat = 110
    /// **How wide a paragraph may get** (build 24). The column is fluid now — see
    /// `PaneColumn` — so a note row is the one thing that still needs a bound, because prose
    /// set across a 2360 pt window cannot be read. Controls, tables and tiles are not prose.
    static let prose: CGFloat = PaneColumn.prose
    /// The title-bar band **both** columns reserve, so a pane title starts level with the
    /// sidebar's first heading.
    static let titleBar: CGFloat = PaneColumn.titleBar
    static let titleBarFullScreen: CGFloat = PaneColumn.titleBarFullScreen
}

/// Behind-window vibrancy — the standard macOS sidebar material. The window's own background,
/// so the sidebar is translucent the way every system app's is; the main column paints
/// `Theme.content` over it.
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}
