import Foundation

enum DriveFormatters {
    static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    static let compactBytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    static func fileSize(_ value: Int64) -> String {
        bytes.string(fromByteCount: value)
    }

    static func compactFileSize(_ value: Int64) -> String {
        compactBytes.string(fromByteCount: value)
    }

    static func displayPath(for url: URL) -> String {
        let standardizedURL = url.standardizedFileURL
        let standardizedPath = standardizedURL.path

        for directory in namedStandardDirectories() {
            let rootPath = directory.url.standardizedFileURL.path
            if standardizedPath == rootPath {
                return directory.name
            }
            if standardizedPath.hasPrefix(rootPath + "/") {
                let relativePath = String(standardizedPath.dropFirst(rootPath.count + 1))
                return relativePath.isEmpty ? directory.name : "\(directory.name)/\(relativePath)"
            }
        }

        let homeURL = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let homePath = homeURL.path
        if standardizedPath == homePath {
            return "用户"
        }
        if standardizedPath.hasPrefix(homePath + "/") {
            let relativePath = String(standardizedPath.dropFirst(homePath.count + 1))
            return relativePath.isEmpty ? "用户" : "用户/\(relativePath)"
        }

        if let volumeRoot = mountedVolumeRoot(for: standardizedURL) {
            let rootPath = volumeRoot.standardizedFileURL.path
            let volumeName = volumeRoot.lastPathComponent.isEmpty ? "移动硬盘" : volumeRoot.lastPathComponent
            if standardizedPath == rootPath {
                return "移动硬盘/\(volumeName)"
            }
            if standardizedPath.hasPrefix(rootPath + "/") {
                let relativePath = String(standardizedPath.dropFirst(rootPath.count + 1))
                return relativePath.isEmpty ? "移动硬盘/\(volumeName)" : "移动硬盘/\(volumeName)/\(relativePath)"
            }
        }

        let components = standardizedURL.pathComponents.filter { $0 != "/" }
        return components.isEmpty ? "系统根目录" : components.joined(separator: "/")
    }

    private static func namedStandardDirectories() -> [(name: String, url: URL)] {
        let fileManager = FileManager.default
        return [
            ("桌面", fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first),
            ("文稿", fileManager.urls(for: .documentDirectory, in: .userDomainMask).first),
            ("应用程序", fileManager.urls(for: .applicationDirectory, in: .localDomainMask).first),
            ("下载", fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first),
            ("照片", fileManager.urls(for: .picturesDirectory, in: .userDomainMask).first),
            ("音乐", fileManager.urls(for: .musicDirectory, in: .userDomainMask).first),
            ("影片", fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first)
        ].compactMap { name, url in
            guard let url else { return nil }
            return (name, url.standardizedFileURL)
        }
    }

    private static func mountedVolumeRoot(for url: URL) -> URL? {
        let targetPath = url.standardizedFileURL.path
        let volumes = FileManager.default
            .mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []

        return volumes
            .map(\.standardizedFileURL)
            .filter { volume in
                let volumePath = volume.path
                guard volumePath != "/" else { return false }
                return targetPath == volumePath || targetPath.hasPrefix(volumePath + "/")
            }
            .sorted { $0.path.count > $1.path.count }
            .first
    }
}
