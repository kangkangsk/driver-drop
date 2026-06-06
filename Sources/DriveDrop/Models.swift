import Foundation

enum SourceKind: String, CaseIterable, Identifiable, Sendable {
    case user = "用户"
    case desktop = "桌面"
    case documents = "文稿"
    case applications = "应用程序"
    case downloads = "下载"
    case photos = "照片"
    case music = "音乐"
    case movies = "影片"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .user:
            return "person.crop.circle"
        case .desktop:
            return "desktopcomputer"
        case .documents:
            return "doc.text"
        case .applications:
            return "square.grid.2x2"
        case .downloads:
            return "arrow.down.circle"
        case .photos:
            return "photo"
        case .music:
            return "music.note"
        case .movies:
            return "film"
        }
    }

    var rootURL: URL? {
        switch self {
        case .user:
            return FileManager.default.homeDirectoryForCurrentUser
        case .desktop:
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        case .documents:
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        case .applications:
            return FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
        case .downloads:
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case .photos:
            return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        case .music:
            return FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        case .movies:
            return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        }
    }
}

struct SourceLocation: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let symbolName: String
    let rootURL: URL
    var count: Int
    let isCustom: Bool

    init(kind: SourceKind, rootURL: URL, count: Int = 0) {
        self.id = "builtin.\(kind.id)"
        self.title = kind.rawValue
        self.symbolName = kind.symbolName
        self.rootURL = rootURL.standardizedFileURL
        self.count = count
        self.isCustom = false
    }

    init(customURL: URL, count: Int = 0) {
        let standardizedURL = customURL.standardizedFileURL
        let title = standardizedURL.lastPathComponent.isEmpty
            ? DriveFormatters.displayPath(for: standardizedURL)
            : standardizedURL.lastPathComponent

        self.id = "custom.\(standardizedURL.path)"
        self.title = title
        self.symbolName = "folder.badge.gearshape"
        self.rootURL = standardizedURL
        self.count = count
        self.isCustom = true
    }
}

struct SourceBrowserItem: Identifiable, Equatable, Sendable {
    let id: URL
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    var size: Int64?
    let modifiedAt: Date?

    var canEnter: Bool {
        isDirectory && !isPackage
    }

    var symbolName: String {
        if isPackage && url.pathExtension.lowercased() == "photoslibrary" {
            return "photo.stack.fill"
        }
        if isDirectory {
            return "folder.fill"
        }

        switch url.pathExtension.lowercased() {
        case "mov", "mp4", "m4v":
            return "film.fill"
        case "zip", "tar", "gz":
            return "archivebox.fill"
        case "jpg", "jpeg", "png", "heic", "webp":
            return "photo.fill"
        case "pdf":
            return "doc.richtext.fill"
        default:
            return "doc.fill"
        }
    }
}

struct TargetVolume: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let mountURL: URL
    let fileSystem: String
    let totalCapacity: Int64
    let availableCapacity: Int64
    let isWritable: Bool
    let isEjectable: Bool
    let isSample: Bool

    var usedCapacity: Int64 {
        max(totalCapacity - availableCapacity, 0)
    }

    var usageFraction: Double {
        guard totalCapacity > 0 else { return 0 }
        return min(max(Double(usedCapacity) / Double(totalCapacity), 0), 1)
    }
}

enum MigrationMode: String, CaseIterable, Identifiable, Sendable {
    case copy = "复制"
    case move = "移动"
    case mirror = "镜像"

    var id: String { rawValue }
}

enum MigrationItemStatus: String, Equatable, Sendable {
    case preflighting = "预检中"
    case resuming = "续传中"
    case verifying = "正在校验"
    case copying = "正在复制"
    case waiting = "等待"
    case needsAttention = "需确认"
    case completed = "完成"
    case paused = "已暂停"
    case failed = "失败"
}

struct MigrationItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceURL: URL
    let displayName: String
    let sourceSummary: String
    let estimatedSize: Int64
    var status: MigrationItemStatus
    var progress: Double
    var hasConflict: Bool
    var conflictResolved = false
    var isSample = false

    var symbolName: String {
        if sourceURL.hasDirectoryPath {
            return "folder.fill"
        }

        switch sourceURL.pathExtension.lowercased() {
        case "mov", "mp4", "m4v":
            return "film.fill"
        case "zip", "tar", "gz":
            return "archivebox.fill"
        case "photoslibrary":
            return "photo.stack.fill"
        case "jpg", "jpeg", "png", "heic", "webp":
            return "photo.fill"
        case "pdf":
            return "doc.richtext.fill"
        default:
            return "doc.fill"
        }
    }
}

struct MigrationOptions: Equatable, Sendable {
    var verifyAfterCopy = true
    var preserveMetadata = true
    var skipSystemCaches = false
    var ejectWhenFinished = false
}

enum TimelineState: Equatable, Sendable {
    case done
    case current
    case pending
}

struct TimelineStep: Identifiable, Equatable, Sendable {
    let id = UUID()
    let title: String
    let detail: String
    let state: TimelineState
}

enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case migrate = "迁移"
    case history = "历史"
    case settings = "设置"

    var id: String { rawValue }
}
