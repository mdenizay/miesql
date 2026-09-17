import AppKit
import SwiftUI
import MieSQLCore

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label(app.t("settings.general"), systemImage: "gearshape") }
            editorTab
                .tabItem { Label(app.t("settings.editor"), systemImage: "text.cursor") }
            dataTab
                .tabItem { Label(app.t("settings.data"), systemImage: "externaldrive") }
            aboutTab
                .tabItem { Label(app.t("settings.about"), systemImage: "info.circle") }
        }
        .frame(width: 480, height: 380)
    }

    private var generalTab: some View {
        Form {
            Picker(app.t("settings.appearance"), selection: $app.settings.appearance) {
                Text(app.t("settings.appearance.system")).tag(AppearanceMode.system)
                Text(app.t("settings.appearance.light")).tag(AppearanceMode.light)
                Text(app.t("settings.appearance.dark")).tag(AppearanceMode.dark)
            }
            .pickerStyle(.segmented)

            Picker(app.t("settings.language"), selection: $app.settings.languageCode) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language.rawValue)
                }
            }

            Toggle(app.t("settings.restoreTabs"), isOn: $app.settings.restoreTabsOnLaunch)
        }
        .formStyle(.grouped)
    }

    private var editorTab: some View {
        Form {
            LabeledContent(app.t("settings.editorFontSize")) {
                Stepper(value: $app.settings.editorFontSize, in: 9...24, step: 1) {
                    Text("\(Int(app.settings.editorFontSize)) pt").monospacedDigit()
                }
            }
            LabeledContent(app.t("settings.gridFontSize")) {
                Stepper(value: $app.settings.gridFontSize, in: 9...24, step: 1) {
                    Text("\(Int(app.settings.gridFontSize)) pt").monospacedDigit()
                }
            }
            Toggle(app.t("settings.lineNumbers"), isOn: $app.settings.showLineNumbers)
            Toggle(app.t("settings.wrapLines"), isOn: $app.settings.wrapLongLines)
        }
        .formStyle(.grouped)
    }

    private var dataTab: some View {
        Form {
            LabeledContent(app.t("settings.pageSize")) {
                TextField("", value: $app.settings.pageSize, format: .number)
                    .frame(width: 90)
            }
            LabeledContent(app.t("settings.maxRows")) {
                TextField("", value: $app.settings.maxResultRows, format: .number)
                    .frame(width: 90)
            }
            LabeledContent(app.t("settings.historyLimit")) {
                TextField("", value: $app.settings.historyLimit, format: .number)
                    .frame(width: 90)
            }
            Toggle(app.t("settings.confirmDestructive"), isOn: $app.settings.confirmDestructiveStatements)
        }
        .formStyle(.grouped)
    }

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(app.t("app.name")).font(.title2.weight(.semibold))
            Text(app.t("app.tagline")).foregroundStyle(.secondary)

            Divider()

            Text(app.t("settings.privacy"))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text(app.t("settings.dataLocation"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(AppPaths.supportDirectory.path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Button(app.t("settings.revealInFinder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.supportDirectory])
                }
                .controlSize(.small)
            }

            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Query history, with a jump back into the editor.
struct HistoryView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(app.t("history.title")).font(.headline)
                Spacer()
                Button(app.t("history.clear"), role: .destructive) { app.clearHistory() }
                    .controlSize(.small)
                Button(app.t("general.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)
            }
            .padding(12)

            Divider()

            if filtered.isEmpty {
                Text(app.t("history.empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: entry.succeeded ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(entry.succeeded ? .green : .red)
                                .font(.caption)
                            Text(entry.connectionName)
                                .font(.caption.weight(.medium))
                            if !entry.database.isEmpty {
                                Text(entry.database)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(entry.executedAt, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.preview)
                            .font(.callout.monospaced())
                            .lineLimit(2)
                        if let error = entry.errorMessage {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { insert(entry) }
                    .contextMenu {
                        Button(app.t("history.insert")) { insert(entry) }
                        Button(app.t("general.copy")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.sql, forType: .string)
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: app.t("general.search"))
        .frame(width: 620, height: 460)
    }

    private var filtered: [QueryHistoryEntry] {
        guard !search.isEmpty else { return app.history }
        return app.history.filter { $0.sql.localizedCaseInsensitiveContains(search) }
    }

    private func insert(_ entry: QueryHistoryEntry) {
        if case .query(let model) = app.selectedTab {
            model.sql = entry.sql
        } else if let sessionID = app.selectedSessionID ?? app.sessions.first?.id {
            app.newQueryTab(sessionID: sessionID, sql: entry.sql)
        }
        dismiss()
    }
}
