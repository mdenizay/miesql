import AppKit
import SwiftUI
import MieSQLCore

/// Export a database — structure, data, or both — to a `.sql` file.
struct DumpSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    let request: DumpRequest

    @State private var tables: [TableRef] = []
    @State private var selection: Set<String> = []
    @State private var options = DumpOptions()
    @State private var destination: URL?
    @State private var progress: DumpProgress?
    @State private var isRunning = false
    @State private var summary: String?
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(app.t("dump.title")).font(.headline)
                Spacer()
                Text(request.database).font(.callout).foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()

            HSplitView {
                tableList
                    .frame(minWidth: 220)
                optionsForm
                    .frame(minWidth: 280)
            }

            Divider()
            footer
        }
        .frame(width: 640, height: 480)
        .task { await loadTables() }
        .onDisappear { task?.cancel() }
    }

    private var tableList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(app.t("dump.tables")).font(.subheadline.weight(.medium))
                Spacer()
                Button(app.t("general.all")) { selection = Set(tables.map(\.id)) }
                    .controlSize(.mini)
                Button(app.t("general.none")) { selection = [] }
                    .controlSize(.mini)
            }
            .padding(8)

            List(tables, selection: $selection) { table in
                HStack(spacing: 6) {
                    Toggle("", isOn: Binding(
                        get: { selection.contains(table.id) },
                        set: { isOn in
                            if isOn { selection.insert(table.id) } else { selection.remove(table.id) }
                        }
                    ))
                    .labelsHidden()
                    Image(systemName: table.kind.symbolName)
                        .foregroundStyle(.secondary)
                    Text(table.name).lineLimit(1)
                }
                .tag(table.id)
            }
        }
    }

    private var optionsForm: some View {
        Form {
            Toggle(app.t("dump.includeSchema"), isOn: $options.includeSchema)
            Toggle(app.t("dump.includeData"), isOn: $options.includeData)
            Toggle(app.t("dump.dropIfExists"), isOn: $options.dropIfExists)
            Toggle(app.t("dump.transaction"), isOn: $options.wrapInTransaction)

            LabeledContent(app.t("dump.rowsPerInsert")) {
                TextField("", value: $options.rowsPerInsert, format: .number)
                    .frame(width: 80)
            }

            LabeledContent(app.t("dump.destination")) {
                HStack {
                    Text(destination?.lastPathComponent ?? "—")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(app.t("general.browse")) { chooseDestination() }
                }
            }

            if let progress, isRunning {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress.fraction)
                    Text(app.t("dump.running", progress.currentTable))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(progress.rowsWritten) \(app.t("general.rows"))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }

            if let summary {
                Label(summary, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(app.t("general.cancel")) {
                task?.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button(app.t("dump.start")) { start() }
                .keyboardShortcut(.defaultAction)
                .disabled(isRunning || destination == nil || selection.isEmpty)
        }
        .padding(12)
    }

    private func loadTables() async {
        guard let session = app.session(id: request.sessionID), let driver = session.driver else { return }
        do {
            let schemas = try await driver.listSchemas(database: request.database)
            if schemas.isEmpty {
                tables = try await driver.listTables(in: SchemaRef(database: request.database))
            } else {
                var collected: [TableRef] = []
                for schema in schemas {
                    collected += try await driver.listTables(in: SchemaRef(database: request.database, schema: schema))
                }
                tables = collected
            }
            selection = Set(tables.map(\.id))
        } catch {
            errorMessage = DatabaseSession.describe(error)
        }
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(request.database).sql"
        guard panel.runModal() == .OK else { return }
        destination = panel.url
    }

    private func start() {
        guard let session = app.session(id: request.sessionID),
              let driver = session.driver,
              let destination else { return }

        let selected = tables.filter { selection.contains($0.id) }
        isRunning = true
        summary = nil
        errorMessage = nil

        task = Task {
            do {
                try await DumpService().dump(
                    tables: selected,
                    using: driver,
                    kind: session.kind,
                    options: options,
                    to: destination
                ) { update in
                    Task { @MainActor in progress = update }
                }
                summary = app.t("dump.done", selected.count, destination.lastPathComponent)
            } catch is CancellationError {
                errorMessage = nil
            } catch {
                errorMessage = DatabaseSession.describe(error)
            }
            isRunning = false
        }
    }
}

/// Run a `.sql` file against the connection — the restore half of the dumper.
struct RunScriptSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    let request: ScriptRequest

    @State private var fileURL: URL?
    @State private var stopOnError = true
    @State private var progress: ScriptProgress?
    @State private var isRunning = false
    @State private var summary: ScriptRunSummary?
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(app.t("restore.title")).font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()

            Form {
                LabeledContent(app.t("restore.file")) {
                    HStack {
                        Text(fileURL?.lastPathComponent ?? "—")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(app.t("general.browse")) { chooseFile() }
                    }
                }
                Toggle(app.t("restore.stopOnError"), isOn: $stopOnError)

                if let progress, isRunning {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: progress.fraction)
                        Text(app.t("restore.running", progress.statementIndex, progress.statementCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let summary {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            app.t("restore.done", summary.succeeded, summary.total),
                            systemImage: summary.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                        )
                        .foregroundStyle(summary.failures.isEmpty ? .green : .orange)

                        if !summary.failures.isEmpty {
                            Text(app.t("restore.failures", summary.failures.count))
                                .font(.caption)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(summary.failures) { failure in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(failure.message)
                                                .font(.caption)
                                                .foregroundStyle(.red)
                                            Text(failure.statement)
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.secondary)
                                                .lineLimit(3)
                                        }
                                    }
                                }
                            }
                            .frame(maxHeight: 140)
                        }
                    }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(app.t("general.close")) {
                    task?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(app.t("restore.start")) { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRunning || fileURL == nil)
            }
            .padding(12)
        }
        .frame(width: 560, height: 460)
        .onDisappear { task?.cancel() }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "sql") ?? .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return }
        fileURL = panel.url
    }

    private func start() {
        guard let session = app.session(id: request.sessionID),
              let driver = session.driver,
              let fileURL else { return }

        isRunning = true
        summary = nil
        errorMessage = nil

        task = Task {
            do {
                let result = try await ScriptRunner().run(
                    fileAt: fileURL,
                    using: driver,
                    kind: session.kind,
                    stopOnError: stopOnError
                ) { update in
                    Task { @MainActor in progress = update }
                }
                summary = result
            } catch is CancellationError {
                errorMessage = nil
            } catch {
                errorMessage = DatabaseSession.describe(error)
            }
            isRunning = false
        }
    }
}

/// Load a CSV file into a table, with a preview and per-column mapping.
struct CSVImportSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    let request: ImportRequest

    @State private var fileURL: URL?
    @State private var options = CSVImportOptions()
    @State private var preview: CSVPreview?
    @State private var targetColumns: [String] = []
    @State private var mapping: [Int: String] = [:]
    @State private var isRunning = false
    @State private var summary: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(app.t("import.title")).font(.headline)
                Spacer()
                Text(request.table.qualifiedName).font(.callout).foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()

            Form {
                LabeledContent(app.t("import.file")) {
                    HStack {
                        Text(fileURL?.lastPathComponent ?? "—")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(app.t("general.browse")) { chooseFile() }
                    }
                }
                Toggle(app.t("import.hasHeader"), isOn: $options.hasHeaderRow)
                    .onChange(of: options.hasHeaderRow) { _, _ in reloadPreview() }

                LabeledContent(app.t("import.delimiter")) {
                    Picker("", selection: delimiterBinding) {
                        Text(",").tag(",")
                        Text(";").tag(";")
                        Text("Tab").tag("\t")
                        Text("|").tag("|")
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }

                if let preview, !preview.header.isEmpty {
                    Section(app.t("import.mapping")) {
                        ForEach(preview.header.indices, id: \.self) { index in
                            LabeledContent(preview.header[index]) {
                                Picker("", selection: Binding(
                                    get: { mapping[index] ?? "" },
                                    set: { value in
                                        if value.isEmpty { mapping.removeValue(forKey: index) }
                                        else { mapping[index] = value }
                                    }
                                )) {
                                    Text(app.t("general.none")).tag("")
                                    ForEach(targetColumns, id: \.self) { column in
                                        Text(column).tag(column)
                                    }
                                }
                                .labelsHidden()
                            }
                        }
                    }

                    Section(app.t("import.preview")) {
                        ScrollView(.horizontal) {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(preview.rows.indices, id: \.self) { index in
                                    Text(preview.rows[index].joined(separator: " │ "))
                                        .font(.caption.monospaced())
                                        .lineLimit(1)
                                }
                            }
                        }
                        .frame(maxHeight: 120)
                        Text("\(preview.totalRowsScanned) \(app.t("general.rows"))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if let summary {
                    Label(summary, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(app.t("general.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(app.t("import.start")) { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRunning || fileURL == nil || mapping.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 560, height: 520)
        .task { await loadTargetColumns() }
    }

    private var delimiterBinding: Binding<String> {
        Binding(
            get: { String(options.delimiter) },
            set: { value in
                options.delimiter = value.first ?? ","
                reloadPreview()
            }
        )
    }

    private func loadTargetColumns() async {
        guard let session = app.session(id: request.sessionID), let driver = session.driver else { return }
        do {
            let details = try await driver.describe(table: request.table)
            targetColumns = details.columns.map(\.name)
        } catch {
            errorMessage = DatabaseSession.describe(error)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return }
        fileURL = panel.url
        reloadPreview()
    }

    private func reloadPreview() {
        guard let fileURL else { return }
        do {
            let loaded = try CSVImporter().preview(fileAt: fileURL, options: options)
            preview = loaded
            // Pre-map anything whose header matches a column name, which is the usual case.
            var initial: [Int: String] = [:]
            for (index, name) in loaded.header.enumerated() {
                if let match = targetColumns.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                    initial[index] = match
                }
            }
            mapping = initial
        } catch {
            errorMessage = DatabaseSession.describe(error)
        }
    }

    private func start() {
        guard let session = app.session(id: request.sessionID), let fileURL else { return }
        options.columnMapping = mapping
        isRunning = true
        summary = nil
        errorMessage = nil

        Task {
            do {
                let statements = try CSVImporter().statements(
                    fileAt: fileURL,
                    table: request.table,
                    kind: session.kind,
                    options: options
                )
                var inserted = 0
                for statement in statements {
                    _ = try await session.execute(statement)
                    inserted += 1
                }
                summary = "\(inserted) \(app.t("general.done"))"
            } catch {
                errorMessage = DatabaseSession.describe(error)
            }
            isRunning = false
        }
    }
}
