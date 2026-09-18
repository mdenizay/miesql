import Foundation
import Testing
@testable import MieSQLCore

@Suite("Connection URLs")
struct ConnectionURLTests {

    // MARK: - The common shapes

    @Test("Parses a full PostgreSQL URL")
    func fullPostgres() throws {
        let parsed = try ConnectionURLParser.parse("postgres://admin:s3cret@db.example.com:6432/analytics")
        #expect(parsed.profile.kind == .postgres)
        #expect(parsed.profile.host == "db.example.com")
        #expect(parsed.profile.port == 6432)
        #expect(parsed.profile.username == "admin")
        #expect(parsed.profile.database == "analytics")
        #expect(parsed.password == "s3cret")
        #expect(parsed.profile.name == "analytics")
        #expect(parsed.profile.savePassword)
    }

    @Test("Accepts every PostgreSQL scheme spelling")
    func postgresAliases() throws {
        for scheme in ["postgres", "postgresql", "psql", "pgsql"] {
            let parsed = try ConnectionURLParser.parse("\(scheme)://u@h/d")
            #expect(parsed.profile.kind == .postgres)
        }
    }

    @Test("Tells MySQL and MariaDB apart")
    func mysqlAndMariaDB() throws {
        #expect(try ConnectionURLParser.parse("mysql://root@localhost/shop").profile.kind == .mysql)
        #expect(try ConnectionURLParser.parse("mariadb://root@localhost/shop").profile.kind == .mariadb)
        // MySQL's default port fills in when the URL omits it.
        #expect(try ConnectionURLParser.parse("mysql://root@localhost/shop").profile.port == 3306)
    }

    @Test("Unwraps a JDBC prefix")
    func jdbcPrefix() throws {
        let parsed = try ConnectionURLParser.parse("jdbc:postgresql://localhost:5432/app")
        #expect(parsed.profile.kind == .postgres)
        #expect(parsed.profile.database == "app")
        #expect(parsed.profile.port == 5432)
    }

    // MARK: - The parts that trip naive parsers

    @Test("A password containing @ does not break the host")
    func passwordWithAtSign() throws {
        let parsed = try ConnectionURLParser.parse("postgres://user:p@ss@w0rd@db.internal:5432/app")
        #expect(parsed.profile.host == "db.internal")
        #expect(parsed.profile.username == "user")
        #expect(parsed.password == "p@ss@w0rd")
    }

    @Test("A password containing : and / survives")
    func passwordWithSeparators() throws {
        let parsed = try ConnectionURLParser.parse("mysql://root:a:b/c@127.0.0.1:3306/shop")
        #expect(parsed.profile.username == "root")
        #expect(parsed.password == "a:b/c")
        #expect(parsed.profile.host == "127.0.0.1")
        #expect(parsed.profile.database == "shop")
    }

    @Test("Percent-encoded credentials are decoded")
    func percentEncoding() throws {
        let parsed = try ConnectionURLParser.parse("postgres://my%40user:p%40ss%2Fword@host/my%20db")
        #expect(parsed.profile.username == "my@user")
        #expect(parsed.password == "p@ss/word")
        #expect(parsed.profile.database == "my db")
    }

    @Test("Handles IPv6 hosts")
    func ipv6() throws {
        let bracketed = try ConnectionURLParser.parse("postgres://u@[::1]:5433/app")
        #expect(bracketed.profile.host == "::1")
        #expect(bracketed.profile.port == 5433)

        // Unbracketed and portless: the colons belong to the address, not a port.
        let bare = try ConnectionURLParser.parse("postgres://u@2001:db8::1/app")
        #expect(bare.profile.host == "2001:db8::1")
        #expect(bare.profile.port == 5432)
    }

    @Test("Takes the first host from a failover list")
    func failoverList() throws {
        let parsed = try ConnectionURLParser.parse("postgres://u@primary.example.com:5432,replica.example.com:5432/app")
        #expect(parsed.profile.host == "primary.example.com")
    }

    @Test("Omitting the database falls back to the username, as libpq does")
    func databaseDefaultsToUser() throws {
        let parsed = try ConnectionURLParser.parse("postgres://ada@localhost")
        #expect(parsed.profile.database == "ada")
        #expect(!parsed.warnings.isEmpty)
    }

    // MARK: - Query parameters

    @Test("Maps sslmode onto the profile")
    func sslModes() throws {
        #expect(try ConnectionURLParser.parse("postgres://u@h/d?sslmode=disable").profile.sslMode == .disable)
        #expect(try ConnectionURLParser.parse("postgres://u@h/d?sslmode=prefer").profile.sslMode == .prefer)
        #expect(try ConnectionURLParser.parse("postgres://u@h/d?sslmode=require").profile.sslMode == .require)
        #expect(try ConnectionURLParser.parse("mysql://u@h/d?useSSL=true").profile.sslMode == .prefer)
        #expect(try ConnectionURLParser.parse("mysql://u@h/d?ssl-mode=DISABLED").profile.sslMode == .disable)
    }

    @Test("Warns that verify-full is downgraded rather than silently honoured")
    func verifyFullWarns() throws {
        let parsed = try ConnectionURLParser.parse("postgres://u@h/d?sslmode=verify-full")
        #expect(parsed.profile.sslMode == .require)
        #expect(parsed.warnings.contains { $0.lowercased().contains("verify-full") })
    }

    @Test("Reads timeouts and read-only flags")
    func otherParameters() throws {
        #expect(try ConnectionURLParser.parse("postgres://u@h/d?connect_timeout=30").profile.connectTimeoutSeconds == 30)
        // Millisecond-style values are converted rather than taken as a 30000-second wait.
        #expect(try ConnectionURLParser.parse("postgres://u@h/d?connectTimeout=30000").profile.connectTimeoutSeconds == 30)
        #expect(try ConnectionURLParser.parse("postgres://u@h/d?readonly=true").profile.readOnly)
    }

    // MARK: - SQLite

    @Test("Parses SQLite URLs and bare paths")
    func sqliteForms() throws {
        #expect(try ConnectionURLParser.parse("sqlite:///Users/ada/app.sqlite").profile.filePath == "/Users/ada/app.sqlite")
        #expect(try ConnectionURLParser.parse("file:///tmp/data.db").profile.filePath == "/tmp/data.db")
        #expect(try ConnectionURLParser.parse("/Users/ada/app.sqlite").profile.kind == .sqlite)
        #expect(try ConnectionURLParser.parse("/Users/ada/app.sqlite").profile.filePath == "/Users/ada/app.sqlite")
        #expect(try ConnectionURLParser.parse("./local.db").profile.filePath == "./local.db")

        let named = try ConnectionURLParser.parse("sqlite:///var/db/inventory.sqlite")
        #expect(named.profile.name == "inventory")

        let readOnly = try ConnectionURLParser.parse("sqlite:///tmp/a.db?mode=ro")
        #expect(readOnly.profile.readOnly)
    }

    @Test("Expands a tilde in a SQLite path")
    func tildeExpansion() throws {
        let parsed = try ConnectionURLParser.parse("~/Databases/app.sqlite")
        #expect(!parsed.profile.filePath.hasPrefix("~"))
        #expect(parsed.profile.filePath.hasSuffix("/Databases/app.sqlite"))
    }

    // MARK: - libpq keyword form

    @Test("Parses the keyword/value form")
    func keywordValue() throws {
        let parsed = try ConnectionURLParser.parse("host=db.example.com port=5433 dbname=app user=ada password='se cret' sslmode=require")
        #expect(parsed.profile.kind == .postgres)
        #expect(parsed.profile.host == "db.example.com")
        #expect(parsed.profile.port == 5433)
        #expect(parsed.profile.database == "app")
        #expect(parsed.profile.username == "ada")
        #expect(parsed.password == "se cret")
        #expect(parsed.profile.sslMode == .require)
    }

    // MARK: - Tolerated wrappers

    @Test("Strips quotes and a DATABASE_URL= prefix")
    func tolerantInput() throws {
        let fromEnvFile = try ConnectionURLParser.parse("DATABASE_URL=\"postgres://u:p@h:5432/d\"")
        #expect(fromEnvFile.profile.host == "h")
        #expect(fromEnvFile.profile.database == "d")

        let quoted = try ConnectionURLParser.parse("  'mysql://root@localhost/shop'  ")
        #expect(quoted.profile.kind == .mysql)
    }

    // MARK: - Failures

    @Test("Rejects what it cannot understand")
    func errors() {
        #expect(throws: ConnectionURLError.empty) { _ = try ConnectionURLParser.parse("   ") }
        #expect(throws: ConnectionURLError.unsupportedScheme("redis")) {
            _ = try ConnectionURLParser.parse("redis://localhost:6379")
        }
        #expect(throws: ConnectionURLError.invalidPort("abc")) {
            _ = try ConnectionURLParser.parse("postgres://u@host:abc/db")
        }
        #expect(throws: ConnectionURLError.self) { _ = try ConnectionURLParser.parse("just some words") }
    }

    @Test("Recognises candidates without committing to parsing them")
    func candidateDetection() {
        #expect(ConnectionURLParser.looksLikeConnectionURL("postgres://u@h/d"))
        #expect(ConnectionURLParser.looksLikeConnectionURL("jdbc:mysql://h/d"))
        #expect(ConnectionURLParser.looksLikeConnectionURL("/Users/ada/app.sqlite"))
        #expect(ConnectionURLParser.looksLikeConnectionURL("host=localhost dbname=app"))
        #expect(!ConnectionURLParser.looksLikeConnectionURL("SELECT * FROM users"))
        #expect(!ConnectionURLParser.looksLikeConnectionURL("https://example.com"))
        #expect(!ConnectionURLParser.looksLikeConnectionURL(""))
    }

    // MARK: - Round trip

    @Test("Serialises back to a URL that parses the same way")
    func roundTrip() throws {
        var profile = ConnectionProfile(kind: .postgres)
        profile.host = "db.example.com"
        profile.port = 6432
        profile.username = "my@user"
        profile.database = "analytics"
        profile.sslMode = .require

        let url = ConnectionURLParser.string(for: profile, password: "p@ss/word", includePassword: true)
        let parsed = try ConnectionURLParser.parse(url)

        #expect(parsed.profile.host == profile.host)
        #expect(parsed.profile.port == profile.port)
        #expect(parsed.profile.username == profile.username)
        #expect(parsed.profile.database == profile.database)
        #expect(parsed.profile.sslMode == .require)
        #expect(parsed.password == "p@ss/word")
    }

    @Test("Leaves the password out unless asked")
    func passwordOmittedByDefault() {
        var profile = ConnectionProfile(kind: .mysql)
        profile.host = "localhost"
        profile.username = "root"
        profile.database = "shop"

        let url = ConnectionURLParser.string(for: profile, password: "hunter2")
        #expect(url == "mysql://root@localhost/shop")
        #expect(!url.contains("hunter2"))
    }

    @Test("Serialises SQLite as a file URL")
    func sqliteRoundTrip() throws {
        var profile = ConnectionProfile(kind: .sqlite)
        profile.filePath = "/Users/ada/app.sqlite"
        let url = ConnectionURLParser.string(for: profile)
        #expect(url == "sqlite:///Users/ada/app.sqlite")
        #expect(try ConnectionURLParser.parse(url).profile.filePath == profile.filePath)
    }
}
