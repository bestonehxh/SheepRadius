import SwiftUI

/// The NAS list, build 18: a real table with the built-in 127.0.0.1 client at the top of it,
/// and the editor on the right.
///
/// Build 17 put three text fields in every row, which meant the shared secret of every client
/// in the lab was on screen (or a row of dots) whether or not anyone was editing one, and a
/// mis-click in the wrong row edited the wrong device. One row is selected at a time now, and
/// only that row has fields.
struct ClientsView: View {
    @ObservedObject private var model = AppModel.shared
    /// The selected row's id — a client's UUID string, or `builtIn` for the generated row.
    @State private var selected: String?
    private static let builtIn = "__builtin"

    /// The built-in client is not in `doc.clients` — it is generated — so the table is driven
    /// by this wrapper, with `client == nil` standing for it.
    private struct Row: Identifiable {
        let id: String
        let name: String
        let address: String
        let client: NASClient?
    }

    private var rows: [Row] {
        [Row(id: Self.builtIn, name: "localhost", address: "127.0.0.1", client: nil)]
            + model.doc.clients.map { Row(id: $0.id.uuidString, name: $0.name,
                                          address: $0.address, client: $0) }
    }

    private var selectedIndex: Int? {
        guard let selected, selected != Self.builtIn else { return nil }
        return model.doc.clients.firstIndex { $0.id.uuidString == selected }
    }

    @State private var paneWidth: CGFloat = PaneTable.minimumWindow - PaneTable.sidebar
    @State private var showInspector = false

    private var frame: PaneTable.Frame {
        PaneTable.frame(pane: paneWidth, hasTree: false, need: PaneTable.clientsNeed)
    }

    private var headline: PaneHeadline.Block { PaneHeadline.block(for: "clients") }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(eyebrow: headline.eyebrow, heading: headline.heading,
                       subtitle: headline.subtitle) {
                // **Adding a row no longer blocks the app** (build 25, QA M-18 — the rule is
                // `ApplyScope`). A client with no address and no secret is a *draft*: it is
                // listed, its problems are drawn on its own row, and Apply and every save go
                // on working on everything else until it is finished.
                Button("Add client") {
                    let client = NASClient(name: "nas\(model.doc.clients.count + 1)", address: "", secret: "")
                    model.doc.clients.append(client)
                    selected = client.id.uuidString
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                if !frame.inspectorIsColumn {
                    Button { showInspector.toggle() } label: {
                        Image(systemName: showInspector ? "sidebar.trailing" : "sidebar.right")
                    }
                    .buttonStyle(.bordered)
                    .disabled(selected == nil)
                    .help(selected == nil ? "Select a client first."
                          : showInspector ? "Hide the inspector" : "Show the inspector")
                }
            }
            .paneColumn()
            .padding(.top, 18)
            .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 12) {
                SectionTitle("Clients", note: sectionNote)
                HStack(spacing: 0) {
                    table
                    if frame.inspectorIsColumn { inspector }
                }
                .clipShape(RoundedRectangle(cornerRadius: Metrics.card))
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.card)
                        .strokeBorder(Theme.hairline, lineWidth: 0.5)
                }
                .overlay(alignment: .trailing) {
                    if !frame.inspectorIsColumn, showInspector, selected != nil {
                        inspector
                            .background(Theme.content)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(Theme.hairline).frame(width: 0.5)
                            }
                            .shadow(color: .black.opacity(0.16), radius: 10, x: -2)
                    }
                }
            }
            .padding(.horizontal, frame.gutter)
            .padding(.bottom, 18)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { paneWidth = $0 }
    }

    private var sectionNote: String {
        let count = model.doc.clients.count
        return "\(count) configured · localhost is always allowed"
    }

    @ViewBuilder
    private var inspector: some View {
        if let index = selectedIndex {
            ClientInspector(client: $model.doc.clients[index]) {
                let id = model.doc.clients[index].id
                selected = nil
                model.doc.clients.removeAll { $0.id == id }
            }
        } else if selected == Self.builtIn {
            builtInInspector
        } else {
            InspectorPlaceholder(text: "Select a client to edit its address and shared secret.")
        }
    }

    /// Three columns, proportional, no stripes (build 26 — `PaneTable.clientsColumns`).
    private var table: some View {
        let columns = PaneTable.clientsColumns(table: frame.table)
        return Table(of: Row.self, selection: $selected) {
            TableColumn("Name") { row in
                Text(row.name.isEmpty ? "—" : row.name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(row.client == nil ? Theme.faintText : Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: PaneTable.clientsMinimums[0], ideal: columns.name)
            TableColumn("IP or CIDR") { row in
                Text(row.address.isEmpty ? "not set yet" : row.address)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(row.address.isEmpty ? Theme.warn : Theme.text2)
                    .lineLimit(1)
            }
            .width(min: PaneTable.clientsMinimums[1], ideal: columns.address)
            TableColumn("Shared secret") { row in
                if let client = row.client {
                    Text(client.secret.isEmpty ? "not set yet" : "••••••••")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(client.secret.isEmpty ? Theme.warn : Theme.dimText)
                } else {
                    Text("built in — used by the Test pane")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.faintText)
                        .lineLimit(1)
                }
            }
            .width(min: PaneTable.clientsMinimums[2], ideal: columns.secret)
        } rows: {
            ForEach(rows) { row in
                TableRow(row)
                    .contextMenu {
                        if let client = row.client {
                            Button("Delete", role: .destructive) {
                                if selected == client.id.uuidString { selected = nil }
                                model.doc.clients.removeAll { $0.id == client.id }
                            }
                        } else {
                            Text("The built-in client cannot be changed.")
                        }
                    }
            }
        }
        .plainTable()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var builtInInspector: some View {
        Inspector(title: "localhost", subtitle: "127.0.0.1") {
            Text("""
            Generated, not stored: the Test pane sends its requests from this Mac, and radiusd \
            drops a request from an address that is not a client. It cannot be edited or removed.
            """)
                .hint()
            Text("RADIUS identifies a client by the source IP of its packets. On a multi-VLAN switch that is the interface it routes out of, not necessarily its management IP.")
                .hint()
        }
    }
}

/// The editor for one NAS. The shared secret is revealed per client, not for the whole pane.
private struct ClientInspector: View {
    @ObservedObject private var model = AppModel.shared
    @Binding var client: NASClient
    let delete: () -> Void
    @State private var reveal = false

    var body: some View {
        Inspector(title: client.name.isEmpty ? "New client" : client.name,
                  subtitle: client.address) {
            InspectorField("Name") {
                TextField("nas1", text: $client.name)
            }
            InspectorField("IP or CIDR") {
                TextField("192.168.1.2 or 10.0.0.0/24", text: $client.address)
            }
            InspectorField("Shared secret") {
                HStack(spacing: 6) {
                    Group {
                        if reveal { TextField("secret", text: $client.secret) }
                        else { SecureField("secret", text: $client.secret) }
                    }
                    Button { reveal.toggle() } label: {
                        Image(systemName: reveal ? "eye.slash" : "eye").font(.system(size: 10))
                    }
                    .buttonStyle(.borderless).foregroundStyle(Theme.dimText)
                    .help(reveal ? "Hide the shared secret" : "Show the shared secret")
                    .accessibilityLabel(reveal ? "Hide the shared secret" : "Show the shared secret")
                }
            }
            // **The five CIDR rules and the secret rule, said here** (build 25, QA M-19) —
            // beside the two fields they are about, rather than only on one truncated line of
            // a bar on every other pane.
            ValidationNotes(problems: model.clientProblems(client.id))
            Toggle("Require Message-Authenticator", isOn: $client.requireMessageAuthenticator)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .help("Rejects requests that lack a Message-Authenticator (BlastRADIUS mitigation).")
            Text("A request from an unlisted IP is dropped without a reply and shows up in the Log as “Ignoring request … from unknown client”.")
                .hint()
            Button("Delete client", role: .destructive, action: delete)
                .buttonStyle(.bordered)
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .id(client.id)
    }
}
