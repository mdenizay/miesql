import AppKit
import SwiftUI
import MieSQLCore
import UniformTypeIdentifiers

@main
struct MieSQLApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(app)
                .preferredColorScheme(app.colorScheme)
                // `.contentMinSize` below reads its floor from here; without a frame the
                // window would be allowed to collapse to nothing.
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1240, height: 780)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands { AppCommands(app: app) }

        Settings {
            SettingsView()
                .environmentObject(app)
                .preferredColorScheme(app.colorScheme)
        }
    }
}

/// Menu bar entries and the keyboard shortcuts that go with them.
struct AppCommands: Commands {
    @ObservedObject var app: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(app.t("workspace.newQuery")) {
                if let sessionID = app.selectedSessionID ?? app.sessions.first?.id {
                    app.newQueryTab(sessionID: sessionID)
                }
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(app.sessions.isEmpty)

            Button(app.t("connection.new")) {
                app.editingProfile = ConnectionProfile()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button(app.t("workspace.openFile")) { openSQLFile() }
                .keyboardShortcut("o", modifiers: .command)
            Button(app.t("workspace.saveFile")) { saveSQLFile() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(currentQueryTab == nil)
        }

        CommandMenu(app.t("menu.query")) {
            Button(app.t("workspace.run")) {
                if let tab = currentQueryTab { app.run(tab: tab) }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(currentQueryTab == nil)

            Button(app.t("workspace.format")) {
                if let tab = currentQueryTab, let session = app.session(id: tab.sessionID) {
                    tab.sql = SQLFormatter.format(tab.sql, kind: session.kind)
                }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(currentQueryTab == nil)

            Divider()

            Button(app.t("history.title")) { app.isShowingHistory = true }
                .keyboardShortcut("y", modifiers: .command)
        }

        CommandMenu(app.t("menu.view")) {
            Button(app.t("menu.commandPalette")) { app.isShowingPalette = true }
                .keyboardShortcut("k", modifiers: .command)
        }
    }

    private var currentQueryTab: QueryTabModel? {
        if case .query(let model) = app.selectedTab { return model }
        return nil
    }

    private func openSQLFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "sql") ?? .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK,
              let url = panel.url,
              let contents = try? String(contentsOf: url, encoding: .utf8),
              let sessionID = app.selectedSessionID ?? app.sessions.first?.id else { return }
        let tab = app.newQueryTab(sessionID: sessionID, sql: contents)
        tab.title = url.deletingPathExtension().lastPathComponent
    }

    private func saveSQLFile() {
        guard let tab = currentQueryTab else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "sql") ?? .plainText]
        panel.nameFieldStringValue = tab.title + ".sql"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? tab.sql.write(to: url, atomically: true, encoding: .utf8)
    }
}
