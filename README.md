# DriveDrop SwiftUI Prototype

DriveDrop 是一个 macOS 原生 SwiftUI 文件迁移应用原型，用来把文件拖入迁移队列并迁移到移动硬盘。

## 运行方式

```bash
cd driver-drop
swift run DriveDrop
```

## 打包为 macOS 应用

```bash
cd driver-drop
scripts/package_app.sh
```

打包结果：

- `dist/DriveDrop.app`：可直接双击打开的 macOS 应用包。
- `dist/DriveDrop.zip`：保留 `.app` 目录结构的压缩包。

## 当前已实现

- SwiftUI 三栏主窗口：来源、迁移队列、目标盘 Inspector。
- 应用图标：打包时写入原生 `.icns` 图标资源。
- 来源浏览器：左侧默认展示用户、桌面、文稿、应用程序、下载、照片、音乐、影片，点击后显示文件/文件夹列表；也可以通过左侧“位置”的加号添加任意文件夹。
- 移动硬盘浏览：点击左侧移动硬盘后，中间列表切换为硬盘内容管理视图。
- 文件管理：移动硬盘和自定义添加位置支持新建文件夹、复制添加、重命名、移动、删除，操作前会弹窗确认。
- 文件夹大小：打开目录时会后台计算当前列表中的文件夹大小，以文件路径为 key 记住本次最新结果；应用重新打开会清空旧大小数据并重新计算，大小列表头可手动刷新实时重算。
- Finder 文件拖拽接收：拖入文件会追加到队列。
- 外接卷扫描：只显示真实外接卷；未连接可读写移动硬盘时目标区域保持空态。
- 容量读取：移动硬盘容量使用文件系统真实容量口径，和 Finder“简介”的可用空间保持一致。
- 写入保护：系统硬盘只作为来源读取，目标只能写入可读写移动硬盘；系统盘来源不允许使用“移动”删除源文件。
- 预计用时：根据队列中未迁移项目的剩余大小估算，空队列显示 0 分钟。
- 迁移进度：队列进度条旁同步显示百分比。
- 断点续传：暂停、普通失败、断电或应用重启后保留 `.drivedrop-part` 临时数据；重新加入同一来源后会复用已复制字节继续迁移。
- 迁移策略：复制/移动/镜像，复制后校验、保留元数据等开关。
- 同名文件冲突弹窗：同名项目可批量应用处理。
- 挂载变化监听：移动硬盘挂载、卸载、重命名后刷新目标盘列表。
- 真实迁移执行：文件分块复制、目录递归复制、进度更新、同名文件保留两份、基础大小校验。
- 安全写入策略：先复制到 `.drivedrop-part` 临时路径，成功校验后再移动到最终文件名。
- 迁移报告：迁移结束后在目标盘 `DriveDrop Migration` 目录生成 Markdown 报告。
- 移动模式：复制并校验完成后删除源文件。

## 文件结构

```text
Sources/DriveDrop/
  DriveDropApp.swift
  Models.swift
  Formatters.swift
  MigrationStore.swift
  MainWindowView.swift
  MigrationExecutor.swift
scripts/
  generate_app_icon.swift
  verify_migration_executor.swift
```

## 验证迁移执行器

当前机器只有 Command Line Tools，缺少 `XCTest`/`Testing` 模块，所以这里提供一个不依赖测试框架的验证脚本：

```bash
cd driver-drop
swiftc Sources/DriveDrop/Models.swift \
  Sources/DriveDrop/Formatters.swift \
  Sources/DriveDrop/MigrationExecutor.swift \
  scripts/verify_migration_executor.swift \
  -o .build/debug/verify-migration-executor
.build/debug/verify-migration-executor
```

## 后续开发重点

- 对 sandbox 权限和 security-scoped bookmark 做持久化。
- 增加全量 SHA-256 校验、速度估算和剩余时间估算。
- 增加真正的镜像同步策略。
