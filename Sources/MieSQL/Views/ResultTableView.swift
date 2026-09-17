import AppKit
import SwiftUI
import MieSQLCore

/// The result grid. `NSTableView` rather than SwiftUI's `Table` because it recycles row
/// views, so scrolling a hundred thousand rows costs the same as scrolling ten.
struct ResultTableView: NSViewRepresentable {

    let columns: [ColumnInfo]
    let rows: [ResultRow]
    var fontSize: Double
    var isEditable: Bool
    /// Values changed in the grid but not yet applied, drawn with a highlight.
    var pendingUpdates: [Int: [String: SQLValue]]
    var deletedRowIDs: Set<Int>
    var sortColumn: String?
    var sortAscending: Bool

    var onEdit: (Int, ColumnInfo, SQLValue) -> Void
    var onSort: (ColumnInfo) -> Void
    var onSelectionChange: ([Int]) -> Void
    var onCopy: (CopyStyle, [Int]) -> Void
    var onDeleteRows: ([Int]) -> Void

    enum CopyStyle {
        case cell
        case csv
        case json
        case insert
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .fullWidth
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowSizeStyle = .custom
        tableView.intercellSpacing = NSSize(width: 6, height: 2)
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        tableView.menu = context.coordinator.makeMenu()

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        context.coordinator.tableView = tableView
        context.coordinator.rebuildColumns()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        let previous = context.coordinator.parent
        context.coordinator.parent = self

        let columnsChanged = previous.columns.map(\.name) != columns.map(\.name)
        if columnsChanged {
            context.coordinator.rebuildColumns()
        }
        tableView.rowHeight = max(18, fontSize + 8)
        tableView.reloadData()
        context.coordinator.updateSortIndicators()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var parent: ResultTableView
        weak var tableView: NSTableView?

        init(_ parent: ResultTableView) {
            self.parent = parent
        }

        // MARK: Columns

        func rebuildColumns() {
            guard let tableView else { return }
            for column in tableView.tableColumns {
                tableView.removeTableColumn(column)
            }

            for info in parent.columns {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col-\(info.index)"))
                column.title = info.name
                column.headerToolTip = info.typeName.isEmpty ? info.name : "\(info.name) · \(info.typeName)"
                column.width = estimatedWidth(for: info)
                column.minWidth = 48
                column.maxWidth = 1200
                column.resizingMask = [.userResizingMask]
                tableView.addTableColumn(column)
            }
            updateSortIndicators()
            tableView.reloadData()
        }

        /// A first guess at a useful width, based on the header and the first rows.
        private func estimatedWidth(for info: ColumnInfo) -> CGFloat {
            let font = Theme.gridFont(size: parent.fontSize)
            var width = (info.name as NSString).size(withAttributes: [.font: NSFont.boldSystemFont(ofSize: parent.fontSize)]).width + 28
            for row in parent.rows.prefix(30) {
                let text = row[info.index].displayValue
                let measured = (text as NSString).size(withAttributes: [.font: font]).width + 18
                width = max(width, measured)
            }
            return min(max(width, 60), 420)
        }

        func updateSortIndicators() {
            guard let tableView else { return }
            for column in tableView.tableColumns {
                tableView.setIndicatorImage(nil, in: column)
            }
            guard let sortColumn = parent.sortColumn,
                  let info = parent.columns.first(where: { $0.name == sortColumn }),
                  let column = tableView.tableColumns.first(where: { $0.identifier.rawValue == "col-\(info.index)" })
            else { return }
            let image = NSImage(named: parent.sortAscending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator")
            tableView.setIndicatorImage(image, in: column)
        }

        func tableView(_ tableView: NSTableView, mouseDownInHeaderOf tableColumn: NSTableColumn) {
            guard let info = columnInfo(for: tableColumn) else { return }
            parent.onSort(info)
        }

        // MARK: Data

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.rows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let info = columnInfo(for: tableColumn), row < parent.rows.count else { return nil }
            let resultRow = parent.rows[row]

            let identifier = tableColumn.identifier
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = identifier
                let field = NSTextField(labelWithString: "")
                field.translatesAutoresizingMaskIntoConstraints = false
                field.lineBreakMode = .byTruncatingTail
                field.delegate = self
                cell.addSubview(field)
                cell.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }

            guard let field = cell.textField else { return cell }
            field.font = Theme.gridFont(size: parent.fontSize)
            field.alignment = info.isNumeric ? .right : .left
            field.isEditable = parent.isEditable
            field.isSelectable = true
            field.isBordered = false
            field.drawsBackground = false
            field.tag = row

            let pending = parent.pendingUpdates[resultRow.id]?[info.name]
            let value = pending ?? resultRow[info.index]

            if value.isNull {
                field.stringValue = "NULL"
                field.textColor = .tertiaryLabelColor
                field.font = NSFont.monospacedSystemFont(ofSize: parent.fontSize - 1, weight: .regular)
            } else {
                // Newlines would break row height; show the first line and keep the rest
                // available in the tooltip and the cell inspector.
                field.stringValue = value.stringValue.replacingOccurrences(of: "\n", with: "⏎ ")
                field.textColor = pending != nil ? .controlAccentColor : .labelColor
            }
            field.toolTip = value.isNull ? "NULL" : value.stringValue

            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = DeletedAwareRowView()
            view.isMarkedDeleted = row < parent.rows.count && parent.deletedRowIDs.contains(parent.rows[row].id)
            return view
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView else { return }
            parent.onSelectionChange(Array(tableView.selectedRowIndexes))
        }

        // MARK: Editing

        func controlTextDidEndEditing(_ notification: Notification) {
            guard parent.isEditable,
                  let field = notification.object as? NSTextField,
                  let tableView,
                  let cell = field.superview as? NSTableCellView else { return }

            let row = tableView.row(for: cell)
            let columnIndex = tableView.column(for: cell)
            guard row >= 0, columnIndex >= 0,
                  columnIndex < tableView.tableColumns.count,
                  let info = columnInfo(for: tableView.tableColumns[columnIndex]),
                  row < parent.rows.count else { return }

            let text = field.stringValue
            // Typing the word NULL is how a cell is cleared; an empty string stays empty.
            let value: SQLValue = text == "NULL" ? .null : .text(text)
            parent.onEdit(parent.rows[row].id, info, value)
        }

        @objc func handleDoubleClick(_ sender: Any?) {
            guard let tableView, tableView.clickedRow >= 0, tableView.clickedColumn >= 0 else { return }
            if parent.isEditable {
                tableView.editColumn(tableView.clickedColumn, row: tableView.clickedRow, with: nil, select: true)
            }
        }

        // MARK: Context menu

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.addItem(withTitle: "Copy Cell", action: #selector(copyCell), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Copy as CSV", action: #selector(copyCSV), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Copy as JSON", action: #selector(copyJSON), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Copy as INSERT", action: #selector(copyInsert), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Set to NULL", action: #selector(setNull), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Delete Selected Rows", action: #selector(deleteRows), keyEquivalent: "").target = self
            return menu
        }

        private var actionRows: [Int] {
            guard let tableView else { return [] }
            let selected = Array(tableView.selectedRowIndexes)
            if selected.isEmpty, tableView.clickedRow >= 0 { return [tableView.clickedRow] }
            return selected
        }

        @objc private func copyCell() { parent.onCopy(.cell, actionRows) }
        @objc private func copyCSV() { parent.onCopy(.csv, actionRows) }
        @objc private func copyJSON() { parent.onCopy(.json, actionRows) }
        @objc private func copyInsert() { parent.onCopy(.insert, actionRows) }
        @objc private func deleteRows() { parent.onDeleteRows(actionRows) }

        @objc private func setNull() {
            guard parent.isEditable, let tableView, tableView.clickedColumn >= 0 else { return }
            guard let info = columnInfo(for: tableView.tableColumns[tableView.clickedColumn]) else { return }
            for row in actionRows where row < parent.rows.count {
                parent.onEdit(parent.rows[row].id, info, .null)
            }
        }

        /// The column the user clicked, or the first one, for "Copy Cell".
        var clickedColumnInfo: ColumnInfo? {
            guard let tableView, tableView.clickedColumn >= 0,
                  tableView.clickedColumn < tableView.tableColumns.count else { return nil }
            return columnInfo(for: tableView.tableColumns[tableView.clickedColumn])
        }

        private func columnInfo(for column: NSTableColumn) -> ColumnInfo? {
            guard let index = Int(column.identifier.rawValue.dropFirst("col-".count)) else { return nil }
            return parent.columns.first { $0.index == index }
        }
    }
}

/// Draws a strike-through tint over rows the user has marked for deletion.
final class DeletedAwareRowView: NSTableRowView {
    var isMarkedDeleted = false

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isMarkedDeleted else { return }
        NSColor.systemRed.withAlphaComponent(0.14).setFill()
        bounds.fill()
    }
}
