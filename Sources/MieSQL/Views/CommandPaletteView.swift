import SwiftUI
import MieSQLCore

/// ⌘K: one search field over connections, loaded tables and the common actions.
struct CommandPaletteView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selectedIndex = 0

    private enum Item: Identifiable {
        case connection(ConnectionProfile)
        case table(TableRef, sessionID: UUID, connectionName: String)
        case action(key: String, symbol: String, run: () -> Void)

        var id: String {
            switch self {
            case .connection(let profile): return "c-\(profile.id)"
            case .table(let table, let sessionID, _): return "t-\(sessionID)-\(table.id)"
            case .action(let key, _, _): return "a-\(key)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(app.t("palette.placeholder"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onSubmit { activate(items.first) }
            }
            .padding(14)

            Divider()

            if items.isEmpty {
                Text(app.t("palette.noResults"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List(items) { item in
                    row(item)
                        .contentShape(Rectangle())
                        .onTapGesture { activate(item) }
                }
                .listStyle(.plain)
                .frame(height: 320)
            }
        }
        .frame(width: 560)
    }

    @ViewBuilder
    private func row(_ item: Item) -> some View {
        switch item {
        case .connection(let profile):
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.displayName)
                    Text(profile.subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: profile.kind.symbolName)
                    .foregroundStyle(Theme.color(for: profile.kind))
            }
        case .table(let table, _, let connectionName):
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(table.qualifiedName)
                    Text(connectionName).font(.caption2).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: table.kind.symbolName)
                    .foregroundStyle(.secondary)
            }
        case .action(let key, let symbol, _):
            Label(app.t(key), systemImage: symbol)
        }
    }

    private var items: [Item] {
        let needle = query.trimmingCharacters(in: .whitespaces)

        var results: [Item] = []

        results += app.profiles
            .filter { needle.isEmpty || $0.displayName.localizedCaseInsensitiveContains(needle) }
            .prefix(6)
            .map { Item.connection($0) }

        for session in app.sessions {
            let matches = session.allLoadedTables
                .filter { needle.isEmpty ? false : $0.name.localizedCaseInsensitiveContains(needle) }
                .prefix(10)
            results += matches.map {
                Item.table($0, sessionID: session.id, connectionName: session.profile.displayName)
            }
        }

        let actions: [Item] = [
            .action(key: "connection.new", symbol: "plus.circle") { app.newConnection() },
            .action(key: "connection.newFromURL", symbol: "link.badge.plus") { app.newConnection(fromURL: true) },
            .action(key: "workspace.newQuery", symbol: "terminal") {
                if let sessionID = app.selectedSessionID ?? app.sessions.first?.id {
                    app.newQueryTab(sessionID: sessionID)
                }
            },
            .action(key: "history.title", symbol: "clock") { app.isShowingHistory = true }
        ]
        results += actions.filter { item in
            guard case .action(let key, _, _) = item else { return false }
            return needle.isEmpty || app.t(key).localizedCaseInsensitiveContains(needle)
        }

        return results
    }

    private func activate(_ item: Item?) {
        guard let item else { return }
        switch item {
        case .connection(let profile):
            app.connect(to: profile)
        case .table(let table, let sessionID, _):
            app.openTable(table, sessionID: sessionID)
        case .action(_, _, let run):
            run()
        }
        dismiss()
    }
}
