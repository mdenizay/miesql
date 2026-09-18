import SwiftUI
import MieSQLCore

/// The connection tree. Connections are grouped by their optional folder, and each open
/// connection expands into databases, schemas and tables, loaded on demand.
struct SidebarView: View {
    @EnvironmentObject private var app: AppModel
    @State private var filterText = ""

    var body: some View {
        VStack(spacing: 0) {
            List {
                if app.profiles.isEmpty {
                    emptyState
                } else {
                    ForEach(folders, id: \.self) { folder in
                        if folder.isEmpty {
                            ForEach(profiles(in: folder)) { profile in
                                connectionRow(profile)
                            }
                        } else {
                            Section(folder) {
                                ForEach(profiles(in: folder)) { profile in
                                    connectionRow(profile)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $filterText, placement: .sidebar, prompt: app.t("sidebar.filter"))

            Divider()
            footer
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(app.t("connection.new")) { app.newConnection() }
                    Button(app.t("connection.newFromURL")) { app.newConnection(fromURL: true) }
                } label: {
                    Label(app.t("connection.new"), systemImage: "plus")
                } primaryAction: {
                    app.newConnection()
                }
                .help(app.t("connection.new"))
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func connectionRow(_ profile: ConnectionProfile) -> some View {
        let session = app.sessions.first { $0.id == profile.id }

        Group {
            if let session, session.status.isConnected {
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { app.selectedSessionID == profile.id },
                        set: { app.selectedSessionID = $0 ? profile.id : nil }
                    )
                ) {
                    ForEach(session.databases) { database in
                        databaseRow(database, session: session)
                    }
                } label: {
                    connectionLabel(profile, session: session)
                }
            } else {
                connectionLabel(profile, session: session)
            }
        }
        .contextMenu { connectionMenu(profile, session: session) }
    }

    private func connectionLabel(_ profile: ConnectionProfile, session: DatabaseSession?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(statusColor(session))

            Image(systemName: profile.kind.symbolName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.color(hex: profile.colorHex) ?? Theme.color(for: profile.kind))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(profile.displayName)
                    .lineLimit(1)
                Text(profile.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if profile.readOnly {
                Image(systemName: "lock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(app.t("connection.readOnly"))
            }
            if session?.status == .connecting {
                ProgressView().controlSize(.small)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { toggle(profile, session: session) }
    }

    @ViewBuilder
    private func databaseRow(_ database: DatabaseNode, session: DatabaseSession) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { session.expandedDatabases.contains(database.name) },
                set: { expanded in
                    if expanded {
                        session.expandedDatabases.insert(database.name)
                        Task { try? await session.loadChildren(ofDatabase: database.name) }
                    } else {
                        session.expandedDatabases.remove(database.name)
                    }
                }
            )
        ) {
            if database.hasSchemaLevel {
                ForEach(database.schemas) { schema in
                    schemaRow(schema, database: database, session: session)
                }
            } else {
                tableRows(matching(database.tables), session: session)
            }
        } label: {
            Label(database.name, systemImage: "cylinder")
                .lineLimit(1)
        }
        .contextMenu {
            Button(app.t("dump.title")) {
                app.dumpRequest = DumpRequest(sessionID: session.id, database: database.name)
            }
            Button(app.t("restore.title")) {
                app.scriptRequest = ScriptRequest(sessionID: session.id)
            }
            Divider()
            Button(app.t("general.refresh")) {
                session.invalidate(database: database.name)
                Task { try? await session.loadChildren(ofDatabase: database.name) }
            }
        }
    }

    @ViewBuilder
    private func schemaRow(_ schema: SchemaNode, database: DatabaseNode, session: DatabaseSession) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { session.expandedSchemas.contains(schema.id) },
                set: { expanded in
                    if expanded {
                        session.expandedSchemas.insert(schema.id)
                        Task { try? await session.loadChildren(ofSchema: schema.name, in: database.name) }
                    } else {
                        session.expandedSchemas.remove(schema.id)
                    }
                }
            )
        ) {
            tableRows(matching(schema.tables), session: session)
        } label: {
            Label(schema.name, systemImage: "folder")
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func tableRows(_ tables: [TableRef], session: DatabaseSession) -> some View {
        if tables.isEmpty {
            Text(app.t("sidebar.noObjects"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(tables) { table in
                Label(table.name, systemImage: table.kind.symbolName)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture { app.openTable(table, sessionID: session.id) }
                    .contextMenu {
                        Button(app.t("workspace.tab.data")) { app.openTable(table, sessionID: session.id) }
                        Button(app.t("import.title")) {
                            app.importRequest = ImportRequest(sessionID: session.id, table: table)
                        }
                        Divider()
                        Button("SELECT * FROM \(table.qualifiedName)") {
                            let dialect = SQLDialect(kind: session.kind)
                            app.newQueryTab(
                                sessionID: session.id,
                                sql: "SELECT *\nFROM \(dialect.qualified(table))\nLIMIT 100;"
                            )
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private func connectionMenu(_ profile: ConnectionProfile, session: DatabaseSession?) -> some View {
        if session?.status.isConnected == true {
            Button(app.t("connection.disconnect")) {
                Task { await app.closeSession(id: profile.id) }
            }
            Button(app.t("workspace.newQuery")) {
                app.newQueryTab(sessionID: profile.id)
            }
        } else {
            Button(app.t("connection.connect")) { app.connect(to: profile) }
        }
        Divider()
        Button(app.t("general.edit")) { app.editConnection(profile) }
        Button(app.t("general.duplicate")) { app.duplicate(profile: profile) }
        Button(app.t("connection.copyURL")) { app.copyConnectionURL(for: profile) }
            .help(app.t("connection.copyURL.note"))
        Divider()
        Button(app.t("general.delete"), role: .destructive) {
            app.confirmation = Confirmation(
                title: app.t("connection.delete.title"),
                message: app.t("connection.delete.message"),
                confirmTitle: app.t("general.delete"),
                isDestructive: true
            ) {
                app.delete(profile: profile)
            }
        }
    }

    // MARK: - Footer and empty state

    private var footer: some View {
        HStack(spacing: 6) {
            if let session = app.session(id: app.selectedSessionID), let info = session.serverInfo {
                Image(systemName: "bolt.horizontal.circle")
                    .foregroundStyle(.secondary)
                Text("\(info.productName) \(info.version)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(app.t("app.tagline"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(app.t("connection.empty.title"))
                .font(.headline)
            Text(app.t("connection.empty.message"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(app.t("connection.new")) {
                app.newConnection()
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private var folders: [String] {
        var seen: [String] = []
        for profile in app.profiles where !seen.contains(profile.folder) {
            seen.append(profile.folder)
        }
        // Ungrouped connections come first, then folders alphabetically.
        return seen.sorted { lhs, rhs in
            if lhs.isEmpty { return true }
            if rhs.isEmpty { return false }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    private func profiles(in folder: String) -> [ConnectionProfile] {
        app.profiles
            .filter { $0.folder == folder }
            .filter { filterText.isEmpty || $0.displayName.localizedCaseInsensitiveContains(filterText) || $0.subtitle.localizedCaseInsensitiveContains(filterText) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// The search field filters tables too, not just connections.
    private func matching(_ tables: [TableRef]) -> [TableRef] {
        guard !filterText.isEmpty else { return tables }
        return tables.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
    }

    private func statusColor(_ session: DatabaseSession?) -> Color {
        switch session?.status {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        default: return Color.secondary.opacity(0.35)
        }
    }

    private func toggle(_ profile: ConnectionProfile, session: DatabaseSession?) {
        if session?.status.isConnected == true {
            Task { await app.closeSession(id: profile.id) }
        } else {
            app.connect(to: profile)
        }
    }
}
