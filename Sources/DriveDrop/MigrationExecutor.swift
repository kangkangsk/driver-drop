import Foundation

struct MigrationProgress: Sendable {
    let itemID: UUID
    let copiedBytes: Int64
    let totalBytes: Int64

    var fraction: Double {
        guard totalBytes > 0 else { return 1 }
        return min(max(Double(copiedBytes) / Double(totalBytes), 0), 1)
    }
}

struct MigrationExecutionResult: Sendable {
    let itemID: UUID
    let itemName: String
    let sourceURL: URL
    let destinationURL: URL
    let bytesCopied: Int64
    let resumedBytes: Int64
    let skippedItems: Int
    let mode: MigrationMode
}

enum MigrationExecutorError: LocalizedError {
    case sourceMissing(URL)
    case destinationNotWritable(URL)
    case verificationFailed(sourceBytes: Int64, destinationBytes: Int64)
    case unsupportedItem(URL)

    var errorDescription: String? {
        switch self {
        case .sourceMissing(let url):
            return "源文件不存在：\(DriveFormatters.displayPath(for: url))"
        case .destinationNotWritable(let url):
            return "目标路径不可写：\(DriveFormatters.displayPath(for: url))"
        case .verificationFailed(let sourceBytes, let destinationBytes):
            return "校验失败：源文件 \(sourceBytes) 字节，目标文件 \(destinationBytes) 字节"
        case .unsupportedItem(let url):
            return "暂不支持迁移该项目：\(DriveFormatters.displayPath(for: url))"
        }
    }
}

final class MigrationExecutor: @unchecked Sendable {
    private let fileManager = FileManager.default
    private let chunkSize = 2 * 1024 * 1024

    func resumableBytes(for item: MigrationItem, destinationRoot: URL) -> Int64 {
        let temporaryDestination = existingTemporaryDestinationURL(for: item, destinationRoot: destinationRoot)
        guard fileManager.fileExists(atPath: temporaryDestination.path) else {
            return 0
        }

        let existingBytes = (try? measuredSize(of: temporaryDestination, skipSystemCaches: false)) ?? 0
        return min(max(existingBytes, 0), item.estimatedSize)
    }

    func migrate(
        item: MigrationItem,
        destinationRoot: URL,
        mode: MigrationMode,
        options: MigrationOptions,
        progress: @escaping @Sendable (MigrationProgress) async -> Void
    ) async throws -> MigrationExecutionResult {
        guard fileManager.fileExists(atPath: item.sourceURL.path) else {
            throw MigrationExecutorError.sourceMissing(item.sourceURL)
        }

        try Task.checkCancellation()
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        guard fileManager.isWritableFile(atPath: destinationRoot.path) else {
            throw MigrationExecutorError.destinationNotWritable(destinationRoot)
        }

        let sourceIsDirectory = try isDirectory(item.sourceURL)
        let finalDestination = uniqueDestinationURL(
            for: destinationRoot.appendingPathComponent(item.displayName, isDirectory: sourceIsDirectory)
        )
        let temporaryDestination = try preparedTemporaryDestinationURL(
            for: item,
            destinationRoot: destinationRoot,
            isDirectory: sourceIsDirectory
        )

        do {
            let entries = try collectEntries(from: item.sourceURL, skipSystemCaches: options.skipSystemCaches)
            let totalBytes = max(entries.reduce(Int64(0)) { $0 + $1.size }, 1)
            var copiedBytes: Int64 = 0
            var resumedBytes: Int64 = 0
            var skippedItems = 0

            if sourceIsDirectory {
                if fileExistsAsNonDirectory(temporaryDestination) {
                    try fileManager.removeItem(at: temporaryDestination)
                }
                try fileManager.createDirectory(at: temporaryDestination, withIntermediateDirectories: true)
                if options.preserveMetadata {
                    try preserveAttributes(from: item.sourceURL, to: temporaryDestination)
                }
            } else if fileExistsAsDirectory(temporaryDestination) {
                try fileManager.removeItem(at: temporaryDestination)
            }

            for entry in entries {
                try Task.checkCancellation()

                if entry.shouldSkip {
                    skippedItems += 1
                    continue
                }

                let destination = sourceIsDirectory
                    ? temporaryDestination.appendingPathComponent(entry.relativePath, isDirectory: entry.kind == .directory)
                    : temporaryDestination

                switch entry.kind {
                case .directory:
                    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                    if options.preserveMetadata {
                        try preserveAttributes(from: entry.sourceURL, to: destination)
                    }
                case .symlink(let targetPath):
                    try createParentDirectory(for: destination)
                    try? fileManager.removeItem(at: destination)
                    try fileManager.createSymbolicLink(atPath: destination.path, withDestinationPath: targetPath)
                case .file:
                    try await copyFile(
                        from: entry.sourceURL,
                        to: destination,
                        expectedBytes: entry.size,
                        preserveMetadata: options.preserveMetadata
                    ) { bytes, wasResumed in
                        copiedBytes += bytes
                        if wasResumed {
                            resumedBytes += bytes
                        }
                        await progress(MigrationProgress(itemID: item.id, copiedBytes: copiedBytes, totalBytes: totalBytes))
                    }
                }
            }

            if options.verifyAfterCopy {
                let destinationBytes = try measuredSize(of: temporaryDestination, skipSystemCaches: options.skipSystemCaches)
                let sourceBytes = entries.reduce(Int64(0)) { $0 + ($1.shouldSkip ? 0 : $1.size) }
                guard sourceBytes == destinationBytes else {
                    throw MigrationExecutorError.verificationFailed(sourceBytes: sourceBytes, destinationBytes: destinationBytes)
                }
            }

            try Task.checkCancellation()
            try fileManager.moveItem(at: temporaryDestination, to: finalDestination)

            if mode == .move {
                try fileManager.removeItem(at: item.sourceURL)
            }

            await progress(MigrationProgress(itemID: item.id, copiedBytes: max(copiedBytes, 1), totalBytes: max(copiedBytes, 1)))

            return MigrationExecutionResult(
                itemID: item.id,
                itemName: item.displayName,
                sourceURL: item.sourceURL,
                destinationURL: finalDestination,
                bytesCopied: copiedBytes,
                resumedBytes: resumedBytes,
                skippedItems: skippedItems,
                mode: mode
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let migrationError as MigrationExecutorError {
            if case .verificationFailed = migrationError {
                try? fileManager.removeItem(at: temporaryDestination)
            }
            throw migrationError
        } catch {
            throw error
        }
    }

    func writeReport(results: [MigrationExecutionResult], failures: [(String, String)], to destinationRoot: URL) throws -> URL {
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let timestamp = formatter.string(from: Date())
        let fileSafeTimestamp = timestamp.replacingOccurrences(of: ":", with: "-")
        let reportURL = destinationRoot.appendingPathComponent("DriveDrop-迁移报告-\(fileSafeTimestamp).md")

        var lines: [String] = [
            "# DriveDrop 迁移报告",
            "",
            "- 生成时间：\(timestamp)",
            "- 成功项目：\(results.count)",
            "- 失败项目：\(failures.count)",
            ""
        ]

        if !results.isEmpty {
            lines.append("## 成功")
            lines.append("")
            for result in results {
                lines.append("- \(result.itemName)")
                lines.append("  - 来源：\(DriveFormatters.displayPath(for: result.sourceURL))")
                lines.append("  - 目标：\(DriveFormatters.displayPath(for: result.destinationURL))")
                lines.append("  - 大小：\(DriveFormatters.fileSize(result.bytesCopied))")
                if result.resumedBytes > 0 {
                    lines.append("  - 续传：复用 \(DriveFormatters.fileSize(result.resumedBytes))")
                }
                lines.append("  - 方式：\(result.mode.rawValue)")
                if result.skippedItems > 0 {
                    lines.append("  - 跳过：\(result.skippedItems) 个缓存/系统项")
                }
            }
            lines.append("")
        }

        if !failures.isEmpty {
            lines.append("## 失败")
            lines.append("")
            for failure in failures {
                lines.append("- \(failure.0)：\(failure.1)")
            }
            lines.append("")
        }

        try lines.joined(separator: "\n").write(to: reportURL, atomically: true, encoding: .utf8)
        return reportURL
    }

    private func collectEntries(from sourceURL: URL, skipSystemCaches: Bool) throws -> [CopyEntry] {
        let sourceIsDirectory = try isDirectory(sourceURL)

        if !sourceIsDirectory {
            return [
                CopyEntry(
                    sourceURL: sourceURL,
                    relativePath: sourceURL.lastPathComponent,
                    kind: try kind(of: sourceURL),
                    size: try measuredSize(of: sourceURL, skipSystemCaches: skipSystemCaches),
                    shouldSkip: shouldSkip(sourceURL, skipSystemCaches: skipSystemCaches)
                )
            ]
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: nil
        ) else {
            throw MigrationExecutorError.unsupportedItem(sourceURL)
        }

        var entries: [CopyEntry] = []
        let rootPath = sourceURL.standardizedFileURL.path

        for case let url as URL in enumerator {
            let skip = shouldSkip(url, skipSystemCaches: skipSystemCaches)
            if skip, (try? isDirectory(url)) == true {
                enumerator.skipDescendants()
            }

            let relativePath = relativePath(from: rootPath, to: url)
            entries.append(
                CopyEntry(
                    sourceURL: url,
                    relativePath: relativePath,
                    kind: try kind(of: url),
                    size: skip ? 0 : (try measuredSize(of: url, skipSystemCaches: skipSystemCaches, descendIntoDirectories: false)),
                    shouldSkip: skip
                )
            )
        }

        return entries.sorted { lhs, rhs in
            if lhs.kind == .directory, rhs.kind != .directory {
                return true
            }
            if lhs.kind != .directory, rhs.kind == .directory {
                return false
            }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }

    private func copyFile(
        from source: URL,
        to destination: URL,
        expectedBytes: Int64,
        preserveMetadata: Bool,
        progress: (Int64, Bool) async throws -> Void
    ) async throws {
        try createParentDirectory(for: destination)

        let resumeOffset = try resumableOffset(for: destination, expectedBytes: expectedBytes)
        if resumeOffset == 0 {
            try? fileManager.removeItem(at: destination)
            guard fileManager.createFile(atPath: destination.path, contents: nil) else {
                throw MigrationExecutorError.destinationNotWritable(destination)
            }
        }

        let readHandle = try FileHandle(forReadingFrom: source)
        let writeHandle = try FileHandle(forWritingTo: destination)

        defer {
            readHandle.closeFile()
            writeHandle.closeFile()
        }

        if resumeOffset > 0 {
            try await progress(resumeOffset, true)
            if resumeOffset >= expectedBytes {
                writeHandle.truncateFile(atOffset: UInt64(expectedBytes))
                if preserveMetadata {
                    try preserveAttributes(from: source, to: destination)
                }
                return
            }

            readHandle.seek(toFileOffset: UInt64(resumeOffset))
            writeHandle.seekToEndOfFile()
        }

        while true {
            try Task.checkCancellation()
            let data = readHandle.readData(ofLength: chunkSize)
            if data.isEmpty {
                break
            }
            writeHandle.write(data)
            try await progress(Int64(data.count), false)
        }

        writeHandle.synchronizeFile()

        if preserveMetadata {
            try preserveAttributes(from: source, to: destination)
        }
    }

    private func createParentDirectory(for url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    private func resumableOffset(for destination: URL, expectedBytes: Int64) throws -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory) else {
            return 0
        }

        if isDirectory.boolValue {
            try fileManager.removeItem(at: destination)
            return 0
        }

        let attributes = try fileManager.attributesOfItem(atPath: destination.path)
        let existingBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard existingBytes > 0 else {
            return 0
        }

        guard existingBytes <= expectedBytes else {
            try fileManager.removeItem(at: destination)
            return 0
        }

        return existingBytes
    }

    private func preserveAttributes(from source: URL, to destination: URL) throws {
        let attributes = try fileManager.attributesOfItem(atPath: source.path)
        var preserved: [FileAttributeKey: Any] = [:]

        for key in [FileAttributeKey.creationDate, .modificationDate, .posixPermissions] {
            if let value = attributes[key] {
                preserved[key] = value
            }
        }

        if !preserved.isEmpty {
            try fileManager.setAttributes(preserved, ofItemAtPath: destination.path)
        }
    }

    private func uniqueDestinationURL(for requestedURL: URL) -> URL {
        guard fileManager.fileExists(atPath: requestedURL.path) else {
            return requestedURL
        }

        let parent = requestedURL.deletingLastPathComponent()
        let baseName = requestedURL.deletingPathExtension().lastPathComponent
        let fileExtension = requestedURL.pathExtension

        for index in 2..<10_000 {
            let candidateName = fileExtension.isEmpty ? "\(baseName) \(index)" : "\(baseName) \(index).\(fileExtension)"
            let candidate = parent.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return parent.appendingPathComponent("\(requestedURL.lastPathComponent) \(UUID().uuidString)")
    }

    func temporaryDestinationURL(for item: MigrationItem, destinationRoot: URL) -> URL {
        temporaryDestinationURL(
            for: item,
            destinationRoot: destinationRoot,
            isDirectory: item.sourceURL.hasDirectoryPath
        )
    }

    private func temporaryDestinationURL(for item: MigrationItem, destinationRoot: URL, isDirectory: Bool) -> URL {
        destinationRoot.appendingPathComponent(
            ".\(safeTemporaryBaseName(for: item.displayName)).\(resumeIdentifier(for: item, isDirectory: isDirectory)).drivedrop-part",
            isDirectory: isDirectory
        )
    }

    private func existingTemporaryDestinationURL(for item: MigrationItem, destinationRoot: URL) -> URL {
        let sourceIsDirectory = item.sourceURL.hasDirectoryPath
        let stableURL = temporaryDestinationURL(for: item, destinationRoot: destinationRoot, isDirectory: sourceIsDirectory)
        if fileManager.fileExists(atPath: stableURL.path) {
            return stableURL
        }

        return legacyTemporaryDestinationURL(
            for: item,
            destinationRoot: destinationRoot,
            stableURL: stableURL,
            isDirectory: sourceIsDirectory
        ) ?? stableURL
    }

    private func preparedTemporaryDestinationURL(for item: MigrationItem, destinationRoot: URL, isDirectory: Bool) throws -> URL {
        let stableURL = temporaryDestinationURL(for: item, destinationRoot: destinationRoot, isDirectory: isDirectory)
        guard !fileManager.fileExists(atPath: stableURL.path),
              let legacyURL = legacyTemporaryDestinationURL(
                for: item,
                destinationRoot: destinationRoot,
                stableURL: stableURL,
                isDirectory: isDirectory
              )
        else {
            return stableURL
        }

        try fileManager.moveItem(at: legacyURL, to: stableURL)
        return stableURL
    }

    private func legacyTemporaryDestinationURL(
        for item: MigrationItem,
        destinationRoot: URL,
        stableURL: URL,
        isDirectory: Bool
    ) -> URL? {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: destinationRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: []
        ) else {
            return nil
        }

        let oldPrefix = ".\(item.displayName)."
        let safePrefix = ".\(safeTemporaryBaseName(for: item.displayName))."
        let stableName = stableURL.lastPathComponent
        let candidates = contents.compactMap { url -> (url: URL, modifiedAt: Date, bytes: Int64)? in
            let name = url.lastPathComponent
            guard name != stableName,
                  name.hasSuffix(".drivedrop-part"),
                  name.hasPrefix(oldPrefix) || name.hasPrefix(safePrefix)
            else {
                return nil
            }

            var isCandidateDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isCandidateDirectory),
                  isCandidateDirectory.boolValue == isDirectory
            else {
                return nil
            }

            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let modifiedAt = values?.contentModificationDate ?? .distantPast
            let bytes = (try? measuredSize(of: url, skipSystemCaches: false)) ?? 0
            return bytes > 0 ? (url, modifiedAt, bytes) : nil
        }

        return candidates
            .sorted { lhs, rhs in
                if lhs.bytes != rhs.bytes {
                    return lhs.bytes > rhs.bytes
                }
                return lhs.modifiedAt > rhs.modifiedAt
            }
            .first?
            .url
    }

    private func resumeIdentifier(for item: MigrationItem, isDirectory: Bool) -> String {
        var parts = [
            item.sourceURL.standardizedFileURL.path,
            item.displayName,
            isDirectory ? "directory" : "file"
        ]

        if let values = try? item.sourceURL.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]) {
            let sourceBytes = values.fileSize ?? values.totalFileAllocatedSize ?? Int(item.estimatedSize)
            parts.append("\(sourceBytes)")
            if let modifiedAt = values.contentModificationDate {
                parts.append("\(modifiedAt.timeIntervalSince1970)")
            }
        } else {
            parts.append("\(item.estimatedSize)")
        }

        return stableHash(parts.joined(separator: "|"))
    }

    private func stableHash(_ value: String) -> String {
        let prime: UInt64 = 1_099_511_628_211
        var hash: UInt64 = 14_695_981_039_346_656_037

        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }

        return String(format: "%016llx", hash)
    }

    private func safeTemporaryBaseName(for name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = name.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let cleaned = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return String((cleaned.isEmpty ? "item" : cleaned).prefix(80))
    }

    private func fileExistsAsDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func fileExistsAsNonDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private func measuredSize(
        of url: URL,
        skipSystemCaches: Bool,
        descendIntoDirectories: Bool = true
    ) throws -> Int64 {
        if shouldSkip(url, skipSystemCaches: skipSystemCaches) {
            return 0
        }

        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey])

        if values.isSymbolicLink == true {
            return 0
        }

        if values.isDirectory == true {
            guard descendIntoDirectories else { return 0 }
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey],
                options: [],
                errorHandler: nil
            ) else {
                return 0
            }

            var total: Int64 = 0
            for case let child as URL in enumerator {
                if shouldSkip(child, skipSystemCaches: skipSystemCaches) {
                    if (try? isDirectory(child)) == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                let childValues = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey])
                if childValues.isDirectory != true, childValues.isSymbolicLink != true {
                    total += Int64(childValues.fileSize ?? childValues.totalFileAllocatedSize ?? 0)
                }
            }
            return total
        }

        return Int64(values.fileSize ?? values.totalFileAllocatedSize ?? 0)
    }

    private func kind(of url: URL) throws -> CopyEntry.Kind {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])

        if values.isSymbolicLink == true {
            return .symlink(try fileManager.destinationOfSymbolicLink(atPath: url.path))
        }

        if values.isDirectory == true {
            return .directory
        }

        return .file
    }

    private func isDirectory(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    }

    private func relativePath(from rootPath: String, to url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else {
            return url.lastPathComponent
        }

        return String(path.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func shouldSkip(_ url: URL, skipSystemCaches: Bool) -> Bool {
        guard skipSystemCaches else { return false }

        let skippedNames: Set<String> = [
            ".DS_Store",
            ".Spotlight-V100",
            ".TemporaryItems",
            ".Trashes",
            ".fseventsd",
            "Caches",
            "__MACOSX"
        ]

        return skippedNames.contains(url.lastPathComponent)
    }
}

private struct CopyEntry: Sendable {
    enum Kind: Equatable, Sendable {
        case directory
        case file
        case symlink(String)
    }

    let sourceURL: URL
    let relativePath: String
    let kind: Kind
    let size: Int64
    let shouldSkip: Bool
}
