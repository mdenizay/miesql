import Testing
@testable import MieSQLCore

@Suite("Statement splitting")
struct StatementSplitterTests {

    @Test("Splits on semicolons")
    func splitsSimpleScript() {
        let statements = SQLStatementSplitter.split("SELECT 1; SELECT 2;", kind: .postgres)
        #expect(statements.map(\.text) == ["SELECT 1", "SELECT 2"])
    }

    @Test("Ignores semicolons inside string literals")
    func ignoresSemicolonsInStrings() {
        let statements = SQLStatementSplitter.split("SELECT 'a;b'; SELECT 2", kind: .postgres)
        #expect(statements.count == 2)
        #expect(statements[0].text == "SELECT 'a;b'")
    }

    @Test("Ignores semicolons inside comments")
    func ignoresSemicolonsInComments() {
        let sql = """
        -- first; not a split
        SELECT 1;
        /* also; not a split */
        SELECT 2
        """
        let statements = SQLStatementSplitter.split(sql, kind: .postgres)
        #expect(statements.count == 2)
    }

    @Test("Handles PostgreSQL dollar quoting")
    func handlesDollarQuoting() {
        let sql = "CREATE FUNCTION f() RETURNS int AS $$ BEGIN RETURN 1; END; $$ LANGUAGE plpgsql; SELECT 1"
        let statements = SQLStatementSplitter.split(sql, kind: .postgres)
        #expect(statements.count == 2)
        #expect(statements[0].text.contains("BEGIN RETURN 1; END;"))
    }

    @Test("Honours MySQL DELIMITER directives")
    func honoursDelimiter() {
        let sql = """
        DELIMITER //
        CREATE TRIGGER t BEGIN SELECT 1; END//
        DELIMITER ;
        SELECT 2;
        """
        let statements = SQLStatementSplitter.split(sql, kind: .mysql)
        #expect(statements.contains { $0.text.contains("CREATE TRIGGER") && $0.text.contains("SELECT 1;") })
        #expect(statements.contains { $0.text == "SELECT 2" })
    }

    @Test("Escaped quotes do not end a literal")
    func handlesEscapedQuotes() {
        let statements = SQLStatementSplitter.split("SELECT 'it''s'; SELECT 2", kind: .postgres)
        #expect(statements.count == 2)
        #expect(statements[0].text == "SELECT 'it''s'")
    }
}

@Suite("Dialect quoting")
struct DialectTests {

    @Test("Quotes identifiers per engine")
    func quotesIdentifiers() {
        #expect(SQLDialect(kind: .mysql).quote("users") == "`users`")
        #expect(SQLDialect(kind: .postgres).quote("users") == "\"users\"")
        #expect(SQLDialect(kind: .sqlite).quote("users") == "\"users\"")
    }

    @Test("Doubles embedded quote characters")
    func escapesIdentifiers() {
        #expect(SQLDialect(kind: .mysql).quote("we`ird") == "`we``ird`")
        #expect(SQLDialect(kind: .postgres).quote("we\"ird") == "\"we\"\"ird\"")
    }

    @Test("Escapes string literals, including MySQL backslashes")
    func escapesLiterals() {
        #expect(SQLDialect(kind: .postgres).stringLiteral("it's") == "'it''s'")
        #expect(SQLDialect(kind: .mysql).stringLiteral("a\\b") == "'a\\\\b'")
    }

    @Test("Finds the leading keyword past comments")
    func findsLeadingKeyword() {
        #expect(SQLDialect.leadingKeyword(of: "  -- note\n SELECT 1") == "select")
        #expect(SQLDialect.leadingKeyword(of: "/* x */ DELETE FROM t") == "delete")
    }

    @Test("Classifies read-only statements")
    func classifiesReadOnly() {
        #expect(SQLDialect.isReadOnlyStatement("SELECT 1"))
        #expect(SQLDialect.isReadOnlyStatement("WITH t AS (SELECT 1) SELECT * FROM t"))
        #expect(!SQLDialect.isReadOnlyStatement("DROP TABLE users"))
        #expect(!SQLDialect.isReadOnlyStatement("UPDATE users SET a = 1"))
    }
}

@Suite("Exporting results")
struct ExporterTests {

    private var sample: QueryResult {
        QueryResult(
            statement: "SELECT",
            columns: [
                ColumnInfo(index: 0, name: "id", typeName: "int4"),
                ColumnInfo(index: 1, name: "name", typeName: "text")
            ],
            rows: [
                ResultRow(id: 0, values: [.text("1"), .text("Ada")]),
                ResultRow(id: 1, values: [.text("2"), .null]),
                ResultRow(id: 2, values: [.text("3"), .text("say \"hi\", ok")])
            ]
        )
    }

    @Test("CSV quotes fields containing separators and quotes")
    func csvQuoting() {
        let csv = ResultExporter.export(sample, options: ExportOptions(format: .csv))
        let lines = csv.split(separator: "\n")
        #expect(lines[0] == "id,name")
        #expect(lines[1] == "1,Ada")
        #expect(lines[2] == "2,")
        #expect(lines[3] == "3,\"say \"\"hi\"\", ok\"")
    }

    @Test("JSON renders NULL as null")
    func jsonNulls() {
        let json = ResultExporter.export(sample, options: ExportOptions(format: .json))
        #expect(json.contains("\"name\": null"))
        #expect(json.contains("\"name\": \"say \\\"hi\\\", ok\""))
    }

    @Test("SQL INSERT escapes values and quotes identifiers")
    func sqlInserts() {
        let sql = ResultExporter.export(
            sample,
            options: ExportOptions(format: .sqlInsert, tableName: "people", kind: .postgres)
        )
        #expect(sql.contains("INSERT INTO \"people\" (\"id\", \"name\") VALUES ('1', 'Ada');"))
        #expect(sql.contains("VALUES ('2', NULL);"))
    }
}

@Suite("Row editing")
struct RowEditPlannerTests {

    private let table = TableRef(database: "app", schema: "public", name: "users")

    @Test("UPDATE matches on the full primary key")
    func plansUpdate() throws {
        let planner = RowEditPlanner(kind: .postgres, table: table, keyColumns: ["id"])
        let statements = try planner.plan([
            .update(rowID: 0, changes: ["name": .text("Ada")], original: ["id": .text("7"), "name": .text("Grace")])
        ])
        #expect(statements[0].sql == "UPDATE \"public\".\"users\" SET \"name\" = 'Ada' WHERE \"id\" = '7';")
    }

    @Test("NULL key parts use IS NULL")
    func handlesNullKeys() throws {
        let planner = RowEditPlanner(kind: .sqlite, table: TableRef(database: "main", name: "t"), keyColumns: ["a", "b"])
        let statements = try planner.plan([
            .delete(rowID: 0, original: ["a": .text("1"), "b": .null])
        ])
        #expect(statements[0].sql == "DELETE FROM \"t\" WHERE \"a\" = '1' AND \"b\" IS NULL;")
    }

    @Test("Refuses to edit a table without a key")
    func requiresKey() {
        let planner = RowEditPlanner(kind: .mysql, table: table, keyColumns: [])
        #expect(throws: RowEditError.self) {
            _ = try planner.plan([.delete(rowID: 0, original: ["id": .text("1")])])
        }
    }

    @Test("Inserts do not need a key")
    func insertsWithoutKey() throws {
        // MySQL has no schema level, so its refs carry only a database and a table name.
        let planner = RowEditPlanner(
            kind: .mysql,
            table: TableRef(database: "app", name: "users"),
            keyColumns: []
        )
        let statements = try planner.plan([.insert(rowID: 0, values: ["name": .text("Ada")])])
        #expect(statements[0].sql == "INSERT INTO `users` (`name`) VALUES ('Ada');")
    }
}

@Suite("CSV parsing")
struct CSVImporterTests {

    @Test("Parses quoted fields, embedded quotes and newlines")
    func parsesQuoted() {
        let rows = CSVImporter().parse("a,b\n1,\"x,y\"\n2,\"he said \"\"no\"\"\"\n", delimiter: ",")
        #expect(rows.count == 3)
        #expect(rows[1] == ["1", "x,y"])
        #expect(rows[2] == ["2", "he said \"no\""])
    }
}

@Suite("PostgreSQL binary decoding")
struct PostgresValueRendererTests {

    @Test("Decodes integers")
    func decodesIntegers() {
        #expect(PostgresValueRenderer.decodeBinary([0x00, 0x00, 0x00, 0x2A], oid: 23) == "42")
        #expect(PostgresValueRenderer.decodeBinary([0xFF, 0xFF, 0xFF, 0xFF], oid: 23) == "-1")
    }

    @Test("Decodes booleans")
    func decodesBooleans() {
        #expect(PostgresValueRenderer.decodeBinary([0x01], oid: 16) == "true")
        #expect(PostgresValueRenderer.decodeBinary([0x00], oid: 16) == "false")
    }

    @Test("Decodes numeric with scale")
    func decodesNumeric() {
        // 1234.5600 -> ndigits 3, weight 0, sign 0, dscale 4, digits [1234, 5600]
        let bytes: [UInt8] = [
            0x00, 0x02, // ndigits
            0x00, 0x00, // weight
            0x00, 0x00, // sign
            0x00, 0x04, // dscale
            0x04, 0xD2, // 1234
            0x15, 0xE0  // 5600
        ]
        #expect(PostgresValueRenderer.decodeBinary(bytes, oid: 1700) == "1234.5600")
    }

    @Test("Decodes UUIDs")
    func decodesUUID() {
        let bytes: [UInt8] = [
            0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0,
            0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0
        ]
        #expect(PostgresValueRenderer.decodeBinary(bytes, oid: 2950) == "12345678-9abc-def0-1234-56789abcdef0")
    }

    @Test("Decodes dates and timestamps against the 2000-01-01 epoch")
    func decodesDates() {
        #expect(PostgresValueRenderer.decodeBinary([0x00, 0x00, 0x00, 0x00], oid: 1082) == "2000-01-01")
        // 86_400_000_000 microseconds = one day after the epoch
        let oneDay: Int64 = 86_400_000_000
        var bytes: [UInt8] = []
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((oneDay >> Int64(shift)) & 0xFF))
        }
        #expect(PostgresValueRenderer.decodeBinary(bytes, oid: 1114) == "2000-01-02 00:00:00")
    }

    @Test("Decodes text arrays")
    func decodesArray() {
        // {"a","b"}: ndim 1, hasnull 0, elemtype 25, dim 2, lower 1, then elements
        let bytes: [UInt8] = [
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x19,
            0x00, 0x00, 0x00, 0x02,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x01, 0x61,
            0x00, 0x00, 0x00, 0x01, 0x62
        ]
        #expect(PostgresValueRenderer.decodeBinary(bytes, oid: 1009) == "{a,b}")
    }
}

@Suite("Formatting")
struct SQLFormatterTests {

    @Test("Breaks before major clauses and uppercases keywords")
    func formatsSelect() {
        let formatted = SQLFormatter.formatStatement("select a,b from t where a=1 order by b", kind: .postgres)
        let lines = formatted.split(separator: "\n").map(String.init)
        #expect(lines.first == "SELECT")
        #expect(lines.contains { $0.hasPrefix("FROM") })
        #expect(lines.contains { $0.hasPrefix("WHERE") })
        #expect(formatted.contains("ORDER BY"))
    }
}
