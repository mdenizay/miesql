import Foundation

/// Word lists for highlighting and completion. Kept as one shared vocabulary rather than
/// per-dialect sets: an extra suggestion is cheap, a missing one is annoying.
public enum SQLKeywords {

    public static let reserved: Set<String> = [
        "ADD", "ALL", "ALTER", "ANALYZE", "AND", "AS", "ASC", "ATTACH", "AUTOINCREMENT",
        "BEGIN", "BETWEEN", "BY", "CASCADE", "CASE", "CAST", "CHECK", "COLLATE", "COLUMN",
        "COMMENT", "COMMIT", "CONFLICT", "CONSTRAINT", "CREATE", "CROSS", "CURRENT",
        "DATABASE", "DEFAULT", "DEFERRABLE", "DELETE", "DESC", "DESCRIBE", "DETACH",
        "DISTINCT", "DO", "DROP", "EACH", "ELSE", "END", "ESCAPE", "EXCEPT", "EXCLUSIVE",
        "EXISTS", "EXPLAIN", "FALSE", "FETCH", "FILTER", "FOLLOWING", "FOR", "FOREIGN",
        "FROM", "FULL", "GENERATED", "GRANT", "GROUP", "HAVING", "IF", "IGNORE",
        "IMMEDIATE", "IN", "INDEX", "INDEXED", "INITIALLY", "INNER", "INSERT", "INSTEAD",
        "INTERSECT", "INTO", "IS", "ISNULL", "JOIN", "KEY", "LATERAL", "LEFT", "LIKE",
        "LIMIT", "MATCH", "MATERIALIZED", "NATURAL", "NO", "NOT", "NOTHING", "NOTNULL",
        "NULL", "NULLS", "OF", "OFFSET", "ON", "OR", "ORDER", "OUTER", "OVER", "PARTITION",
        "PLAN", "PRAGMA", "PRECEDING", "PRIMARY", "PROCEDURE", "QUERY", "RAISE", "RANGE",
        "RECURSIVE", "REFERENCES", "REGEXP", "REINDEX", "RELEASE", "RENAME", "REPLACE",
        "RESTRICT", "RETURNING", "REVOKE", "RIGHT", "ROLLBACK", "ROW", "ROWS", "SAVEPOINT",
        "SCHEMA", "SELECT", "SET", "SHOW", "TABLE", "TEMP", "TEMPORARY", "THEN", "TIES",
        "TO", "TRANSACTION", "TRIGGER", "TRUE", "TRUNCATE", "UNION", "UNIQUE", "UPDATE",
        "USE", "USING", "VACUUM", "VALUES", "VIEW", "VIRTUAL", "WHEN", "WHERE", "WINDOW",
        "WITH", "WITHOUT"
    ]

    public static let types: Set<String> = [
        "BIGINT", "BIGSERIAL", "BINARY", "BIT", "BLOB", "BOOL", "BOOLEAN", "BYTEA", "CHAR",
        "CHARACTER", "CITEXT", "DATE", "DATETIME", "DECIMAL", "DOUBLE", "ENUM", "FLOAT",
        "INET", "INT", "INT2", "INT4", "INT8", "INTEGER", "INTERVAL", "JSON", "JSONB",
        "LONGBLOB", "LONGTEXT", "MEDIUMINT", "MEDIUMTEXT", "MONEY", "NUMERIC", "REAL",
        "SERIAL", "SET", "SMALLINT", "TEXT", "TIME", "TIMESTAMP", "TIMESTAMPTZ", "TINYINT",
        "TINYTEXT", "UUID", "VARBINARY", "VARCHAR", "XML", "YEAR"
    ]

    public static let functions: Set<String> = [
        "ABS", "AVG", "CEIL", "CEILING", "COALESCE", "CONCAT", "COUNT", "CURRENT_DATE",
        "CURRENT_TIME", "CURRENT_TIMESTAMP", "CURRENT_USER", "DATE_TRUNC", "DENSE_RANK",
        "EXTRACT", "FIRST_VALUE", "FLOOR", "GREATEST", "GROUP_CONCAT", "IFNULL", "JSON_AGG",
        "JSON_EXTRACT", "LAG", "LAST_VALUE", "LEAD", "LEAST", "LENGTH", "LOWER", "LPAD",
        "MAX", "MIN", "NOW", "NULLIF", "NTILE", "RANDOM", "RANK", "REPLACE", "ROUND",
        "ROW_NUMBER", "RPAD", "STRING_AGG", "SUBSTR", "SUBSTRING", "SUM", "TO_CHAR",
        "TO_DATE", "TO_TIMESTAMP", "TRIM", "UNNEST", "UPPER", "VERSION"
    ]

    /// Multi-word snippets offered after the single words, so `SELECT ` can suggest `SELECT * FROM`.
    public static let snippets: [(trigger: String, body: String, detail: String)] = [
        ("sel", "SELECT * FROM ", "Select all columns"),
        ("selc", "SELECT COUNT(*) FROM ", "Count rows"),
        ("ins", "INSERT INTO  ()\nVALUES ();", "Insert row"),
        ("upd", "UPDATE  SET  WHERE ;", "Update rows"),
        ("del", "DELETE FROM  WHERE ;", "Delete rows"),
        ("ct", "CREATE TABLE  (\n  id SERIAL PRIMARY KEY\n);", "Create table"),
        ("ij", "INNER JOIN  ON ", "Inner join"),
        ("lj", "LEFT JOIN  ON ", "Left join"),
        ("cte", "WITH t AS (\n  SELECT 1\n)\nSELECT * FROM t;", "Common table expression")
    ]

    public static let allWords: [String] = (reserved.union(types).union(functions)).sorted()
}
