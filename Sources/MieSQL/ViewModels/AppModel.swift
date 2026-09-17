import AppKit
import Foundation
import MieSQLCore
import SwiftUI

/// Central coordinator: owns the settings, the saved connections, every live session and
/// the open tabs. Views talk to this and never to the drivers directly.
@MainActor
final class AppModel: ObservableObject {

    // Stores
    private let connectionStore = ConnectionStore()
    private let settingsStore = SettingsStore()
    private let historyStore = QueryHistoryStore()
    private let snippetStore = SnippetStore()

    // State
    @Published var settings: AppSettings {
        didSet {
            settingsStore.save(settings)
            localizer = Localizer(language: AppLanguage.resolve(settings.languageCode))
        }
    }
    @Published private(set) var localizer: Localizer
    @Published var profiles: [ConnectionProfile] = []
    @Published var sessions: [DatabaseSession] = []
    @Published var tabs: [WorkspaceTab] = []
    @Published var selectedTabID: UUID?
    @Published var selectedSessionID: UUID?
    @Published var history: [QueryHistoryEntry] = []
    @Published var snippets: [SQLSnippet] = []

    // Sheets and alerts
    @Published var editingProfile: ConnectionProfile?
    @Published var passwordRequest: PasswordRequest?
    @Published var confirmation: Confirmation?
    @Published var alert: AlertMessage?
    @Published var dumpRequest: DumpRequest?
    @Published var scriptRequest: ScriptRequest?
    @Published var importRequest: ImportRequest?
    @Published var isShowingPalette = false
    @Published var isShowingHistory = false

    init() {
        let loadedSettings = settingsStore.load()
        settings = loadedSettings
        localizer = Localizer(language: AppLanguage.resolve(loadedSettings.languageCode))
        profiles = connectionStore.load()
        history = historyStore.load()
        snippets = snippetStore.load()
    }

    /// Shorthand so views can write `app.t("general.save")`.
    func t(_ key: String) -> String { localizer(key) }
    func t(_ key: String, _ arguments: CustomStringConvertible...) -> String {
        var text = localizer(key)
        for argument in arguments {
            guard let range = text.range(of: "%@") else { break }
            text.replaceSubrange(range, with: argument.description)
        }
        return text
    }

    var colorScheme: ColorScheme? {
        switch settings.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    // MARK: - Profiles

    func save(profile: ConnectionProfile, password: String?) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        persistProfiles()

        if profile.savePassword, let password, !password.isEmpty {
            try? KeychainStore.save(password: password, account: profile.keychainAccount)
        } else if !profile.savePassword {
            KeychainStore.delete(account: profile.keychainAccount)
        }

        // Keep an open session's label and flags in step with the edited profile.
        if let session = sessions.first(where: { $0.id == profile.id }) {
            session.profile = profile
        }
    }

    func delete(profile: ConnectionProfile) {
        Task { await closeSession(id: profile.id) }
        profiles.removeAll { $0.id == profile.id }
        KeychainStore.delete(account: profile.keychainAccount)
        persistProfiles()
    }

    func duplicate(profile: ConnectionProfile) {
        var copy = profile
        copy.id = UUID()
        copy.name = profile.displayName + " copy"
        copy.savePassword = false
        copy.lastConnectedAt = nil
        profiles.append(copy)
        persistProfiles()
    }

    private func persistProfiles() {
        do {
            try connectionStore.save(profiles)
        } catch {
            alert = AlertMessage(title: t("general.error"), message: error.localizedDescription)
        }
    }

    // MARK: - Sessions

    func session(id: UUID?) -> DatabaseSession? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    func connect(to profile: ConnectionProfile) {
        let session = sessions.first(where: { $0.id == profile.id }) ?? {
            let new = DatabaseSession(profile: profile)
            sessions.append(new)
            return new
        }()
        session.profile = profile
        selectedSessionID = session.id

        // SQLite has no password; everything else may need one we do not hold yet.
        if profile.kind.isFileBased {
            Task { await performConnect(session: session, password: nil) }
            return
        }

        if profile.savePassword, let stored = KeychainStore.password(account: profile.keychainAccount) {
            Task { await performConnect(session: session, password: stored) }
            return
        }

        passwordRequest = PasswordRequest(profile: profile) { [weak self] password, remember in
            guard let self else { return }
            if remember {
                try? KeychainStore.save(password: password, account: profile.keychainAccount)
                if let index = self.profiles.firstIndex(where: { $0.id == profile.id }) {
                    self.profiles[index].savePassword = true
                    self.persistProfiles()
                }
            }
            Task { await self.performConnect(session: session, password: password) }
        }
    }

    private func performConnect(session: DatabaseSession, password: String?) async {
        await session.connect(password: password)
        if case .failed(let message) = session.status {
            alert = AlertMessage(title: t("connection.failed"), message: message)
            return
        }
        if let index = profiles.firstIndex(where: { $0.id == session.id }) {
            profiles[index].lastConnectedAt = Date()
            persistProfiles()
        }
    }

    func closeSession(id: UUID) async {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        await session.disconnect()
        tabs.removeAll { $0.sessionID == id }
        sessions.removeAll { $0.id == id }
        if selectedSessionID == id { selectedSessionID = sessions.first?.id }
        if let selectedTabID, !tabs.contains(where: { $0.id == selectedTabID }) {
            self.selectedTabID = tabs.first?.id
        }
    }

    /// Tests a profile without adding it to the sidebar.
    func testConnection(_ profile: ConnectionProfile, password: String?) async -> Result<ServerInfo, any Error> {
        let driver = DriverFactory.makeDriver(for: ConnectionCredentials(profile: profile, password: password))
        do {
            let info = try await driver.connect()
            await driver.disconnect()
            return .success(info)
        } catch {
            await driver.disconnect()
            return .failure(error)
        }
    }

    // MARK: - Tabs

    @discardableResult
    func newQueryTab(sessionID: UUID, sql: String = "") -> QueryTabModel {
        let session = session(id: sessionID)
        let existingQueryTabs = tabs.filter { if case .query = $0 { return true }; return false }.count
        let model = QueryTabModel(
            sessionID: sessionID,
            title: "\(t("workspace.tab.query")) \(existingQueryTabs + 1)",
            sql: sql,
            database: session?.serverInfo?.currentDatabase ?? ""
        )
        tabs.append(.query(model))
        selectedTabID = model.id
        return model
    }

    func openTable(_ table: TableRef, sessionID: UUID) {
        // Re-select an already open tab rather than stacking duplicates.
        if let existing = tabs.first(where: { tab in
            if case .table(let model) = tab {
                return model.sessionID == sessionID && model.table == table
            }
            return false
        }) {
            selectedTabID = existing.id
            return
        }

        let model = TableTabModel(sessionID: sessionID, table: table, pageSize: settings.pageSize)
        tabs.append(.table(model))
        selectedTabID = model.id
        Task { await loadTable(model) }
    }

    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
    }

    var selectedTab: WorkspaceTab? {
        tabs.first { $0.id == selectedTabID }
    }

    // MARK: - Running SQL

    func run(tab: QueryTabModel, sql: String? = nil) {
        let script = (sql ?? tab.sql).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty, let session = session(id: tab.sessionID) else { return }

        let statements = SQLStatementSplitter.split(script, kind: session.kind)
        let destructive = statements.filter { !SQLDialect.isReadOnlyStatement($0.text) }

        if settings.confirmDestructiveStatements, !destructive.isEmpty {
            let keywords = Set(destructive.map { SQLDialect.leadingKeyword(of: $0.text).uppercased() })
            confirmation = Confirmation(
                title: t("confirm.destructive.title"),
                message: t("confirm.destructive.message", keywords.sorted().joined(separator: ", ")),
                confirmTitle: t("workspace.run"),
                isDestructive: true
            ) { [weak self] in
                self?.execute(script: script, in: tab, session: session)
            }
            return
        }

        execute(script: script, in: tab, session: session)
    }

    private func execute(script: String, in tab: QueryTabModel, session: DatabaseSession) {
        tab.isRunning = true
        tab.errorMessage = nil

        Task {
            let started = Date()
            do {
                var results = try await session.execute(script)
                // Keep a runaway SELECT from filling memory; the cap is a user setting.
                results = results.map { result in
                    guard result.rows.count > settings.maxResultRows else { return result }
                    return QueryResult(
                        statement: result.statement,
                        columns: result.columns,
                        rows: Array(result.rows.prefix(settings.maxResultRows)),
                        rowsAffected: result.rowsAffected,
                        duration: result.duration,
                        messages: result.messages + ["Showing the first \(settings.maxResultRows) rows."]
                    )
                }

                tab.results = results
                tab.selectedResultIndex = 0
                tab.isRunning = false

                record(
                    sql: script,
                    session: session,
                    duration: Date().timeIntervalSince(started),
                    succeeded: true,
                    rowCount: results.first?.rows.count,
                    error: nil
                )
            } catch {
                let message = DatabaseSession.describe(error)
                tab.errorMessage = message
                tab.isRunning = false
                record(
                    sql: script,
                    session: session,
                    duration: Date().timeIntervalSince(started),
                    succeeded: false,
                    rowCount: nil,
                    error: message
                )
            }
        }
    }

    private func record(
        sql: String,
        session: DatabaseSession,
        duration: TimeInterval,
        succeeded: Bool,
        rowCount: Int?,
        error: String?
    ) {
        let entry = QueryHistoryEntry(
            sql: sql,
            connectionName: session.profile.displayName,
            database: session.serverInfo?.currentDatabase ?? "",
            durationSeconds: duration,
            succeeded: succeeded,
            rowCount: rowCount,
            errorMessage: error
        )
        historyStore.append(entry, limit: settings.historyLimit)
        history = historyStore.load()
    }

    func clearHistory() {
        historyStore.clear()
        history = []
    }

    // MARK: - Table browsing

    func loadTable(_ model: TableTabModel) async {
        guard let session = session(id: model.sessionID), let driver = session.driver else { return }
        model.isLoading = true
        model.errorMessage = nil

        do {
            if model.details == nil {
                model.details = try await driver.describe(table: model.table)
            }
            let order = model.sortColumn.map { [(column: $0, ascending: model.sortAscending)] } ?? []
            let page = try await driver.fetchRows(
                table: model.table,
                whereClause: model.filterClause,
                orderBy: order,
                limit: model.pageSize,
                offset: model.offset
            )
            model.result = page
            model.edits.clear()

            // The exact count is only worth fetching for the first page of a filtered view.
            if model.page == 0 {
                model.totalRows = try? await driver.countRows(table: model.table, whereClause: model.filterClause)
            }
        } catch {
            model.errorMessage = DatabaseSession.describe(error)
        }
        model.isLoading = false
    }

    func loadDDL(_ model: TableTabModel) async {
        guard let session = session(id: model.sessionID), let driver = session.driver else { return }
        guard model.ddl.isEmpty else { return }
        do {
            model.ddl = try await driver.createStatement(for: model.table)
        } catch {
            model.ddl = "-- " + DatabaseSession.describe(error)
        }
    }

    /// Shows the generated statements before anything runs, then applies them together.
    func applyEdits(_ model: TableTabModel) {
        guard let session = session(id: model.sessionID) else { return }
        let planner = RowEditPlanner(
            kind: session.kind,
            table: model.table,
            keyColumns: model.primaryKeyColumns
        )

        do {
            let planned = try planner.plan(model.edits.rowEdits())
            let script = planned.map(\.sql).joined(separator: "\n")
            confirmation = Confirmation(
                title: t("confirm.applyEdits.title", planned.count),
                message: script,
                confirmTitle: t("result.applyChanges"),
                isDestructive: true
            ) { [weak self] in
                guard let self else { return }
                Task {
                    do {
                        _ = try await session.execute(script)
                        model.edits.clear()
                        await self.loadTable(model)
                    } catch {
                        self.alert = AlertMessage(
                            title: self.t("general.error"),
                            message: DatabaseSession.describe(error)
                        )
                    }
                }
            }
        } catch {
            alert = AlertMessage(title: t("general.error"), message: error.localizedDescription)
        }
    }

    // MARK: - Snippets

    func saveSnippet(name: String, sql: String) {
        snippets.append(SQLSnippet(name: name, sql: sql))
        snippetStore.save(snippets)
    }

    func deleteSnippet(id: UUID) {
        snippets.removeAll { $0.id == id }
        snippetStore.save(snippets)
    }
}

// MARK: - Sheet payloads

struct PasswordRequest: Identifiable {
    let id = UUID()
    let profile: ConnectionProfile
    let onSubmit: (String, Bool) -> Void
}

struct Confirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    let isDestructive: Bool
    let action: () -> Void
}

struct AlertMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct DumpRequest: Identifiable {
    let id = UUID()
    let sessionID: UUID
    let database: String
}

struct ScriptRequest: Identifiable {
    let id = UUID()
    let sessionID: UUID
}

struct ImportRequest: Identifiable {
    let id = UUID()
    let sessionID: UUID
    let table: TableRef
}
