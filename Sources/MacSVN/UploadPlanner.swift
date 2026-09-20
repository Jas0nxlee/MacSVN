import Foundation

/// 把本地文件/文件夹整理成 svnmucc 动作，并检测与库中已有路径的重名情况。
enum UploadPlanner {
    struct LocalItem {
        let url: URL
        let relativePath: String   // 相对被拖入项的父目录，如 "docs/guide.txt"
        let isDirectory: Bool
        let size: Int64
    }

    /// svn 默认的 global-ignores，外加 .svn / .git 等版本控制元数据目录
    private static let ignorePatterns = [
        ".DS_Store", "*.o", "*.lo", "*.la", "*.al", ".libs", "*.so", "*.so.[0-9]*",
        "*.a", "*.pyc", "*.pyo", "__pycache__", "*.rej", "*~", "#*#", ".#*",
        ".*.swp", "[Tt]humbs.db", "[Tt]humbs.db",
    ]
    private static let ignoreDirectories: Set<String> = [".svn", ".git", ".hg", ".bzr", "CVS"]

    static func isIgnored(name: String) -> Bool {
        for pattern in ignorePatterns where fnmatch(pattern, name, 0) == 0 {
            return true
        }
        return false
    }

    // MARK: 本地枚举

    static func enumerate(roots: [URL]) -> (items: [LocalItem], skipped: [String]) {
        var items: [LocalItem] = []
        var skipped: [String] = []
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]

        for root in roots {
            let originalValues = try? root.resourceValues(forKeys: Set(keys))
            let rootName = root.lastPathComponent
            if ignoreDirectories.contains(rootName) || isIgnored(name: rootName) {
                skipped.append(rootName)
                continue
            }
            if originalValues?.isSymbolicLink == true {
                skipped.append(rootName + "（符号链接）")
                continue
            }

            // 解析符号链接：枚举出来的 URL 会沿用同一套路径前缀，
            // 否则 /var 与 /private/var 这类差异会让相对路径计算失去层级。
            let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
            let isDirectory = (try? resolvedRoot.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let rootSize = isDirectory ? 0 : Int64((try? resolvedRoot.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)

            // 被拖入的项自身也要计入（枚举器只会遍历其子项）
            items.append(LocalItem(url: resolvedRoot, relativePath: rootName,
                                   isDirectory: isDirectory, size: rootSize))
            guard isDirectory else { continue }

            let parentPath = resolvedRoot.deletingLastPathComponent().path
            guard let enumerator = fm.enumerator(at: resolvedRoot,
                                                 includingPropertiesForKeys: keys,
                                                 options: [],
                                                 errorHandler: { _, _ in true }) else {
                skipped.append(rootName + "（无法读取）")
                continue
            }
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                let values = try? url.resourceValues(forKeys: Set(keys))
                let isDir = values?.isDirectory ?? false

                if ignoreDirectories.contains(name) || isIgnored(name: name) {
                    if isDir { enumerator.skipDescendants() }
                    skipped.append(relative(url: url, parent: parentPath))
                    continue
                }
                if values?.isSymbolicLink == true {
                    if isDir { enumerator.skipDescendants() }
                    skipped.append(relative(url: url, parent: parentPath) + "（符号链接）")
                    continue
                }

                items.append(LocalItem(url: url,
                                       relativePath: relative(url: url, parent: parentPath),
                                       isDirectory: isDir,
                                       size: isDir ? 0 : Int64(values?.fileSize ?? 0)))
            }
        }
        return (items, skipped)
    }

    private static func relative(url: URL, parent: String) -> String {
        let path = url.standardizedFileURL.path
        if path.hasPrefix(parent + "/") {
            return String(path.dropFirst(parent.count + 1))
        }
        // 兜底：逐级向上拼接，直到回到父目录
        var parts: [String] = []
        var current = path
        while !current.isEmpty, current != parent, current != "/" {
            parts.insert((current as NSString).lastPathComponent, at: 0)
            current = (current as NSString).deletingLastPathComponent
        }
        return parts.isEmpty ? url.lastPathComponent : parts.joined(separator: "/")
    }

    // MARK: 上传计划

    /// - Parameter remoteKinds: 目标目录下已存在的相对路径 → 类型（含递归子路径）
    static func buildUploadPlan(roots: [URL],
                                targetDir: String,
                                remoteKinds: [String: RemoteKind],
                                extraSkipped: [String] = []) -> TransferPlan {
        let (localItems, skipped) = enumerate(roots: roots)
        var actions: [SVNMAction] = []
        var conflicts: [String] = []
        var blockers: [TransferBlocker] = []
        var blockedPrefixes: [String] = []
        var mergedDirs: [String] = []
        var topLevel: [UploadItem] = []
        var topLevelIndex: [String: Int] = [:]
        var fileCount = 0
        var folderCount = 0
        var totalBytes: Int64 = 0

        for root in roots {
            let name = root.lastPathComponent
            let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDirectory = values?.isDirectory ?? false
            let size = isDirectory ? 0 : Int64(values?.fileSize ?? 0)
            topLevelIndex[name] = topLevel.count
            topLevel.append(UploadItem(localURL: root, name: name, relativePath: name,
                                       isDirectory: isDirectory, size: size))
            if isDirectory { folderCount += 1 } else {
                fileCount += 1
                totalBytes += size
            }
        }

        for item in localItems {
            let remoteURL = encode(relativePath: item.relativePath, under: targetDir)
            let remoteKind = remoteKinds[item.relativePath]
            let rootName = item.relativePath.split(separator: "/").first.map(String.init) ?? item.relativePath
            let isNested = item.relativePath.contains("/")

            // 位于已被拦下的子树内，跳过
            if blockedPrefixes.contains(where: { item.relativePath.hasPrefix($0 + "/") }) {
                continue
            }

            switch (item.isDirectory, remoteKind) {
            case (true, .some(.directory)):
                // 库里已有同名目录：合并内容
                mergedDirs.append(item.relativePath)
                if isNested { folderCount += 1 }
                topLevelIndex[rootName].map { topLevel[$0].willOverwrite = true }

            case (true, .some(.file)):
                // 库里同名的是文件，目录建不出来
                blockers.append(TransferBlocker(path: item.relativePath,
                                                reason: "库中是同名文件，无法合并为目录"))
                blockedPrefixes.append(item.relativePath)
                if isNested { folderCount += 1 }

            case (false, .some(.directory)):
                // 库里同名的是目录，文件覆盖不了目录
                blockers.append(TransferBlocker(path: item.relativePath,
                                                reason: "库中是同名文件夹，无法覆盖为文件"))
                if isNested {
                    fileCount += 1
                    totalBytes += item.size
                }

            case (false, .some(.file)):
                // 同名文件：确认后覆盖
                conflicts.append(item.relativePath)
                topLevelIndex[rootName].map { topLevel[$0].willOverwrite = true }
                actions.append(.put(local: item.url, remote: remoteURL))
                if isNested {
                    fileCount += 1
                    totalBytes += item.size
                }

            case (true, .none):
                actions.append(.mkdir(remoteURL))
                if isNested { folderCount += 1 }

            case (false, .none):
                actions.append(.put(local: item.url, remote: remoteURL))
                if isNested {
                    fileCount += 1
                    totalBytes += item.size
                }
            }
        }

        return TransferPlan(mode: .upload,
                            targetDir: targetDir,
                            actions: actions,
                            items: topLevel,
                            conflicts: conflicts.sorted(),
                            blockers: blockers,
                            mergedDirs: mergedDirs.sorted(),
                            fileCount: fileCount,
                            folderCount: folderCount,
                            totalBytes: totalBytes,
                            skipped: extraSkipped + skipped)
    }

    /// 目标目录下的名字 → 类型
    static func kindMap(in entries: [SVNEntry]) -> [String: RemoteKind] {
        var map: [String: RemoteKind] = [:]
        for entry in entries {
            map[entry.name] = entry.isDirectory ? .directory : .file
        }
        return map
    }

    // MARK: 库内移动计划

    static func buildMovePlan(entries: [SVNEntry],
                              from sourceDir: String,
                              to targetDir: String,
                              remoteKinds: [String: RemoteKind]) -> TransferPlan {
        var actions: [SVNMAction] = []
        var blockers: [TransferBlocker] = []
        var items: [UploadItem] = []
        var totalBytes: Int64 = 0

        for entry in entries {
            let source = RemotePath.join(sourceDir, entry.name)
            let destination = RemotePath.join(targetDir, entry.name)
            if let kind = remoteKinds[entry.name] {
                blockers.append(TransferBlocker(
                    path: entry.name,
                    reason: kind.isDirectory ? "目标目录已存在同名文件夹" : "目标目录已存在同名文件"))
            } else {
                actions.append(.move(from: source, to: destination))
            }
            items.append(UploadItem(localURL: URL(fileURLWithPath: "/"),
                                    name: entry.name,
                                    relativePath: entry.name,
                                    isDirectory: entry.isDirectory,
                                    size: entry.size ?? 0,
                                    willOverwrite: false))
            totalBytes += entry.size ?? 0
        }

        return TransferPlan(mode: .move,
                            targetDir: targetDir,
                            actions: actions,
                            items: items,
                            conflicts: [],
                            blockers: blockers,
                            mergedDirs: [],
                            fileCount: items.filter { !$0.isDirectory }.count,
                            folderCount: items.filter(\.isDirectory).count,
                            totalBytes: totalBytes,
                            skipped: [])
    }

    // MARK: 路径编码

    static func encode(relativePath: String, under base: String) -> String {
        var url = base
        while url.hasSuffix("/") { url.removeLast() }
        for component in relativePath.split(separator: "/") {
            url += "/" + encodeComponent(String(component))
        }
        return url
    }

    static func encodeComponent(_ name: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
    }
}
