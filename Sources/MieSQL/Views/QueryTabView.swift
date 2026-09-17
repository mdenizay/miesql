import AppKit
import SwiftUI
import MieSQLCore

/// Editor on top, results underneath, with a draggable divider between them.
struct QueryTabView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: QueryTabModel
    @State private var selectedText = ""
    @State private var snippetName = ""
    @State private var isNamingSnippet = false

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                toolbar
                Divider()
                SQLEditorView(
                    text: $model.sql,
                    kind: session?.kind ?? .postgres,
                    fontSize: app.settings.editorFontSize,
                    showLineNumbers: app.settings.showLineNumbers,
                    wrapLines: app.settings.wrapLongLines,
                    completionWords: completionWords,
                    onRun: { app.run(tab: model) },
                    onRunSelection: { runSelection() }
                )
            }
            .frame(minHeight: 120, idealHeight: 260)

            resultsPane
                .frame(minHeight: 140)
        }
        .alert(app.t("workspace.saveSnippet"), isPresented: $isNamingSnippet) {
            TextField(app.t("connection.name"), text: $snippetName)
            Button(app.t("general.save")) {
                guard !snippetName.isEmpty else { return }
                app.saveSnippet(name: snippetName, sql: model.sql)
                snippetName = ""
            }
            Button(app.t("general.cancel"), role: .cancel) { snippetName = "" }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                app.run(tab: model)
            } label: {
                Label(app.t("workspace.run"), systemImage: "play.fill")
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.isRunning || model.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if model.isRunning {
                ProgressView().controlSize(.small)
            }

            Divider().frame(height: 16)

            Button {
                model.sql = SQLFormatter.format(model.sql, kind: session?.kind ?? .postgres)
            } label: {
                Label(app.t("workspace.format"), systemImage: "text.alignleft")
            }
            .help(app.t("workspace.format"))

            Button {
                isNamingSnippet = true
            } label: {
                Label(app.t("workspace.saveSnippet"), systemImage: "bookmark")
            }
            .help(app.t("workspace.saveSnippet"))

            if !app.snippets.isEmpty {
                Menu {
                    ForEach(app.snippets) { snippet in
                        Button(snippet.name) { model.sql = snippet.sql }
                    }
                    Divider()
                    ForEach(app.snippets) { snippet in
                        Button("\(app.t("general.delete")): \(snippet.name)", role: .destructive) {
                            app.deleteSnippet(id: snippet.id)
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Spacer()

            if let session, session.databases.count > 1 {
                Picker("", selection: databaseBinding) {
                    ForEach(session.databases) { database in
                        Text(database.name).tag(database.name)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
                .help(app.t("connection.database"))
            }

            if let profile = session?.profile, profile.readOnly {
                Label(app.t("connection.readOnly"), systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsPane: some View {
        VStack(spacing: 0) {
            if let message = model.errorMessage {
                ErrorBanner(message: message)
            }

            if model.results.count > 1 {
                Picker("", selection: $model.selectedResultIndex) {
                    ForEach(model.results.indices, id: \.self) { index in
                        Text("\(index + 1). \(SQLDialect.leadingKeyword(of: model.results[index].statement).uppercased())")
                            .tag(index)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(6)
                Divider()
            }

            if let result = model.currentResult {
                if result.hasResultSet {
                    ResultTableView(
                        columns: result.columns,
                        rows: result.rows,
                        fontSize: app.settings.gridFontSize,
                        isEditable: false,
                        pendingUpdates: [:],
                        deletedRowIDs: [],
                        sortColumn: nil,
                        sortAscending: true,
                        onEdit: { _, _, _ in },
                        onSort: { _ in },
                        onSelectionChange: { _ in },
                        onCopy: { style, rows in copy(style: style, rows: rows, result: result) },
                        onDeleteRows: { _ in }
                    )
                    statusBar(result)
                } else {
                    VStack(spacing: 6) {
                        Text(result.rowsAffected != nil
                             ? app.t("result.affected", result.rowsAffected ?? 0)
                             : app.t("result.noResult"))
                            .foregroundStyle(.secondary)
                        Text(result.summary())
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if model.errorMessage == nil {
                Text(app.t("result.noResult"))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func statusBar(_ result: QueryResult) -> some View {
        HStack(spacing: 10) {
            Text(result.summary())
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(result.messages, id: \.self) { message in
                Label(message, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                ForEach(ExportFormat.allCases) { format in
                    Button(format.displayName) { export(result: result, format: format) }
                }
            } label: {
                Label(app.t("general.export"), systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    // MARK: - Actions

    private var session: DatabaseSession? { app.session(id: model.sessionID) }

    private var databaseBinding: Binding<String> {
        Binding(
            get: { model.database },
            set: { newValue in
                model.database = newValue
                guard let driver = session?.driver else { return }
                Task { try? await driver.use(database: newValue) }
            }
        )
    }

    /// Table and column names from the loaded tree, so completion knows the schema.
    private var completionWords: [String] {
        guard let session else { return [] }
        var words = Set<String>()
        for table in session.allLoadedTables {
            words.insert(table.name)
            if !table.schema.isEmpty { words.insert(table.schema) }
        }
        for database in session.databases {
            words.insert(database.name)
        }
        return Array(words)
    }

    private func runSelection() {
        // The editor owns the selection; ask the first responder for it.
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else {
            app.run(tab: model)
            return
        }
        let selected = (textView.string as NSString).substring(with: textView.selectedRange())
        let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        app.run(tab: model, sql: trimmed.isEmpty ? nil : trimmed)
    }

    private func copy(style: ResultTableView.CopyStyle, rows: [Int], result: QueryResult) {
        let selected = rows.compactMap { result.rows.indices.contains($0) ? result.rows[$0] : nil }
        guard !selected.isEmpty else { return }

        let format: ExportFormat
        switch style {
        case .cell, .csv: format = .csv
        case .json: format = .json
        case .insert: format = .sqlInsert
        }

        let text = ResultExporter.export(
            columns: result.columns,
            rows: selected,
            options: ExportOptions(
                format: format,
                includeHeader: style != .cell,
                tableName: result.columns.first?.tableName ?? "exported_data",
                kind: session?.kind ?? .postgres
            )
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func export(result: QueryResult, format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(model.title).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = ResultExporter.export(
            result,
            options: ExportOptions(format: format, tableName: "exported_data", kind: session?.kind ?? .postgres)
        )
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
    }
}
