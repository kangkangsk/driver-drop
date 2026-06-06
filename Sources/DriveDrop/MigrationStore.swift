import AppKit
import Foundation

private struct FileSystemCapacity {
    let total: Int64
    let available: Int64
}

private enum BrowserContext {
    case source
    case volume
}

@MainActor
final class MigrationStore: ObservableObject {
    @Published var selectedSection: AppSection = .migrate
    @Published var sources: [SourceLocation] = []
    @Published var volumes: [TargetVolume] = []
    @Published var selectedVolumeID: TargetVolume.ID?
    @Published var manualTargetFolder: URL?
    @Published var selectedSourceID: SourceLocation.ID?
    @Published var currentSourceURL: URL?
    @Published var sourceBrowserItems: [SourceBrowserItem] = []
    @Published var items: [MigrationItem] = []
    @Published var migrationMode: MigrationMode = .copy
    @Published var options = MigrationOptions()
    @Published var isDropTargeted = false
    @Published var isMigrating = false
    @Published var showConflictSheet = false
    @Published var statusMessage: String?
    @Published var copiedBytes: Int64 = 0
    @Published var currentTotalBytes: Int64 = 0
    @Published var currentItemName: String?
    @Published var completedItemCount = 0
    @Published var failedItemCount = 0
    @Published var lastReportURL: URL?

    private var volumeObservers: [NSObjectProtocol] = []
    private let executor = MigrationExecutor()
    private var migrationTask: Task<Void, Never>?
    private var sourceSizeTask: Task<Void, Never>?
    private var sourceSizeByPath: [String: Int64] = [:]
    private var completedBytesBeforeCurrent: Int64 = 0
    @Published private var browserContext: BrowserContext = .source

    init() {
        clearPersistedLocalPathData()
        sources = Self.defaultSourceLocations()
        refreshVolumes()
        refreshSourceCounts()
        if let firstSource = sources.first {
            selectSource(firstSource)
        }
        startVolumeMonitoring()
    }

    deinit {
        migrationTask?.cancel()
        sourceSizeTask?.cancel()
        for observer in volumeObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    var selectedVolume: TargetVolume? {
        if let selectedVolumeID {
            return volumes.first { $0.id == selectedVolumeID }
        }
        return nil
    }

    var targetFolderURL: URL? {
        if let manualTargetFolder {
            return Self.isExternalWritableURL(manualTargetFolder) ? manualTargetFolder : nil
        }

        guard let selectedVolume, selectedVolume.isWritable else {
            return nil
        }

        return migrationRoot(for: selectedVolume)
    }

    var targetDisplayURL: URL? {
        manualTargetFolder ?? selectedVolume?.mountURL
    }

    var targetLocationDescription: String {
        if let manualTargetFolder {
            return locationDescription(for: manualTargetFolder)
        }
        if let selectedVolume {
            return "移动硬盘/\(selectedVolume.name)"
        }
        return "未连接"
    }

    var targetName: String {
        if let manualTargetFolder {
            return manualTargetFolder.lastPathComponent.isEmpty
                ? targetLocationDescription
                : manualTargetFolder.lastPathComponent
        }
        return selectedVolume?.name ?? "未选择"
    }

    var targetFormatDescription: String {
        if manualTargetFolder != nil {
            return "手动选择"
        }
        return selectedVolume.map { "\($0.fileSystem) · \(DriveFormatters.compactFileSize($0.totalCapacity))" } ?? "未连接"
    }

    var targetAvailableCapacity: Int64? {
        if let manualTargetFolder {
            guard Self.isExternalWritableURL(manualTargetFolder) else { return nil }
            return availableCapacity(for: manualTargetFolder)
        }
        return selectedVolume?.availableCapacity
    }

    var targetTotalCapacity: Int64? {
        if let manualTargetFolder {
            guard Self.isExternalWritableURL(manualTargetFolder) else { return nil }
            return totalCapacity(for: manualTargetFolder)
        }
        return selectedVolume?.totalCapacity
    }

    var targetUsedCapacity: Int64? {
        guard let total = targetTotalCapacity, let available = targetAvailableCapacity else {
            return nil
        }
        return max(total - available, 0)
    }

    var targetUsageFraction: Double {
        guard let total = targetTotalCapacity, let used = targetUsedCapacity, total > 0 else {
            return 0
        }
        return min(max(Double(used) / Double(total), 0), 1)
    }

    var hasWritableTarget: Bool {
        guard let targetFolderURL else { return false }
        guard Self.isExternalWritableURL(targetFolderURL) else { return false }
        let existingPath = FileManager.default.fileExists(atPath: targetFolderURL.path)
            ? targetFolderURL
            : targetFolderURL.deletingLastPathComponent()
        return FileManager.default.isWritableFile(atPath: existingPath.path)
    }

    var selectedSource: SourceLocation? {
        guard let selectedSourceID else { return nil }
        return sources.first { $0.id == selectedSourceID }
    }

    var currentSourceTitle: String {
        if browserContext == .volume {
            return selectedVolume?.name ?? "移动硬盘"
        }
        return selectedSource?.title ?? "位置"
    }

    var currentSourceSymbolName: String {
        if browserContext == .volume {
            return "externaldrive.fill"
        }
        return selectedSource?.symbolName ?? "folder"
    }

    var currentBrowserLocationDescription: String {
        guard let currentSourceURL else {
            return "无法打开当前位置"
        }
        return locationDescription(for: currentSourceURL)
    }

    var isBrowsingVolume: Bool {
        browserContext == .volume
    }

    var canManageBrowserItems: Bool {
        if browserContext == .volume {
            return selectedVolume?.isWritable == true
        }

        return selectedSource?.isCustom == true && currentSourceURL != nil
    }

    var browserManagementDescription: String {
        if browserContext == .volume {
            return "可对移动硬盘内容新建、改名、移动和删除。"
        }
        if selectedSource?.isCustom == true {
            return "自定义位置支持增删改，执行前会确认。"
        }
        return "系统位置仅作为来源读取。"
    }

    var canNavigateSourceUp: Bool {
        guard let currentSourceURL, let root = currentBrowserRootURL else {
            return false
        }
        return currentSourceURL.standardizedFileURL.path != root.standardizedFileURL.path
    }

    var canRefreshFolderSizes: Bool {
        currentSourceURL != nil && sourceBrowserItems.contains(where: \.isDirectory)
    }

    var totalSize: Int64 {
        items.reduce(0) { $0 + $1.estimatedSize }
    }

    var pendingItems: [MigrationItem] {
        items.filter { item in
            !item.isSample && item.status != .completed
        }
    }

    var remainingSize: Int64 {
        pendingItems.reduce(0) { $0 + $1.estimatedSize }
    }

    var estimatedDurationText: String {
        Self.estimatedDurationText(for: remainingSize, verifyAfterCopy: options.verifyAfterCopy)
    }

    var estimatedDurationDetail: String {
        guard remainingSize > 0 else {
            return "队列为空"
        }

        return "\(pendingItems.count) 个项目 · \(DriveFormatters.fileSize(remainingSize))"
    }

    var conflictCount: Int {
        items.filter(\.hasConflict).count
    }

    var verifiedFileCount: Int {
        completedItemCount
    }

    var speedSummary: String {
        if isMigrating {
            let copied = DriveFormatters.compactFileSize(copiedBytes)
            let total = DriveFormatters.compactFileSize(max(currentTotalBytes, totalSize))
            let current = currentItemName.map { " · 当前：\($0)" } ?? ""
            return "正在迁移 \(copied) / \(total)\(current)"
        }

        if let statusMessage {
            return statusMessage
        }

        if let lastReportURL {
            return "迁移完成 · 报告：\(lastReportURL.lastPathComponent)"
        }

        return "等待开始 · 已选择 \(items.count) 个项目"
    }

    var headerSummary: String {
        let total = DriveFormatters.compactFileSize(totalSize)
        let target = targetAvailableCapacity.map { "目标盘剩余 \(DriveFormatters.compactFileSize($0))" } ?? "目标盘未连接"
        return "\(items.count) 个项目 · \(total) · \(target)"
    }

    var timeline: [TimelineStep] {
        let targetDetail: String
        let targetState: TimelineState
        if let available = targetAvailableCapacity {
            targetDetail = "预计写入 \(DriveFormatters.compactFileSize(remainingSize))，可用 \(DriveFormatters.compactFileSize(available))"
            targetState = .done
        } else {
            targetDetail = "等待连接可读写移动硬盘"
            targetState = .pending
        }

        return [
            TimelineStep(title: "队列扫描", detail: "待迁移 \(pendingItems.count) 个项目", state: items.isEmpty ? .pending : .done),
            TimelineStep(title: "空间预检", detail: targetDetail, state: targetState),
            TimelineStep(title: isMigrating ? "复制与校验" : "等待迁移", detail: isMigrating ? (currentItemName ?? "正在执行迁移计划") : "点击开始后执行迁移计划", state: .current),
            TimelineStep(title: "迁移报告", detail: lastReportURL?.lastPathComponent ?? "等待生成", state: lastReportURL == nil ? .pending : .done)
        ]
    }

    func refreshVolumes() {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsReadOnlyKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsInternalKey,
            .volumeLocalizedFormatDescriptionKey
        ]

        let detected = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? [])
            .compactMap { url -> TargetVolume? in
                guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
                guard Self.isExternalVolumeURL(url, values: values) else { return nil }

                let name = values.volumeName ?? url.lastPathComponent
                let capacity = Self.fileSystemCapacity(for: url)
                let total = capacity?.total ?? values.volumeTotalCapacity.map(Int64.init) ?? 0
                let available = capacity?.available ?? values.volumeAvailableCapacity.map(Int64.init) ?? values.volumeAvailableCapacityForImportantUsage ?? 0
                let format = values.volumeLocalizedFormatDescription ?? "未知格式"

                return TargetVolume(
                    id: url.path,
                    name: name,
                    mountURL: url,
                    fileSystem: format,
                    totalCapacity: max(total, 0),
                    availableCapacity: max(available, 0),
                    isWritable: !(values.volumeIsReadOnly ?? false),
                    isEjectable: values.volumeIsEjectable ?? false,
                    isSample: false
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        volumes = detected

        if let selectedVolumeID, volumes.contains(where: { $0.id == selectedVolumeID }) {
            return
        }

        selectedVolumeID = volumes.first?.id
        if browserContext == .volume {
            if let selectedVolume {
                loadSourceBrowser(at: selectedVolume.mountURL)
            } else {
                currentSourceURL = nil
                sourceBrowserItems = []
                statusMessage = "未连接可读写移动硬盘。"
            }
        }
    }

    func addDroppedURLs(_ urls: [URL]) {
        let newItems = urls.map { url in
            MigrationItem(
                id: UUID(),
                sourceURL: url,
                displayName: url.lastPathComponent.isEmpty ? locationDescription(for: url) : url.lastPathComponent,
                sourceSummary: locationDescription(for: url.deletingLastPathComponent()),
                estimatedSize: estimateSize(for: url),
                status: .waiting,
                progress: 0,
                hasConflict: false
            )
        }

        guard !newItems.isEmpty else { return }
        items.append(contentsOf: newItems)
        refreshSourceCounts()
        statusMessage = "已加入 \(newItems.count) 个项目，点击开始迁移前会先做空间和同名文件预检。"
    }

    func selectSource(_ source: SourceLocation) {
        browserContext = .source
        selectedSourceID = source.id
        loadSourceBrowser(at: source.rootURL)
    }

    func selectVolume(_ volume: TargetVolume) {
        browserContext = .volume
        selectedVolumeID = volume.id
        manualTargetFolder = nil
        loadSourceBrowser(at: volume.mountURL)
    }

    func refreshSourceBrowser() {
        if let currentSourceURL {
            loadSourceBrowser(at: currentSourceURL)
        } else if let selectedSource {
            selectSource(selectedSource)
        }
        refreshSourceCounts()
    }

    func openBrowserItem(_ item: SourceBrowserItem) {
        guard item.canEnter else {
            addBrowserItemToQueue(item)
            return
        }
        loadSourceBrowser(at: item.url)
    }

    func navigateSourceUp() {
        guard canNavigateSourceUp, let currentSourceURL else { return }
        loadSourceBrowser(at: currentSourceURL.deletingLastPathComponent())
    }

    func addBrowserItemToQueue(_ item: SourceBrowserItem) {
        addDroppedURLs([item.url])
    }

    func addCurrentSourceFolderToQueue() {
        guard let currentSourceURL else { return }
        addDroppedURLs([currentSourceURL])
    }

    func createFolderInBrowser() {
        guard canManageBrowserItems, let currentSourceURL else {
            statusMessage = "当前位置不可写。"
            return
        }

        guard let name = promptForName(
            title: "新建文件夹",
            message: "在 \(locationDescription(for: currentSourceURL)) 中创建新文件夹。",
            defaultValue: "新建文件夹",
            confirmTitle: "创建"
        ) else {
            return
        }

        let destination = uniqueDestinationURL(for: currentSourceURL.appendingPathComponent(name, isDirectory: true))
        guard confirmBrowserOperation(title: "确认新建文件夹", message: "将在当前位置创建：\(destination.lastPathComponent)", confirmTitle: "创建") else {
            return
        }

        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            refreshSourceBrowser()
            statusMessage = "已创建文件夹：\(destination.lastPathComponent)。"
        } catch {
            statusMessage = "创建失败：\(error.localizedDescription)"
        }
    }

    func chooseFilesToCopyIntoBrowser() {
        guard canManageBrowserItems, let currentSourceURL else {
            statusMessage = "当前位置不可写。"
            return
        }

        let panel = NSOpenPanel()
        panel.title = "添加到当前位置"
        panel.prompt = "添加"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        let message = panel.urls.count == 1
            ? "将“\(panel.urls[0].lastPathComponent)”复制到：\(locationDescription(for: currentSourceURL))"
            : "将 \(panel.urls.count) 个项目复制到：\(locationDescription(for: currentSourceURL))"
        guard confirmBrowserOperation(title: "确认添加文件", message: message, confirmTitle: "添加") else {
            return
        }

        var copied = 0
        var failed = 0
        for sourceURL in panel.urls {
            do {
                let destination = uniqueDestinationURL(for: currentSourceURL.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: sourceURL.hasDirectoryPath))
                try FileManager.default.copyItem(at: sourceURL, to: destination)
                copied += 1
            } catch {
                failed += 1
            }
        }

        refreshSourceBrowser()
        statusMessage = failed == 0 ? "已添加 \(copied) 个项目。" : "已添加 \(copied) 个项目，失败 \(failed) 个。"
    }

    func renameBrowserItem(_ item: SourceBrowserItem) {
        guard canManageBrowserItems, itemIsInsideCurrentBrowserRoot(item.url) else {
            statusMessage = "当前位置不可改名。"
            return
        }

        guard let newName = promptForName(
            title: "重命名",
            message: "输入“\(item.name)”的新名称。",
            defaultValue: item.name,
            confirmTitle: "继续"
        ) else {
            return
        }

        let destination = item.url.deletingLastPathComponent().appendingPathComponent(newName, isDirectory: item.isDirectory)
        guard destination.path != item.url.path else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            statusMessage = "重命名失败：同名项目已存在。"
            return
        }

        guard confirmBrowserOperation(title: "确认重命名", message: "将“\(item.name)”重命名为“\(newName)”？", confirmTitle: "重命名") else {
            return
        }

        do {
            try FileManager.default.moveItem(at: item.url, to: destination)
            refreshSourceBrowser()
            statusMessage = "已重命名为：\(newName)。"
        } catch {
            statusMessage = "重命名失败：\(error.localizedDescription)"
        }
    }

    func chooseMoveDestination(for item: SourceBrowserItem) {
        guard canManageBrowserItems, itemIsInsideCurrentBrowserRoot(item.url), let root = currentBrowserRootURL else {
            statusMessage = "当前位置不可移动。"
            return
        }

        let panel = NSOpenPanel()
        panel.title = "选择移动目标"
        panel.prompt = "移动到这里"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = currentSourceURL ?? root

        guard panel.runModal() == .OK, let destinationFolder = panel.url?.standardizedFileURL else { return }
        guard itemIsInsideCurrentBrowserRoot(destinationFolder) else {
            statusMessage = "移动目标必须在当前可管理位置内。"
            return
        }

        let destination = uniqueDestinationURL(for: destinationFolder.appendingPathComponent(item.name, isDirectory: item.isDirectory))
        guard destination.deletingLastPathComponent().path != item.url.deletingLastPathComponent().path else {
            statusMessage = "已在该文件夹内，无需移动。"
            return
        }

        guard confirmBrowserOperation(
            title: "确认移动",
            message: "将“\(item.name)”移动到：\(locationDescription(for: destinationFolder))",
            confirmTitle: "移动"
        ) else {
            return
        }

        do {
            try FileManager.default.moveItem(at: item.url, to: destination)
            refreshSourceBrowser()
            statusMessage = "已移动：\(item.name)。"
        } catch {
            statusMessage = "移动失败：\(error.localizedDescription)"
        }
    }

    func deleteBrowserItem(_ item: SourceBrowserItem) {
        guard canManageBrowserItems, itemIsInsideCurrentBrowserRoot(item.url) else {
            statusMessage = "当前位置不可删除。"
            return
        }

        guard confirmBrowserOperation(
            title: "确认删除",
            message: "将永久删除“\(item.name)”。此操作不可撤销。",
            confirmTitle: "删除",
            style: .critical
        ) else {
            return
        }

        do {
            try FileManager.default.removeItem(at: item.url)
            refreshSourceBrowser()
            statusMessage = "已删除：\(item.name)。"
        } catch {
            statusMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    func chooseSourceLocation() {
        let panel = NSOpenPanel()
        panel.title = "添加浏览位置"
        panel.prompt = "添加位置"
        panel.message = "选择一个文件夹加入左侧位置列表，之后可以直接浏览并加入迁移队列。"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK else { return }
        addSourceLocations(panel.urls)
    }

    func removeSourceLocation(_ source: SourceLocation) {
        guard source.isCustom else { return }
        guard confirmBrowserOperation(title: "移除位置", message: "从左侧列表移除“\(source.title)”。不会删除磁盘上的文件。", confirmTitle: "移除") else {
            return
        }

        let wasSelected = source.id == selectedSourceID
        sources.removeAll { $0.id == source.id }

        if wasSelected {
            if let firstSource = sources.first {
                selectSource(firstSource)
            } else {
                selectedSourceID = nil
                currentSourceURL = nil
                sourceBrowserItems = []
            }
        }

        statusMessage = "已移除位置：\(source.title)。"
    }

    private func addSourceLocations(_ urls: [URL]) {
        var added: [SourceLocation] = []
        var existingPaths = Set(sources.map { $0.rootURL.standardizedFileURL.path })

        for url in urls {
            let standardizedURL = url.standardizedFileURL
            let path = standardizedURL.path
            guard !existingPaths.contains(path) else { continue }

            let location = SourceLocation(customURL: standardizedURL)
            sources.append(location)
            existingPaths.insert(path)
            added.append(location)
        }

        guard !added.isEmpty else {
            statusMessage = "所选文件夹已经在位置列表中。"
            return
        }

        refreshSourceCounts()
        selectSource(added[0])
        statusMessage = added.count == 1 ? "已添加位置：\(added[0].title)。" : "已添加 \(added.count) 个位置。"
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "选择要迁移的文件或文件夹"
        panel.prompt = "加入队列"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK else { return }
        addDroppedURLs(panel.urls)
    }

    func chooseTargetFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择移动硬盘或目标文件夹"
        panel.prompt = "设为目标"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = selectedVolume?.mountURL

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard Self.isExternalWritableURL(url) else {
            manualTargetFolder = nil
            selectedVolumeID = volumes.first?.id
            statusMessage = "系统硬盘只允许读取，目标只能选择可读写移动硬盘。"
            return
        }
        manualTargetFolder = url
        statusMessage = "目标已设置为：\(locationDescription(for: url))"
    }

    func clearQueue() {
        guard !isMigrating else { return }
        items.removeAll()
        completedItemCount = 0
        failedItemCount = 0
        copiedBytes = 0
        currentTotalBytes = 0
        currentItemName = nil
        lastReportURL = nil
        statusMessage = "队列已清空。"
    }

    private func loadSourceBrowser(at url: URL) {
        sourceSizeTask?.cancel()
        currentSourceURL = url

        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isPackageKey,
                    .fileSizeKey,
                    .totalFileAllocatedSizeKey,
                    .contentModificationDateKey,
                    .isHiddenKey
                ],
                options: [.skipsHiddenFiles]
            )

            sourceBrowserItems = urls
                .compactMap { sourceBrowserItem(for: $0) }
                .sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory {
                        return lhs.isDirectory
                    }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            if browserContext == .source, let selectedSourceID {
                updateSourceCount(id: selectedSourceID, count: sourceBrowserItems.count)
            }
            rememberKnownSizes(from: sourceBrowserItems)
            statusMessage = "\(currentSourceTitle) 已载入 \(sourceBrowserItems.count) 个项目。"
            scheduleDirectorySizeCalculation(for: sourceBrowserItems, browserURL: url)
        } catch {
            sourceBrowserItems = []
            statusMessage = "无法读取 \(locationDescription(for: url))：\(error.localizedDescription)"
        }
    }

    private func sourceBrowserItem(for url: URL) -> SourceBrowserItem? {
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isPackageKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey
        ]) else {
            return nil
        }

        let isDirectory = values.isDirectory == true
        let isPackage = values.isPackage == true

        return SourceBrowserItem(
            id: url,
            url: url,
            name: url.lastPathComponent,
            isDirectory: isDirectory,
            isPackage: isPackage,
            size: isDirectory ? cachedSize(for: url) : Int64(values.fileSize ?? values.totalFileAllocatedSize ?? 0),
            modifiedAt: values.contentModificationDate
        )
    }

    func refreshVisibleFolderSizes() {
        guard let currentSourceURL else { return }
        scheduleDirectorySizeCalculation(for: sourceBrowserItems, browserURL: currentSourceURL, force: true)
    }

    private func scheduleDirectorySizeCalculation(for items: [SourceBrowserItem], browserURL: URL, force: Bool = false) {
        sourceSizeTask?.cancel()
        let directories = items
            .filter(\.isDirectory)
            .map(\.url)

        guard !directories.isEmpty else {
            sourceSizeTask = nil
            return
        }

        if force {
            markDirectorySizesAsCalculating(directories, browserURL: browserURL)
            statusMessage = "正在刷新当前列表的文件夹大小。"
        }

        sourceSizeTask = Task.detached(priority: .utility) { [directories, browserURL, force] in
            for directory in directories {
                if Task.isCancelled {
                    return
                }

                let size = Self.directoryLogicalSize(for: directory)
                await MainActor.run { [weak self] in
                    self?.applyDirectorySize(size, for: directory, browserURL: browserURL)
                }
            }

            if force {
                await MainActor.run { [weak self] in
                    self?.finishForcedDirectorySizeRefresh(browserURL: browserURL, refreshedCount: directories.count)
                }
            }
        }
    }

    private func applyDirectorySize(_ size: Int64, for directory: URL, browserURL: URL) {
        rememberSize(size, for: directory)

        guard currentSourceURL?.standardizedFileURL.path == browserURL.standardizedFileURL.path,
              let index = sourceBrowserItems.firstIndex(where: { $0.url.standardizedFileURL.path == directory.standardizedFileURL.path })
        else {
            return
        }

        sourceBrowserItems[index].size = size
    }

    private func markDirectorySizesAsCalculating(_ directories: [URL], browserURL: URL) {
        guard currentSourceURL?.standardizedFileURL.path == browserURL.standardizedFileURL.path else {
            return
        }

        let paths = Set(directories.map { Self.sourceSizeCachePath(for: $0) })
        for index in sourceBrowserItems.indices where paths.contains(Self.sourceSizeCachePath(for: sourceBrowserItems[index].url)) {
            sourceBrowserItems[index].size = nil
        }
    }

    private func finishForcedDirectorySizeRefresh(browserURL: URL, refreshedCount: Int) {
        guard currentSourceURL?.standardizedFileURL.path == browserURL.standardizedFileURL.path else {
            return
        }

        statusMessage = "已刷新 \(refreshedCount) 个文件夹大小。"
    }

    private func cachedSize(for url: URL) -> Int64? {
        sourceSizeByPath[Self.sourceSizeCachePath(for: url)]
    }

    private func rememberKnownSizes(from items: [SourceBrowserItem]) {
        for item in items {
            guard let size = item.size else { continue }
            let path = Self.sourceSizeCachePath(for: item.url)
            if sourceSizeByPath[path] != size {
                sourceSizeByPath[path] = size
            }
        }
    }

    private func rememberSize(_ size: Int64, for url: URL) {
        let path = Self.sourceSizeCachePath(for: url)
        guard sourceSizeByPath[path] != size else { return }
        sourceSizeByPath[path] = size
    }

    private func clearPersistedLocalPathData() {
        sourceSizeByPath.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.customSourcePathsKey)
        UserDefaults.standard.removeObject(forKey: Self.sourceSizeCacheKey)
    }

    private static func sourceSizeCachePath(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private nonisolated static func directoryLogicalSize(for url: URL) -> Int64 {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: nil
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if Task.isCancelled {
                return total
            }

            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isDirectory != true,
                  values.isSymbolicLink != true
            else {
                continue
            }

            total += Int64(values.fileSize ?? values.totalFileAllocatedSize ?? 0)
        }

        return total
    }

    private func refreshSourceCounts() {
        for source in sources {
            guard FileManager.default.fileExists(atPath: source.rootURL.path),
                  let contents = try? FileManager.default.contentsOfDirectory(at: source.rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            else {
                updateSourceCount(id: source.id, count: 0)
                continue
            }
            updateSourceCount(id: source.id, count: contents.count)
        }
    }

    private func updateSourceCount(id: SourceLocation.ID, count: Int) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].count = count
    }

    private var currentBrowserRootURL: URL? {
        switch browserContext {
        case .source:
            return selectedSource?.rootURL
        case .volume:
            return selectedVolume?.mountURL
        }
    }

    private func locationDescription(for url: URL) -> String {
        let standardizedURL = url.standardizedFileURL

        let sourceMatches = sources
            .sorted { $0.rootURL.standardizedFileURL.path.count > $1.rootURL.standardizedFileURL.path.count }
        for source in sourceMatches {
            if let description = relativeLocationDescription(
                for: standardizedURL,
                rootURL: source.rootURL,
                rootTitle: source.title
            ) {
                return description
            }
        }

        let volumeMatches = volumes
            .sorted { $0.mountURL.standardizedFileURL.path.count > $1.mountURL.standardizedFileURL.path.count }
        for volume in volumeMatches {
            if let description = relativeLocationDescription(
                for: standardizedURL,
                rootURL: volume.mountURL,
                rootTitle: "移动硬盘/\(volume.name)"
            ) {
                return description
            }
        }

        return DriveFormatters.displayPath(for: standardizedURL)
    }

    private func relativeLocationDescription(for url: URL, rootURL: URL, rootTitle: String) -> String? {
        let rootPath = rootURL.standardizedFileURL.path
        let urlPath = url.standardizedFileURL.path

        guard urlPath == rootPath || urlPath.hasPrefix(rootPath + "/") else {
            return nil
        }

        guard urlPath != rootPath else {
            return rootTitle
        }

        let relativePath = String(urlPath.dropFirst(rootPath.count + 1))
        return relativePath.isEmpty ? rootTitle : "\(rootTitle)/\(relativePath)"
    }

    private func itemIsInsideCurrentBrowserRoot(_ url: URL) -> Bool {
        guard let root = currentBrowserRootURL?.standardizedFileURL else { return false }
        let rootPath = root.path
        let urlPath = url.standardizedFileURL.path
        return urlPath == rootPath || urlPath.hasPrefix(rootPath + "/")
    }

    private func promptForName(title: String, message: String, defaultValue: String, confirmTitle: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "取消")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("/") else {
            statusMessage = "名称不能为空，也不能包含 /。"
            return nil
        }

        return value
    }

    private func confirmBrowserOperation(title: String, message: String, confirmTitle: String, style: NSAlert.Style = .warning) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func uniqueDestinationURL(for proposedURL: URL) -> URL {
        guard FileManager.default.fileExists(atPath: proposedURL.path) else {
            return proposedURL
        }

        let directory = proposedURL.deletingLastPathComponent()
        let baseName = proposedURL.deletingPathExtension().lastPathComponent
        let pathExtension = proposedURL.pathExtension
        var index = 2

        while true {
            let fileName = pathExtension.isEmpty ? "\(baseName) \(index)" : "\(baseName) \(index).\(pathExtension)"
            let candidate = directory.appendingPathComponent(fileName, isDirectory: proposedURL.hasDirectoryPath)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    func startMigration() {
        if isMigrating {
            pauseMigration()
            return
        }

        statusMessage = nil
        lastReportURL = nil

        guard let destinationRoot = targetFolderURL else {
            statusMessage = "请先连接移动硬盘，或点击“选择目标”指定迁移目录。"
            return
        }

        guard hasWritableTarget else {
            statusMessage = "目标只能写入可读写移动硬盘，请连接移动硬盘或重新选择目标。"
            return
        }

        let candidateIndices = items.indices.filter { index in
            let item = items[index]
            return !item.isSample && item.status != .completed && fileExists(item.sourceURL)
        }

        guard !candidateIndices.isEmpty else {
            statusMessage = "没有可迁移的文件，请拖入文件，或点击“添加文件”。"
            return
        }

        if migrationMode == .move {
            let systemSource = candidateIndices
                .map { items[$0] }
                .first { !Self.isExternalWritableURL($0.sourceURL) }

            if let systemSource {
                statusMessage = "系统硬盘只允许读取，不能移动并删除源文件：\(systemSource.displayName)。请使用“复制”。"
                return
            }
        }

        let resumableBytesByIndex = Dictionary(
            uniqueKeysWithValues: candidateIndices.map { index in
                (index, executor.resumableBytes(for: items[index], destinationRoot: destinationRoot))
            }
        )
        let resumableBytes = resumableBytesByIndex.values.reduce(0, +)
        let requestedBytes = candidateIndices.reduce(Int64(0)) { total, index in
            let remainingBytes = max(items[index].estimatedSize - (resumableBytesByIndex[index] ?? 0), 0)
            return total + remainingBytes
        }
        if let available = targetAvailableCapacity, requestedBytes > available {
            statusMessage = "目标盘空间不足：需要 \(DriveFormatters.compactFileSize(requestedBytes))，可用 \(DriveFormatters.compactFileSize(available))。"
            return
        }

        let conflicts = preflightConflicts(indices: candidateIndices, destinationRoot: destinationRoot)
        if !conflicts.isEmpty {
            statusMessage = "发现 \(conflicts.count) 个同名文件，请先确认处理方式。"
            showConflictSheet = true
            return
        }

        let runItems = candidateIndices.map { items[$0] }
        isMigrating = true
        copiedBytes = 0
        currentTotalBytes = max(requestedBytes, 1)
        currentItemName = nil
        completedItemCount = 0
        failedItemCount = 0
        completedBytesBeforeCurrent = 0
        if resumableBytes > 0 {
            statusMessage = "检测到断点数据，将复用 \(DriveFormatters.compactFileSize(resumableBytes)) 后继续迁移。"
        }

        migrationTask = Task {
            await runMigration(items: runItems, destinationRoot: destinationRoot, ejectURL: manualTargetFolder == nil ? selectedVolume?.mountURL : nil)
        }
    }

    func pauseMigration() {
        migrationTask?.cancel()
        migrationTask = nil
        isMigrating = false
        for index in items.indices where items[index].status == .copying || items[index].status == .verifying {
            items[index].status = .paused
        }
        statusMessage = "迁移已暂停，未完成项目可再次点击开始继续。"
        currentItemName = nil
    }

    func resolveConflicts() {
        for index in items.indices where items[index].hasConflict {
            items[index].hasConflict = false
            items[index].conflictResolved = true
            items[index].status = .waiting
        }
        statusMessage = "同名文件将自动保留两份，新副本会追加序号。"
        showConflictSheet = false
    }

    private func runMigration(items runItems: [MigrationItem], destinationRoot: URL, ejectURL: URL?) async {
        var results: [MigrationExecutionResult] = []
        var failures: [(String, String)] = []

        for item in runItems {
            if Task.isCancelled {
                break
            }

            currentItemName = item.displayName
            let hasResumeData = executor.resumableBytes(for: item, destinationRoot: destinationRoot) > 0
            updateItem(item.id, status: hasResumeData ? .resuming : .copying, progress: hasResumeData ? currentProgress(for: item.id) : 0)

            do {
                let result = try await executor.migrate(
                    item: item,
                    destinationRoot: destinationRoot,
                    mode: migrationMode,
                    options: options
                ) { [weak self] progress in
                    await self?.apply(progress)
                }

                results.append(result)
                completedItemCount += 1
                completedBytesBeforeCurrent = copiedBytes
                updateItem(item.id, status: .completed, progress: 1)
            } catch is CancellationError {
                updateItem(item.id, status: .paused, progress: currentProgress(for: item.id))
                break
            } catch {
                failedItemCount += 1
                failures.append((item.displayName, error.localizedDescription))
                updateItem(item.id, status: .failed, progress: currentProgress(for: item.id))
            }
        }

        isMigrating = false
        currentItemName = nil
        migrationTask = nil

        if !results.isEmpty || !failures.isEmpty {
            do {
                lastReportURL = try executor.writeReport(results: results, failures: failures, to: destinationRoot)
                statusMessage = "迁移结束：成功 \(results.count) 个，失败 \(failures.count) 个。"
            } catch {
                statusMessage = "迁移结束，但报告写入失败：\(error.localizedDescription)"
            }

            if options.ejectWhenFinished, failures.isEmpty, let ejectURL {
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: ejectURL)
                    statusMessage = "迁移完成，目标硬盘已弹出。"
                } catch {
                    statusMessage = "迁移完成，但弹出硬盘失败：\(error.localizedDescription)"
                }
            }
        } else if Task.isCancelled {
            statusMessage = "迁移已暂停。"
        }

        refreshVolumes()
    }

    private func apply(_ progress: MigrationProgress) {
        copiedBytes = max(copiedBytes, completedBytesBeforeCurrent + progress.copiedBytes)
        currentTotalBytes = max(currentTotalBytes, progress.totalBytes)
        updateItem(progress.itemID, status: .copying, progress: progress.fraction)
    }

    private func updateItem(_ id: UUID, status: MigrationItemStatus, progress: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = status
        items[index].progress = min(max(progress, 0), 1)
    }

    private func currentProgress(for id: UUID) -> Double {
        items.first(where: { $0.id == id })?.progress ?? 0
    }

    private func preflightConflicts(indices: [Array<MigrationItem>.Index], destinationRoot: URL) -> [MigrationItem] {
        var conflicts: [MigrationItem] = []

        for index in indices {
            let item = items[index]
            guard !item.conflictResolved else { continue }

            let destination = destinationRoot.appendingPathComponent(item.displayName, isDirectory: item.sourceURL.hasDirectoryPath)
            if FileManager.default.fileExists(atPath: destination.path) {
                items[index].hasConflict = true
                items[index].status = .needsAttention
                conflicts.append(items[index])
            }
        }

        return conflicts
    }

    private func migrationRoot(for volume: TargetVolume) -> URL {
        volume.mountURL.appendingPathComponent("DriveDrop Migration", isDirectory: true)
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func availableCapacity(for url: URL) -> Int64? {
        if let capacity = Self.fileSystemCapacity(for: url) {
            return capacity.available
        }

        let capacityURL = existingCapacityURL(for: url)
        let values = try? capacityURL.resourceValues(forKeys: [
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ])
        return values?.volumeAvailableCapacity.map(Int64.init) ?? values?.volumeAvailableCapacityForImportantUsage
    }

    private func totalCapacity(for url: URL) -> Int64? {
        if let capacity = Self.fileSystemCapacity(for: url) {
            return capacity.total
        }

        let capacityURL = existingCapacityURL(for: url)
        let values = try? capacityURL.resourceValues(forKeys: [.volumeTotalCapacityKey])
        return values?.volumeTotalCapacity.map(Int64.init)
    }

    private func existingCapacityURL(for url: URL) -> URL {
        FileManager.default.fileExists(atPath: url.path)
            ? url
            : url.deletingLastPathComponent()
    }

    private static func fileSystemCapacity(for url: URL) -> FileSystemCapacity? {
        let capacityURL = FileManager.default.fileExists(atPath: url.path)
            ? url
            : url.deletingLastPathComponent()

        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: capacityURL.path) else {
            return nil
        }

        let total = int64Value(attributes[.systemSize])
        let available = int64Value(attributes[.systemFreeSize])

        guard let total, let available else {
            return nil
        }

        return FileSystemCapacity(total: max(total, 0), available: max(available, 0))
    }

    private static func isExternalWritableURL(_ url: URL) -> Bool {
        guard let volumeURL = mountedVolumeRoot(for: url),
              let values = try? volumeURL.resourceValues(forKeys: [
                .volumeIsReadOnlyKey,
                .volumeIsRemovableKey,
                .volumeIsEjectableKey,
                .volumeIsInternalKey
              ])
        else {
            return false
        }

        return isExternalVolumeURL(volumeURL, values: values) && !(values.volumeIsReadOnly ?? true)
    }

    private static func isExternalVolumeURL(_ url: URL, values: URLResourceValues) -> Bool {
        return (values.volumeIsRemovable ?? false)
            || (values.volumeIsEjectable ?? false)
            || !(values.volumeIsInternal ?? true)
    }

    private static func mountedVolumeRoot(for url: URL) -> URL? {
        let targetPath = url.standardizedFileURL.path
        let volumes = FileManager.default
            .mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []

        return volumes
            .map(\.standardizedFileURL)
            .filter { volume in
                let volumePath = volume.path
                return targetPath == volumePath || targetPath.hasPrefix(volumePath + "/")
            }
            .sorted { $0.path.count > $1.path.count }
            .first
    }

    private static func estimatedDurationText(for bytes: Int64, verifyAfterCopy: Bool) -> String {
        guard bytes > 0 else {
            return "0 分钟"
        }

        let bytesPerSecond = 85.0 * 1024.0 * 1024.0
        let verifyFactor = verifyAfterCopy ? 1.25 : 1.0
        let seconds = Int(ceil(Double(bytes) / bytesPerSecond * verifyFactor))

        if seconds < 60 {
            return "< 1 分钟"
        }

        let minutes = Int(ceil(Double(seconds) / 60.0))
        if minutes < 60 {
            return "\(minutes) 分钟"
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(remainingMinutes) 分钟"
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber:
            return number.int64Value
        case let value as Int64:
            return value
        case let value as Int:
            return Int64(value)
        case let value as UInt64:
            return value > UInt64(Int64.max) ? Int64.max : Int64(value)
        default:
            return nil
        }
    }

    private func startVolumeMonitoring() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ]

        volumeObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshVolumes()
                }
            }
        }
    }

    private func estimateSize(for url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }

        if values.isDirectory == true {
            return estimateDirectorySize(for: url)
        }

        return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
    }

    private func estimateDirectorySize(for url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else {
            return 0
        }

        var total: Int64 = 0
        var scanned = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            scanned += 1
            if scanned >= 5000 {
                break
            }
        }

        return max(total, 1_048_576)
    }
}

extension MigrationStore {
    private static let customSourcePathsKey = "DriveDropCustomSourcePaths"
    private static let sourceSizeCacheKey = "DriveDropSourceSizeByPath"

    private static func defaultSourceLocations() -> [SourceLocation] {
        SourceKind.allCases.compactMap { kind in
            kind.rootURL.map {
                SourceLocation(kind: kind, rootURL: $0)
            }
        }
    }
}
