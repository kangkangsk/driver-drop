import SwiftUI
import UniformTypeIdentifiers

struct MainWindowView: View {
    @EnvironmentObject private var store: MigrationStore

    var body: some View {
        HStack(spacing: 0) {
            SourceSidebarView()
                .frame(width: 230)

            Divider()

            MigrationQueueView()
                .frame(minWidth: 520)

            Divider()

            TargetInspectorView()
                .frame(width: 320)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.chooseFiles()
                } label: {
                    Label("添加文件", systemImage: "plus")
                }
                .help("添加要迁移的文件或文件夹")

                Button {
                    store.refreshVolumes()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新磁盘")
            }
        }
        .sheet(isPresented: $store.showConflictSheet) {
            ConflictResolutionSheet()
                .environmentObject(store)
        }
    }
}

struct SourceSidebarView: View {
    @EnvironmentObject private var store: MigrationStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SidebarSectionHeader(title: "位置") {
                    Button {
                        store.chooseSourceLocation()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("添加浏览位置")
                }

                VStack(spacing: 4) {
                    ForEach(store.sources) { source in
                        SourceLocationRow(
                            source: source,
                            isActive: source.id == store.selectedSourceID
                        ) {
                            store.selectSource(source)
                        } removeAction: {
                            store.removeSourceLocation(source)
                        }
                    }
                }

                SidebarSectionLabel("移动硬盘")

                VStack(spacing: 8) {
                    ForEach(store.volumes) { volume in
                        TargetVolumeRow(
                            volume: volume,
                            isSelected: store.isBrowsingVolume && store.selectedVolumeID == volume.id
                        ) {
                            store.selectVolume(volume)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(.bar)
    }
}

struct SidebarSectionHeader<Accessory: View>: View {
    let title: String
    let accessory: Accessory

    init(title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            accessory
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }
}

struct SidebarSectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 6)
    }
}

struct SourceLocationRow: View {
    let source: SourceLocation
    let isActive: Bool
    let action: () -> Void
    let removeAction: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 9) {
                SidebarSymbol(name: source.symbolName)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.title)
                        .font(.subheadline)
                        .lineLimit(1)
                    if source.isCustom {
                        Text("自定义位置")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                BadgeText("\(source.count)")
            }
            .frame(maxWidth: .infinity, minHeight: source.isCustom ? 42 : 34, alignment: .leading)

            if source.isCustom {
                Button(action: removeAction) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.7))
                        .frame(width: 20, height: 28)
                }
                .buttonStyle(.plain)
                .help("移除此位置")
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: source.isCustom ? 46 : 34, alignment: .leading)
        .background(isActive ? Color.accentColor.opacity(0.16) : Color.clear)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onTapGesture(perform: action)
    }
}

struct StrategySidebarRow: View {
    let symbolName: String
    let title: String
    let value: String?

    var body: some View {
        HStack(spacing: 9) {
            SidebarSymbol(name: symbolName)
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 6)
            if let value {
                BadgeText(value)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
    }
}

struct SidebarSymbol: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.blue)
            .frame(width: 22, height: 22)
            .background(Color.white.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct BadgeText: View {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var body: some View {
        Text(value)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .frame(minHeight: 18)
            .background(Color.secondary.opacity(0.12))
            .clipShape(Capsule())
    }
}

struct TargetVolumeRow: View {
    let volume: TargetVolume
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    DiskSymbol(isWritable: volume.isWritable)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(volume.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Text("\(volume.fileSystem) · \(DriveFormatters.compactFileSize(volume.totalCapacity))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                CapacityMeter(fraction: volume.usageFraction, tint: volume.usageFraction > 0.8 ? .orange : .green)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.white.opacity(0.88) : Color.white.opacity(0.54))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.plain)
    }
}

struct DiskSymbol: View {
    let isWritable: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 22, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.accentColor, Color(nsColor: .controlBackgroundColor))
                .frame(width: 32, height: 30)

            Circle()
                .fill(isWritable ? Color.green : Color.red)
                .frame(width: 6, height: 6)
                .padding(4)
        }
        .frame(width: 32, height: 28)
    }
}

struct MigrationQueueView: View {
    @EnvironmentObject private var store: MigrationStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("迁移队列")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text(store.headerSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    store.chooseFiles()
                } label: {
                    Label("添加文件", systemImage: "plus")
                }
                .controlSize(.large)

                if !store.items.isEmpty {
                    Button("清空队列") {
                        store.clearQueue()
                    }
                    .controlSize(.large)
                    .disabled(store.isMigrating)
                }

                Button {
                    store.startMigration()
                } label: {
                    Label(store.isMigrating ? "暂停迁移" : "开始迁移", systemImage: store.isMigrating ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.items.isEmpty || store.targetFolderURL == nil)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 14) {
                    SourceBrowserPanelView()
                    DropZoneView()
                    QueuePanelView()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            HStack {
                Text(store.speedSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                Button("冲突 \(store.conflictCount)") {
                    store.showConflictSheet = true
                }
                .disabled(store.conflictCount == 0)

                Button(store.isMigrating ? "暂停" : "暂停") {
                    store.pauseMigration()
                }
                .disabled(!store.isMigrating)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

struct DropZoneView: View {
    @EnvironmentObject private var store: MigrationStore

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "arrow.right.doc.on.clipboard")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(store.isDropTargeted ? .green : .blue)
                .frame(width: 88, height: 88)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: Color.blue.opacity(0.12), radius: 12, y: 6)

            VStack(alignment: .leading, spacing: 6) {
                Text("放入迁移队列")
                    .font(.headline)
                    .fontWeight(.bold)
                Text("桌面、Finder、照片导出文件夹都可以进入队列，目标路径会按来源自动归档。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    store.chooseFiles()
                } label: {
                    Label("选择文件或文件夹", systemImage: "folder.badge.plus")
                }
                .padding(.top, 6)
            }

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 6) {
                Text("预计用时")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(store.estimatedDurationText)
                    .font(.title3)
                    .fontWeight(.bold)
                Text(store.estimatedDurationDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(width: 148, alignment: .leading)
            .background(Color.white.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(22)
        .frame(minHeight: 196)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(store.isDropTargeted ? Color.green.opacity(0.09) : Color.blue.opacity(0.07))
                .background(Color.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    store.isDropTargeted ? Color.green.opacity(0.78) : Color.accentColor.opacity(0.46),
                    style: StrokeStyle(lineWidth: 1, dash: [6, 4])
                )
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $store.isDropTargeted, perform: handleDrop)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let lock = NSLock()
        let group = DispatchGroup()

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }

                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let itemURL = item as? URL {
                    url = itemURL
                } else if let itemURL = item as? NSURL {
                    url = itemURL as URL
                } else if let string = item as? String {
                    url = URL(string: string)
                } else {
                    url = nil
                }

                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            store.addDroppedURLs(urls)
        }

        return true
    }
}

struct SourceBrowserPanelView: View {
    @EnvironmentObject private var store: MigrationStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: store.currentSourceSymbolName)
                    .foregroundStyle(.blue)
                    .frame(width: 28, height: 28)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(store.currentSourceTitle)
                        .font(.headline)
                        .fontWeight(.bold)
                    Text(store.currentBrowserLocationDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(store.browserManagementDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    store.navigateSourceUp()
                } label: {
                    Label("上一级", systemImage: "arrow.uturn.left")
                }
                .disabled(!store.canNavigateSourceUp)

                Button {
                    store.refreshSourceBrowser()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }

                if store.canManageBrowserItems {
                    Button {
                        store.createFolderInBrowser()
                    } label: {
                        Label("新建文件夹", systemImage: "folder.badge.plus")
                    }

                    Button {
                        store.chooseFilesToCopyIntoBrowser()
                    } label: {
                        Label("添加到此处", systemImage: "square.and.arrow.down")
                    }
                } else {
                    Button {
                        store.addCurrentSourceFolderToQueue()
                    } label: {
                        Label("加入当前文件夹", systemImage: "plus")
                    }
                }
            }
            .padding(14)

            Divider()

            if store.sourceBrowserItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("当前位置没有可显示的项目")
                        .font(.headline)
                    Text("可以切换左侧位置，或点击“添加文件”。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                VStack(spacing: 0) {
                    SourceBrowserHeaderRow()
                    ForEach(store.sourceBrowserItems) { item in
                        SourceBrowserItemRow(item: item)
                        if item.id != store.sourceBrowserItems.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .background(Color.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        }
    }
}

struct SourceBrowserHeaderRow: View {
    @EnvironmentObject private var store: MigrationStore

    var body: some View {
        HStack(spacing: 14) {
            Text("名称")
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                Text("大小")
                Button {
                    store.refreshVisibleFolderSizes()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .disabled(!store.canRefreshFolderSizes)
                .help("重新计算当前列表的文件夹大小")
            }
                .frame(width: 96, alignment: .leading)
            Text("修改时间")
                .frame(width: 132, alignment: .leading)
            Text("操作")
                .frame(width: 190, alignment: .trailing)
        }
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.78))
    }
}

struct SourceBrowserItemRow: View {
    @EnvironmentObject private var store: MigrationStore
    let item: SourceBrowserItem

    var body: some View {
        HStack(spacing: 14) {
            Button {
                store.openBrowserItem(item)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: item.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(item.isDirectory ? .blue : .secondary)
                        .frame(width: 28, height: 28)
                        .background((item.isDirectory ? Color.blue : Color.secondary).opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Text(item.canEnter ? "文件夹，点击打开" : "点击加入队列")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(sizeText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)

            Text(Self.modifiedDateString(item.modifiedAt))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 132, alignment: .leading)

            HStack(spacing: 8) {
                if item.canEnter {
                    Button("打开") {
                        store.openBrowserItem(item)
                    }
                }
                Button("加入队列") {
                    store.addBrowserItemToQueue(item)
                }
                .buttonStyle(.borderedProminent)

                if store.canManageBrowserItems {
                    Menu {
                        Button("重命名") {
                            store.renameBrowserItem(item)
                        }
                        Button("移动") {
                            store.chooseMoveDestination(for: item)
                        }
                        Divider()
                        Button("删除", role: .destructive) {
                            store.deleteBrowserItem(item)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .help("更多操作")
                }
            }
            .frame(width: 190, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
    }

    private static func modifiedDateString(_ date: Date?) -> String {
        guard let date else { return "-" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var sizeText: String {
        if item.isDirectory, item.size == nil {
            return "计算中"
        }
        return DriveFormatters.fileSize(item.size ?? 0)
    }
}

struct QueuePanelView: View {
    @EnvironmentObject private var store: MigrationStore

    var body: some View {
        VStack(spacing: 0) {
            QueueHeaderRow()

            if store.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("还没有迁移项目")
                        .font(.headline)
                    Text("拖入文件，或点击“添加文件”。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
            } else {
                ForEach(store.items) { item in
                    QueueItemRow(item: item)
                    if item.id != store.items.last?.id {
                        Divider()
                    }
                }
            }
        }
        .background(Color.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        }
    }
}

struct QueueHeaderRow: View {
    var body: some View {
        HStack(spacing: 14) {
            Text("项目")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("大小")
                .frame(width: 96, alignment: .leading)
            Text("状态")
                .frame(width: 108, alignment: .leading)
            Text("进度")
                .frame(width: 150, alignment: .leading)
        }
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.78))
    }
}

struct QueueItemRow: View {
    let item: MigrationItem

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: item.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 28, height: 28)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(item.sourceSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(DriveFormatters.compactFileSize(item.estimatedSize))
                .font(.subheadline)
                .frame(width: 96, alignment: .leading)

            StatusBadge(status: item.status)
                .frame(width: 108, alignment: .leading)

            QueueProgressView(progress: item.progress, tint: item.status == .needsAttention ? .orange : .green)
                .frame(width: 150)
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
    }
}

struct QueueProgressView: View {
    let progress: Double
    let tint: Color

    private var percentText: String {
        "\(Int((min(max(progress, 0), 1) * 100).rounded()))%"
    }

    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: min(max(progress, 0), 1))
                .progressViewStyle(.linear)
                .tint(tint)
            Text(percentText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
    }
}

struct StatusBadge: View {
    let status: MigrationItemStatus

    var body: some View {
        Text(status.rawValue)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(background)
            .clipShape(Capsule())
    }

    private var foreground: Color {
        switch status {
        case .preflighting:
            return .blue
        case .resuming:
            return .blue
        case .verifying, .copying, .completed:
            return .green
        case .needsAttention:
            return .orange
        case .failed:
            return .red
        case .waiting, .paused:
            return .secondary
        }
    }

    private var background: Color {
        foreground.opacity(0.13)
    }
}

struct TargetInspectorView: View {
    @EnvironmentObject private var store: MigrationStore

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                TargetVolumePanel()
                MigrationModePanel()
                MigrationOptionsPanel()
                TimelinePanel()
            }
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
    }
}

struct TargetVolumePanel: View {
    @EnvironmentObject private var store: MigrationStore

    var body: some View {
        InspectorPanel(title: "目标硬盘") {
            if store.targetDisplayURL != nil {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        DiskSymbol(isWritable: store.hasWritableTarget)
                            .scaleEffect(1.25)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.targetName)
                                .font(.headline)
                                .fontWeight(.bold)
                                .lineLimit(1)
                            Text(store.targetLocationDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    VStack(spacing: 7) {
                        HStack {
                            Text("已用 \(DriveFormatters.compactFileSize(store.targetUsedCapacity ?? 0))")
                            Spacer()
                            Text("可用 \(DriveFormatters.compactFileSize(store.targetAvailableCapacity ?? 0))")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        CapacityMeter(fraction: store.targetUsageFraction, tint: store.targetUsageFraction > 0.8 ? .orange : .green)
                    }

                }
            } else {
                Text("未连接可读写移动硬盘")
                    .foregroundStyle(.secondary)
            }
        } headerAccessory: {
            HStack(spacing: 6) {
                Button("刷新") {
                    store.refreshVolumes()
                }
                Button("选择目标") {
                    store.chooseTargetFolder()
                }
            }
        }
    }
}

struct MigrationModePanel: View {
    @EnvironmentObject private var store: MigrationStore

    var body: some View {
        InspectorPanel(title: "迁移方式") {
            Picker("", selection: $store.migrationMode) {
                ForEach(MigrationMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MigrationOptionsPanel: View {
    @EnvironmentObject private var store: MigrationStore

    var body: some View {
        InspectorPanel(title: "迁移策略") {
            VStack(alignment: .leading, spacing: 10) {
                OptionToggle(
                    title: "复制后校验",
                    detail: "SHA-256 抽样 + 文件大小复核",
                    isOn: $store.options.verifyAfterCopy
                )
                OptionToggle(
                    title: "保留原始时间",
                    detail: "创建时间、修改时间、Finder 标签",
                    isOn: $store.options.preserveMetadata
                )
                OptionToggle(
                    title: "跳过系统缓存",
                    detail: "缓存、缩略图、临时构建目录",
                    isOn: $store.options.skipSystemCaches
                )
                OptionToggle(
                    title: "完成后弹出硬盘",
                    detail: "迁移成功后自动卸载",
                    isOn: $store.options.ejectWhenFinished
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct OptionToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TimelinePanel: View {
    @EnvironmentObject private var store: MigrationStore

    var body: some View {
        InspectorPanel(title: "当前任务") {
            VStack(spacing: 10) {
                ForEach(store.timeline) { step in
                    TimelineStepView(step: step)
                }
            }
        }
    }
}

struct TimelineStepView: View {
    let step: TimelineStep

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
                .overlay {
                    if step.state == .current {
                        Circle()
                            .stroke(dotColor.opacity(0.18), lineWidth: 8)
                    }
                }
                .padding(.top, 4)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    private var dotColor: Color {
        switch step.state {
        case .done:
            return .green
        case .current:
            return .blue
        case .pending:
            return .secondary.opacity(0.32)
        }
    }
}

struct InspectorPanel<Content: View, Accessory: View>: View {
    let title: String
    let content: Content
    let accessory: Accessory

    init(
        title: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder headerAccessory: () -> Accessory
    ) {
        self.title = title
        self.content = content()
        self.accessory = headerAccessory()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.bold)
                Spacer()
                accessory
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            content
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        }
    }
}

extension InspectorPanel where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
        self.accessory = EmptyView()
    }
}

struct CapacityMeter: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.14))
                Capsule()
                    .fill(tint)
                    .frame(width: max(6, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

struct ConflictResolutionSheet: View {
    @EnvironmentObject private var store: MigrationStore
    @Environment(\.dismiss) private var dismiss

    private var conflicts: [MigrationItem] {
        store.items.filter(\.hasConflict)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("同名文件处理")
                    .font(.headline)
                    .fontWeight(.bold)
                Text("\(conflicts.count) 个项目在目标盘已有同名文件。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            Divider()

            VStack(spacing: 8) {
                ForEach(conflicts) { item in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.displayName)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                            Text(item.displayName.contains("Photos") ? "目标盘版本更新于 2026-05-28" : "源文件大 184 MB")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button(item.displayName.contains("Photos") ? "保留两份" : "替换") { }
                    }
                    .padding(10)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                    }
                }
            }
            .padding(16)

            HStack {
                Spacer()
                Button("稍后") {
                    dismiss()
                }
                Button("应用处理") {
                    store.resolveConflicts()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding([.horizontal, .bottom], 16)
        }
        .frame(width: 430)
    }
}
