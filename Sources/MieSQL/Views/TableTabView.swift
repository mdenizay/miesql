import AppKit
import SwiftUI
import MieSQLCore

/// One table: browse and edit its rows, read its structure, or read its DDL.
struct TableTabView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: TableTabModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            switch model.section {
            case .data: dataSection
            case .structure: StructureView(details: model.details)
            case .ddl: ddlSection
            }
        }
        .task(id: model.section) {
            if model.section == .ddl { await app.loadDDL(model) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Picker("", selection: $model.section) {
                ForEach(TableTabModel.Section.allCases) { section in
                    Text(app.t(section.titleKey)).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if model.isLoading {
                ProgressView().controlSize(.small)
            }

            Spacer()

            Text(model.table.qualifiedName)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button {
                Task { await app.loadTable(model) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(app.t("general.refresh"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Data

    @ViewBuilder
    private var dataSection: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()

            if let message = model.errorMessage {
                ErrorBanner(message: message)
            }

            if let result = model.result {
                ResultTableView(
                    columns: result.columns,
                    rows: result.rows,
                    fontSize: app.settings.gridFontSize,
                    isEditable: model.isEditable,
                    pendingUpdates: model.edits.updates,
                    deletedRowIDs: model.edits.deletions,
                    sortColumn: model.sortColumn,
                    sortAscending: model.sortAscending,
                    onEdit: { rowID, column, value in record(rowID: rowID, column: column, value: value, result: result) },
                    onSort: { column in sort(by: column) },
                    onSelectionChange: { _ in },
                    onCopy: { style, rows in copy(style: style, rows: rows, result: result) },
                    onDeleteRows: { rows in markDeleted(rows, result: result) }
                )
            } else if !model.isLoading {
                Text(app.t("result.noRows"))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }

            Divider()
            statusBar
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            TextField(app.t("result.filter.placeholder"), text: $model.filterClause)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .onSubmit {
                    model.page = 0
                    Task { await app.loadTable(model) }
                }

            if !model.isEditable {
                Label(app.t("result.notEditable"), systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(app.t("result.notEditable"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Button {
                model.page -= 1
                Task { await app.loadTable(model) }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!model.canGoToPreviousPage)

            Text(app.t("result.page", model.page + 1))
                .font(.caption)
                .monospacedDigit()

            Button {
                model.page += 1
                Task { await app.loadTable(model) }
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!model.canGoToNextPage)

            if let total = model.totalRows {
                Text("\(total) \(app.t("general.rows"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            if !model.edits.isEmpty {
                Text(app.t("result.pendingChanges", model.edits.count))
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)

                Button(app.t("result.discardChanges")) {
                    model.edits.clear()
                }
                Button(app.t("result.applyChanges")) {
                    app.applyEdits(model)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Menu {
                ForEach(ExportFormat.allCases) { format in
                    Button(format.displayName) { export(format: format) }
                }
            } label: {
                Label(app.t("general.export"), systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .buttonStyle(.borderless)
        .background(.bar)
    }

    // MARK: - DDL

    private var ddlSection: some View {
        ScrollView {
            Text(model.ddl.isEmpty ? "…" : model.ddl)
                .font(.system(size: app.settings.editorFontSize, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .topTrailing) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.ddl, forType: .string)
            } label: {
                Label(app.t("general.copy"), systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(10)
        }
    }

    // MARK: - Actions

    private func record(rowID: Int, column: ColumnInfo, value: SQLValue, result: QueryResult) {
        guard let row = result.rows.first(where: { $0.id == rowID }) else { return }
        var original: [String: SQLValue] = [:]
        for info in result.columns {
            original[info.name] = row[info.index]
        }
        model.edits.recordUpdate(rowID: rowID, column: column.name, value: value, original: original)
    }

    private func markDeleted(_ rows: [Int], result: QueryResult) {
        guard model.isEditable else { return }
        for index in rows where result.rows.indices.contains(index) {
            let row = result.rows[index]
            var original: [String: SQLValue] = [:]
            for info in result.columns {
                original[info.name] = row[info.index]
            }
            model.edits.originals[row.id] = original
            model.edits.deletions.insert(row.id)
        }
    }

    private func sort(by column: ColumnInfo) {
        if model.sortColumn == column.name {
            model.sortAscending.toggle()
        } else {
            model.sortColumn = column.name
            model.sortAscending = true
        }
        model.page = 0
        Task { await app.loadTable(model) }
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
                tableName: model.table.qualifiedName,
                kind: app.session(id: model.sessionID)?.kind ?? .postgres
            )
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func export(format: ExportFormat) {
        guard let result = model.result else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(model.table.name).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = ResultExporter.export(
            result,
            options: ExportOptions(
                format: format,
                tableName: model.table.qualifiedName,
                kind: app.session(id: model.sessionID)?.kind ?? .postgres
            )
        )
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Columns, indexes and foreign keys for the open table.
struct StructureView: View {
    @EnvironmentObject private var app: AppModel
    let details: TableDetails?

    var body: some View {
        if let details {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let count = details.estimatedRowCount {
                        Label("\(app.t("structure.rowCount")): \(count)", systemImage: "number")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let comment = details.comment, !comment.isEmpty {
                        Text(comment)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    section(app.t("structure.columns")) {
                        Table(details.columns) {
                            TableColumn(app.t("structure.column"), value: \.name)
                            TableColumn(app.t("structure.type"), value: \.dataType)
                            TableColumn(app.t("structure.nullable")) { column in
                                Text(column.isNullable ? "✓" : "")
                            }
                            TableColumn(app.t("structure.key")) { column in
                                Text(column.isPrimaryKey ? "PK" : (column.isAutoIncrement ? "AI" : ""))
                            }
                            TableColumn(app.t("structure.default")) { column in
                                Text(column.defaultValue ?? "")
                                    .foregroundStyle(.secondary)
                            }
                            TableColumn(app.t("structure.comment")) { column in
                                Text(column.comment ?? "")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(minHeight: CGFloat(details.columns.count * 24 + 40))
                    }

                    if !details.indexes.isEmpty {
                        section(app.t("structure.indexes")) {
                            Table(details.indexes) {
                                TableColumn(app.t("connection.name"), value: \.name)
                                TableColumn(app.t("structure.columns")) { index in
                                    Text(index.columns.joined(separator: ", "))
                                }
                                TableColumn(app.t("structure.unique")) { index in
                                    Text(index.isUnique ? "✓" : "")
                                }
                                TableColumn(app.t("structure.primary")) { index in
                                    Text(index.isPrimary ? "✓" : "")
                                }
                                TableColumn(app.t("structure.method")) { index in
                                    Text(index.method ?? "")
                                }
                            }
                            .frame(minHeight: CGFloat(details.indexes.count * 24 + 40))
                        }
                    }

                    if !details.foreignKeys.isEmpty {
                        section(app.t("structure.foreignKeys")) {
                            Table(details.foreignKeys) {
                                TableColumn(app.t("connection.name"), value: \.name)
                                TableColumn(app.t("structure.columns")) { key in
                                    Text(key.columns.joined(separator: ", "))
                                }
                                TableColumn(app.t("structure.references")) { key in
                                    Text("\(key.referencedTable) (\(key.referencedColumns.joined(separator: ", ")))")
                                }
                                TableColumn(app.t("structure.onDelete")) { key in
                                    Text(key.onDelete ?? "")
                                }
                                TableColumn(app.t("structure.onUpdate")) { key in
                                    Text(key.onUpdate ?? "")
                                }
                            }
                            .frame(minHeight: CGFloat(details.foreignKeys.count * 24 + 40))
                        }
                    }
                }
                .padding(14)
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            content()
        }
    }
}
