import Foundation

/// A namespace inside a server. PostgreSQL has database → schema → table; MySQL and
/// SQLite collapse the middle level, so `schema` is empty there and the tree hides it.
public struct SchemaRef: Hashable, Sendable {
    public var database: String
    public var schema: String

    public init(database: String, schema: String = "") {
        self.database = database
        self.schema = schema
    }
}

public enum TableKind: String, Sendable, Codable {
    case table
    case view
    case materializedView

    public var symbolName: String {
        switch self {
        case .table: return "tablecells"
        case .view: return "eye"
        case .materializedView: return "square.stack.3d.up"
        }
    }
}

public struct TableRef: Hashable, Sendable, Identifiable {
    public var id: String { "\(database)|\(schema)|\(name)" }
    public var database: String
    public var schema: String
    public var name: String
    public var kind: TableKind

    public init(database: String, schema: String = "", name: String, kind: TableKind = .table) {
        self.database = database
        self.schema = schema
        self.name = name
        self.kind = kind
    }

    /// `schema.name` where a schema exists, otherwise just the name.
    public var qualifiedName: String {
        schema.isEmpty ? name : "\(schema).\(name)"
    }
}

public struct ColumnDefinition: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var dataType: String
    public var isNullable: Bool
    public var defaultValue: String?
    public var isPrimaryKey: Bool
    public var isAutoIncrement: Bool
    public var comment: String?
    public var ordinalPosition: Int

    public init(
        name: String,
        dataType: String,
        isNullable: Bool = true,
        defaultValue: String? = nil,
        isPrimaryKey: Bool = false,
        isAutoIncrement: Bool = false,
        comment: String? = nil,
        ordinalPosition: Int = 0
    ) {
        self.name = name
        self.dataType = dataType
        self.isNullable = isNullable
        self.defaultValue = defaultValue
        self.isPrimaryKey = isPrimaryKey
        self.isAutoIncrement = isAutoIncrement
        self.comment = comment
        self.ordinalPosition = ordinalPosition
    }
}

public struct IndexDefinition: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var columns: [String]
    public var isUnique: Bool
    public var isPrimary: Bool
    public var method: String?

    public init(name: String, columns: [String], isUnique: Bool = false, isPrimary: Bool = false, method: String? = nil) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.isPrimary = isPrimary
        self.method = method
    }
}

public struct ForeignKeyDefinition: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var columns: [String]
    public var referencedTable: String
    public var referencedColumns: [String]
    public var onDelete: String?
    public var onUpdate: String?

    public init(
        name: String,
        columns: [String],
        referencedTable: String,
        referencedColumns: [String],
        onDelete: String? = nil,
        onUpdate: String? = nil
    ) {
        self.name = name
        self.columns = columns
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.onDelete = onDelete
        self.onUpdate = onUpdate
    }
}

/// Everything the structure tab shows for one table.
public struct TableDetails: Sendable {
    public var table: TableRef
    public var columns: [ColumnDefinition]
    public var indexes: [IndexDefinition]
    public var foreignKeys: [ForeignKeyDefinition]
    public var estimatedRowCount: Int?
    public var comment: String?

    public init(
        table: TableRef,
        columns: [ColumnDefinition] = [],
        indexes: [IndexDefinition] = [],
        foreignKeys: [ForeignKeyDefinition] = [],
        estimatedRowCount: Int? = nil,
        comment: String? = nil
    ) {
        self.table = table
        self.columns = columns
        self.indexes = indexes
        self.foreignKeys = foreignKeys
        self.estimatedRowCount = estimatedRowCount
        self.comment = comment
    }

    public var primaryKeyColumns: [String] {
        let fromColumns = columns.filter(\.isPrimaryKey).map(\.name)
        if !fromColumns.isEmpty { return fromColumns }
        return indexes.first(where: \.isPrimary)?.columns ?? []
    }
}

/// Reported on connect and shown in the sidebar footer.
public struct ServerInfo: Sendable {
    public var productName: String
    public var version: String
    public var currentDatabase: String
    public var currentUser: String

    public init(productName: String, version: String, currentDatabase: String, currentUser: String) {
        self.productName = productName
        self.version = version
        self.currentDatabase = currentDatabase
        self.currentUser = currentUser
    }
}
