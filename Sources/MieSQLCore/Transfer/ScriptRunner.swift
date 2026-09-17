import Foundation

public struct ScriptProgress: Sendable {
    public let statementIndex: Int
    public let statementCount: Int
    public let succeeded: Int
    public let failed: Int
    public let currentStatement: String

    public var fraction: Double {
        statementCount == 0 ? 0 : Double(statementIndex) / Double(statementCount)
    }
}

public struct ScriptFailure: Sendable, Identifiable {
    public let id = UUID()
    public let statement: String
    public let message: String
}

public struct ScriptRunSummary: Sendable {
    public let total: Int
    public let succeeded: Int
    public let failures: [ScriptFailure]
    public let duration: TimeInterval
}

/// Runs a `.sql` file — the other half of the dumper. Statements execute one at a time so
/// progress is honest and a failure can be reported with the statement that caused it.
public struct ScriptRunner: Sendable {

    public init() {}

    public func run(
        script: String,
        using driver: any DatabaseDriver,
        kind: DatabaseKind,
        stopOnError: Bool,
        progress: @Sendable @escaping (ScriptProgress) -> Void
    ) async throws -> ScriptRunSummary {
        let statements = SQLStatementSplitter.split(script, kind: kind)
        let started = Date()
        var succeeded = 0
        var failures: [ScriptFailure] = []

        for (index, statement) in statements.enumerated() {
            try Task.checkCancellation()
            progress(ScriptProgress(
                statementIndex: index,
                statementCount: statements.count,
                succeeded: succeeded,
                failed: failures.count,
                currentStatement: statement.text
            ))

            do {
                _ = try await driver.execute(statement.text)
                succeeded += 1
            } catch {
                let message = (error as? DatabaseError)?.errorDescription ?? error.localizedDescription
                failures.append(ScriptFailure(statement: statement.text, message: message))
                if stopOnError {
                    break
                }
            }
        }

        progress(ScriptProgress(
            statementIndex: statements.count,
            statementCount: statements.count,
            succeeded: succeeded,
            failed: failures.count,
            currentStatement: ""
        ))

        return ScriptRunSummary(
            total: statements.count,
            succeeded: succeeded,
            failures: failures,
            duration: Date().timeIntervalSince(started)
        )
    }

    public func run(
        fileAt url: URL,
        using driver: any DatabaseDriver,
        kind: DatabaseKind,
        stopOnError: Bool,
        progress: @Sendable @escaping (ScriptProgress) -> Void
    ) async throws -> ScriptRunSummary {
        // Fall back to Latin-1 so a dump produced by an older client still loads rather
        // than failing with an unhelpful decoding error.
        let contents: String
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            contents = utf8
        } else if let latin = try? String(contentsOf: url, encoding: .isoLatin1) {
            contents = latin
        } else {
            throw DatabaseError(message: "Could not read \(url.lastPathComponent) as text.")
        }
        return try await run(script: contents, using: driver, kind: kind, stopOnError: stopOnError, progress: progress)
    }
}
