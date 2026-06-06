import Foundation

@main
struct VerifyMigrationExecutor {
    static func main() async throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.remove() }

        try await verifyFileCopy(workspace: workspace)
        try await verifyKeepBothConflict(workspace: workspace)
        try await verifyResumePartialFile(workspace: workspace)
        try await verifyResumePartialDirectory(workspace: workspace)
        try await verifyResumeAfterRestart(workspace: workspace)
        try await verifyLegacyResumeFileAdoption(workspace: workspace)

        print("MigrationExecutor verification passed")
    }

    private static func verifyFileCopy(workspace: TemporaryWorkspace) async throws {
        let source = workspace.source.appendingPathComponent("hello.txt")
        try "hello drivedrop".write(to: source, atomically: true, encoding: .utf8)

        let item = MigrationItem(
            id: UUID(),
            sourceURL: source,
            displayName: source.lastPathComponent,
            sourceSummary: DriveFormatters.displayPath(for: workspace.source),
            estimatedSize: 15,
            status: .waiting,
            progress: 0,
            hasConflict: false
        )

        let result = try await MigrationExecutor().migrate(
            item: item,
            destinationRoot: workspace.destination,
            mode: .copy,
            options: MigrationOptions()
        ) { _ in }

        let copiedText = try String(contentsOf: result.destinationURL, encoding: .utf8)
        try require(copiedText == "hello drivedrop", "copied file content mismatch")
        try require(FileManager.default.fileExists(atPath: source.path), "copy mode removed the source file")
    }

    private static func verifyKeepBothConflict(workspace: TemporaryWorkspace) async throws {
        let source = workspace.source.appendingPathComponent("client.zip")
        let existingDestination = workspace.destination.appendingPathComponent("client.zip")
        try "new".write(to: source, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: workspace.destination, withIntermediateDirectories: true)
        try "old".write(to: existingDestination, atomically: true, encoding: .utf8)

        let item = MigrationItem(
            id: UUID(),
            sourceURL: source,
            displayName: source.lastPathComponent,
            sourceSummary: DriveFormatters.displayPath(for: workspace.source),
            estimatedSize: 3,
            status: .waiting,
            progress: 0,
            hasConflict: false,
            conflictResolved: true
        )

        let result = try await MigrationExecutor().migrate(
            item: item,
            destinationRoot: workspace.destination,
            mode: .copy,
            options: MigrationOptions()
        ) { _ in }

        try require(try String(contentsOf: existingDestination, encoding: .utf8) == "old", "existing destination was overwritten")
        try require(result.destinationURL.lastPathComponent == "client 2.zip", "conflict file was not renamed")
        try require(try String(contentsOf: result.destinationURL, encoding: .utf8) == "new", "renamed destination content mismatch")
    }

    private static func verifyResumePartialFile(workspace: TemporaryWorkspace) async throws {
        let source = workspace.source.appendingPathComponent("large.bin")
        let sourceData = deterministicData(byteCount: 5 * 1024 * 1024 + 137)
        try sourceData.write(to: source)

        let item = MigrationItem(
            id: UUID(),
            sourceURL: source,
            displayName: source.lastPathComponent,
            sourceSummary: DriveFormatters.displayPath(for: workspace.source),
            estimatedSize: Int64(sourceData.count),
            status: .paused,
            progress: 0.4,
            hasConflict: false
        )

        let executor = MigrationExecutor()
        try FileManager.default.createDirectory(at: workspace.destination, withIntermediateDirectories: true)
        let temporaryDestination = executor.temporaryDestinationURL(for: item, destinationRoot: workspace.destination)
        let partialBytes = 2 * 1024 * 1024 + 19
        try Data(sourceData.prefix(partialBytes)).write(to: temporaryDestination)

        let result = try await executor.migrate(
            item: item,
            destinationRoot: workspace.destination,
            mode: .copy,
            options: MigrationOptions()
        ) { _ in }

        try require(result.resumedBytes == Int64(partialBytes), "partial file bytes were not reused")
        try require(!FileManager.default.fileExists(atPath: temporaryDestination.path), "temporary file remained after resume")
        try require(try Data(contentsOf: result.destinationURL) == sourceData, "resumed file content mismatch")
    }

    private static func verifyResumePartialDirectory(workspace: TemporaryWorkspace) async throws {
        let sourceDirectory = workspace.source.appendingPathComponent("album", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        let cover = deterministicData(byteCount: 1024 * 1024 + 7)
        let movie = deterministicData(byteCount: 3 * 1024 * 1024 + 91)
        try cover.write(to: sourceDirectory.appendingPathComponent("cover.jpg"))
        try movie.write(to: sourceDirectory.appendingPathComponent("movie.mov"))

        let item = MigrationItem(
            id: UUID(),
            sourceURL: sourceDirectory,
            displayName: sourceDirectory.lastPathComponent,
            sourceSummary: DriveFormatters.displayPath(for: workspace.source),
            estimatedSize: Int64(cover.count + movie.count),
            status: .paused,
            progress: 0.3,
            hasConflict: false
        )

        let executor = MigrationExecutor()
        let temporaryDestination = executor.temporaryDestinationURL(for: item, destinationRoot: workspace.destination)
        try FileManager.default.createDirectory(at: temporaryDestination, withIntermediateDirectories: true)
        try cover.write(to: temporaryDestination.appendingPathComponent("cover.jpg"))
        let moviePartialBytes = 512 * 1024 + 33
        try Data(movie.prefix(moviePartialBytes)).write(to: temporaryDestination.appendingPathComponent("movie.mov"))

        let result = try await executor.migrate(
            item: item,
            destinationRoot: workspace.destination,
            mode: .copy,
            options: MigrationOptions()
        ) { _ in }

        let expectedResumedBytes = Int64(cover.count + moviePartialBytes)
        try require(result.resumedBytes == expectedResumedBytes, "partial directory bytes were not reused")
        try require(try Data(contentsOf: result.destinationURL.appendingPathComponent("cover.jpg")) == cover, "resumed directory cover mismatch")
        try require(try Data(contentsOf: result.destinationURL.appendingPathComponent("movie.mov")) == movie, "resumed directory movie mismatch")
    }

    private static func verifyResumeAfterRestart(workspace: TemporaryWorkspace) async throws {
        let source = workspace.source.appendingPathComponent("restart.bin")
        let sourceData = deterministicData(byteCount: 4 * 1024 * 1024 + 711)
        try sourceData.write(to: source)

        let firstQueueItem = MigrationItem(
            id: UUID(),
            sourceURL: source,
            displayName: source.lastPathComponent,
            sourceSummary: DriveFormatters.displayPath(for: workspace.source),
            estimatedSize: Int64(sourceData.count),
            status: .copying,
            progress: 0.2,
            hasConflict: false
        )
        let restartedQueueItem = MigrationItem(
            id: UUID(),
            sourceURL: source,
            displayName: source.lastPathComponent,
            sourceSummary: DriveFormatters.displayPath(for: workspace.source),
            estimatedSize: Int64(sourceData.count),
            status: .waiting,
            progress: 0,
            hasConflict: false
        )

        let executor = MigrationExecutor()
        let firstTemporaryDestination = executor.temporaryDestinationURL(for: firstQueueItem, destinationRoot: workspace.destination)
        let restartedTemporaryDestination = executor.temporaryDestinationURL(for: restartedQueueItem, destinationRoot: workspace.destination)
        try require(firstTemporaryDestination == restartedTemporaryDestination, "resume temp path changed after queue restart")

        let partialBytes = 1024 * 1024 + 301
        try FileManager.default.createDirectory(at: workspace.destination, withIntermediateDirectories: true)
        try Data(sourceData.prefix(partialBytes)).write(to: firstTemporaryDestination)

        let result = try await executor.migrate(
            item: restartedQueueItem,
            destinationRoot: workspace.destination,
            mode: .copy,
            options: MigrationOptions()
        ) { _ in }

        try require(result.resumedBytes == Int64(partialBytes), "restart resume bytes were not reused")
        try require(try Data(contentsOf: result.destinationURL) == sourceData, "restart resumed file content mismatch")
    }

    private static func verifyLegacyResumeFileAdoption(workspace: TemporaryWorkspace) async throws {
        let source = workspace.source.appendingPathComponent("legacy.bin")
        let sourceData = deterministicData(byteCount: 3 * 1024 * 1024 + 503)
        try sourceData.write(to: source)

        let item = MigrationItem(
            id: UUID(),
            sourceURL: source,
            displayName: source.lastPathComponent,
            sourceSummary: DriveFormatters.displayPath(for: workspace.source),
            estimatedSize: Int64(sourceData.count),
            status: .waiting,
            progress: 0,
            hasConflict: false
        )

        let partialBytes = 768 * 1024 + 45
        try FileManager.default.createDirectory(at: workspace.destination, withIntermediateDirectories: true)
        let legacyTemporaryDestination = workspace.destination.appendingPathComponent(
            ".\(source.lastPathComponent).\(UUID().uuidString).drivedrop-part"
        )
        try Data(sourceData.prefix(partialBytes)).write(to: legacyTemporaryDestination)

        let executor = MigrationExecutor()
        let result = try await executor.migrate(
            item: item,
            destinationRoot: workspace.destination,
            mode: .copy,
            options: MigrationOptions()
        ) { _ in }

        try require(result.resumedBytes == Int64(partialBytes), "legacy partial file was not adopted")
        try require(!FileManager.default.fileExists(atPath: legacyTemporaryDestination.path), "legacy partial file was not moved away")
        try require(try Data(contentsOf: result.destinationURL) == sourceData, "legacy resumed file content mismatch")
    }

    private static func deterministicData(byteCount: Int) -> Data {
        Data((0..<byteCount).map { UInt8(($0 * 31 + 17) % 251) })
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw VerificationError(message)
        }
    }
}

private struct TemporaryWorkspace {
    let root: URL
    let source: URL
    let destination: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DriveDropVerifier-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct VerificationError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
