import AppKit
import Foundation

/// 隐藏的端到端演练：走真实的 BrowserModel 流程
/// `MacSVN --headless-upload <仓库URL> <目标子目录或-> <本地文件...>`
/// 打开仓库 → 模拟拖入 → 检查重名提示 → 确认提交 → 校验结果。
@MainActor
final class HeadlessScenario {
    private let model: BrowserModel
    private let repository: String
    private let targetName: String?
    private let files: [URL]

    private var elapsed: Double = 0
    private let tickInterval: Double = 0.25
    private var phase = 0

    private enum Operation {
        case upload
        case rename(newName: String)
        case delete
        case login(username: String, password: String)
        case move(target: String)
        /// 打开仓库并断言是否出现登录框
        case openInspect(expectPrompt: Bool)
        /// 打开后退出登录
        case logOut
        /// 新建文件夹（parent 为空表示当前目录）
        case newFolder(parent: String?, name: String)
        /// 库内复制到指定文件夹（target 为 "-" 表示就选当前目录，预期被拦下）
        case copy(target: String)

        var isSubjectOperation: Bool {
            switch self {
            case .rename, .delete, .move: return true
            case .upload, .login, .openInspect, .logOut, .newFolder: return false
            case .copy: return true
            }
        }
    }

    private var operation: Operation = .upload
    private var subjectName: String?
    private var verificationTarget: String?
    private var copyTarget: String?
    private var copyNewName: String?

    static func parse(_ arguments: [String]) -> HeadlessScenario? {
        if let index = arguments.firstIndex(of: "--headless-upload") {
            let rest = Array(arguments.dropFirst(index + 1))
            guard rest.count >= 2 else {
                print("用法: MacSVN --headless-upload <仓库URL> <目标子目录或-> <本地文件...>")
                exit(2)
            }
            return HeadlessScenario(repository: rest[0],
                                    targetName: rest[1] == "-" ? nil : rest[1],
                                    files: rest.dropFirst(2).map { URL(fileURLWithPath: $0) })
        }
        if let index = arguments.firstIndex(of: "--headless-copy") {
            let rest = Array(arguments.dropFirst(index + 1))
            guard rest.count >= 3 else {
                print("用法: MacSVN --headless-copy <仓库URL> <条目名> <目标文件夹|-> [新名字]")
                exit(2)
            }
            let scenario = HeadlessScenario(repository: rest[0], targetName: nil, files: [])
            scenario.subjectName = rest[1]
            scenario.copyTarget = rest[2] == "-" ? nil : rest[2]
            scenario.copyNewName = rest.count > 3 ? rest[3] : nil
            scenario.operation = .copy(target: rest[2])
            return scenario
        }
        if let index = arguments.firstIndex(of: "--headless-newfolder") {
            let rest = Array(arguments.dropFirst(index + 1))
            guard rest.count >= 3 else {
                print("用法: MacSVN --headless-newfolder <仓库URL> <父目录名|-> <新文件夹名>")
                exit(2)
            }
            let scenario = HeadlessScenario(repository: rest[0], targetName: nil, files: [])
            scenario.operation = .newFolder(parent: rest[1] == "-" ? nil : rest[1], name: rest[2])
            return scenario
        }
        if let index = arguments.firstIndex(of: "--headless-open") {
            let rest = Array(arguments.dropFirst(index + 1))
            guard let url = rest.first else {
                print("用法: MacSVN --headless-open <仓库URL> <prompt|silent>")
                exit(2)
            }
            let expectPrompt = (rest.count > 1 ? rest[1] : "silent") == "prompt"
            let scenario = HeadlessScenario(repository: url, targetName: nil, files: [])
            scenario.operation = .openInspect(expectPrompt: expectPrompt)
            return scenario
        }
        if let index = arguments.firstIndex(of: "--headless-logout") {
            let rest = Array(arguments.dropFirst(index + 1))
            guard let url = rest.first else {
                print("用法: MacSVN --headless-logout <仓库URL>")
                exit(2)
            }
            let scenario = HeadlessScenario(repository: url, targetName: nil, files: [])
            scenario.operation = .logOut
            return scenario
        }
        if let index = arguments.firstIndex(of: "--headless-move") {
            let rest = Array(arguments.dropFirst(index + 1))
            guard rest.count >= 3 else {
                print("用法: MacSVN --headless-move <仓库URL> <要移动的条目> <目标目录>")
                exit(2)
            }
            let scenario = HeadlessScenario(repository: rest[0], targetName: nil, files: [])
            scenario.subjectName = rest[1]
            scenario.operation = .move(target: rest[2])
            return scenario
        }
        if let index = arguments.firstIndex(of: "--headless-login") {
            let rest = Array(arguments.dropFirst(index + 1))
            guard rest.count >= 3 else {
                print("用法: MacSVN --headless-login <仓库URL> <用户名> <密码>")
                exit(2)
            }
            let scenario = HeadlessScenario(repository: rest[0], targetName: nil, files: [])
            scenario.operation = .login(username: rest[1], password: rest[2])
            return scenario
        }
        if let index = arguments.firstIndex(of: "--headless-op") {
            let rest = Array(arguments.dropFirst(index + 1))
            guard rest.count >= 3 else {
                print("用法: MacSVN --headless-op <仓库URL> <rename 新名|delete> <条目名>")
                exit(2)
            }
            let scenario = HeadlessScenario(repository: rest[0], targetName: nil, files: [])
            let subject = rest.count > 3 ? rest[2] + "/" + rest[3] : rest[2]
            scenario.subjectName = subject
            if rest[1] == "delete" {
                scenario.operation = .delete
            } else {
                scenario.operation = .rename(newName: rest[1])
            }
            return scenario
        }
        return nil
    }

    init(repository: String, targetName: String?, files: [URL]) {
        self.repository = repository
        self.targetName = targetName
        self.files = files
        self.model = BrowserModel()
    }

    func start() {
        print("→ 打开仓库 \(repository)")
        model.open(url: repository)
        schedule()
    }

    private func schedule() {
        DispatchQueue.main.asyncAfter(deadline: .now() + tickInterval) { [weak self] in
            self?.tick()
        }
    }

    private func tick() {
        elapsed += tickInterval
        if elapsed > 90 {
            print("✗ 超时退出（阶段 \(phase)）")
            exit(1)
        }
        switch phase {
        case 0:
            if case .openInspect(let expectPrompt) = operation {
                if model.loginPrompt != nil {
                    let message = expectPrompt ? "✓ 如预期要求登录" : "✗ 本应免登录，却弹出了登录框"
                    print(message)
                    print(expectPrompt ? "✅ 端到端通过" : "❌ 端到端失败")
                    exit(expectPrompt ? 0 : 1)
                }
                if model.currentURL != nil {
                    let message = expectPrompt
                        ? "✗ 本应要求登录，却直接打开了（凭据被静默复用）"
                        : "✓ 免登录直接打开，共 \(model.entries.count) 项"
                    print(message)
                    print(expectPrompt ? "❌ 端到端失败" : "✅ 端到端通过")
                    exit(expectPrompt ? 1 : 0)
                }
                if let box = model.errorBox, !expectPrompt {
                    print("✗ 打开失败：\(box.message)")
                    exit(1)
                }
                break
            }
            if case .logOut = operation {
                if model.currentURL != nil {
                    print("✓ 已静默打开，共 \(model.entries.count) 项，准备退出登录")
                    let key = RemotePath.hostKey(repository)
                    print("  退出前钥匙串里是否存有登录信息：\(CredentialStore.loadStored(for: key) != nil)")
                    model.logOut()
                    phase = 4
                } else if let box = model.errorBox {
                    print("✗ 打开失败：\(box.message)")
                    exit(1)
                }
                break
            }
            if case .login = operation {
                if let prompt = model.loginPrompt {
                    print("✓ 需要登录，弹出验证框：\(prompt.message)")
                    print("  服务器 \(prompt.hostKey) 记住密码=\(prompt.remember) 需要信任证书=\(prompt.needsTrust)")
                    if case .login(let username, let password) = operation {
                        prompt.username = username
                        prompt.password = password
                        prompt.remember = true   // 走默认行为：记住 1 个月
                        print("→ 提交账号 \(username)")
                        model.submitLoginPrompt(prompt)
                    }
                    phase = 3
                } else if model.currentURL != nil {
                    print("· 无需登录即可打开，共 \(model.entries.count) 项")
                    print("✅ 端到端通过")
                    exit(0)
                } else if let box = model.errorBox {
                    print("✗ 打开失败：\(box.message)")
                    exit(1)
                }
                break
            }
            if model.currentURL != nil {
                print("✓ 已打开，共 \(model.entries.count) 项")
                switch operation {
                case .upload:
                    let target = model.entries.first { $0.name == targetName }
                    print("→ 模拟拖入 \(files.count) 个本地项"
                          + (target.map { " 到目录「\($0.name)」" } ?? " 到当前目录"))
                    model.handleExternalDrop(urls: files, onto: target)
                case .rename(let newName):
                    guard let name = subjectName, model.entries.contains(where: { $0.name == name }) else {
                        print("✗ 库中找不到 \(subjectName ?? "-")")
                        exit(1)
                    }
                    print("→ 重命名「\(name)」为「\(newName)」")
                    model.selection = [name]
                    model.beginRename()
                case .delete:
                    guard let name = subjectName, model.entries.contains(where: { $0.name == name }) else {
                        print("✗ 库中找不到 \(subjectName ?? "-")")
                        exit(1)
                    }
                    print("→ 删除「\(name)」")
                    model.selection = [name]
                    model.beginDelete()
                case .move(let targetName):
                    guard let name = subjectName,
                          let source = model.entries.first(where: { $0.name == name }) else {
                        print("✗ 库中找不到 \(subjectName ?? "-")")
                        exit(1)
                    }
                    guard let target = model.entries.first(where: { $0.name == targetName && $0.isDirectory }) else {
                        print("✗ 目标目录 \(targetName) 不存在")
                        exit(1)
                    }
                    print("→ 库内拖动：把「\(name)」移到目录「\(target.name)」")
                    model.selection = [name]
                    model.handleInternalMove(entries: [source], onto: target)
                case .copy:
                    guard let name = subjectName, let item = model.entries.first(where: { $0.name == name }) else {
                        print("✗ 库中找不到 \(subjectName ?? "-")")
                        exit(1)
                    }
                    print("→ 选中「\(item.name)」（\(item.isDirectory ? "文件夹" : "文件")），打开复制目标选择框")
                    model.selection = [item.name]
                    model.beginCopy()
                case .newFolder(let parent, let name):
                    if let parent {
                        guard let folder = model.entries.first(where: { $0.name == parent && $0.isDirectory }) else {
                            print("✗ 找不到父目录 \(parent)")
                            exit(1)
                        }
                        let target = RemotePath.join(model.currentURL ?? "", UploadPlanner.encodeComponent(folder.name))
                        print("→ 在「\(folder.name)」中新建文件夹「\(name)」")
                        model.beginNewFolder(in: target)
                    } else {
                        print("→ 在当前目录新建文件夹「\(name)」")
                        model.beginNewFolder()
                    }
                case .login, .openInspect, .logOut:
                    break
                }
                phase = 1
            } else if let box = model.errorBox {
                print("✗ 打开失败：\(box.message)")
                exit(1)
            }
        case 1:
            if let prompt = model.copyPrompt {
                if prompt.isLoading {
                    break
                }
                if let loadError = prompt.loadError {
                    print("✗ 打开目标目录失败：\(loadError)")
                    exit(1)
                }
                if case .copy(let target) = operation, target != "-" {
                    let destination = RemotePath.join(repository, UploadPlanner.encodeComponent(target))
                    print("→ 目标选到 \(RemotePath.display(destination))")
                    model.navigateCopy(to: destination)
                    operation = .copy(target: "-")   // 只导航一次
                    phase = 5
                    break
                }
                // 停在当前目录：预期被拦下
                if prompt.blockers.isEmpty {
                    print("✗ 本应拦下（目标就是源所在目录），却没有冲突提示")
                    exit(1)
                }
                for blocker in prompt.blockers {
                    print("  ⛔ \(blocker.path) — \(blocker.reason)")
                }
                print("✓ 目标非法时按钮禁用（canCopy=\(prompt.canCopy)），按预期拦下")
                print("✅ 端到端通过")
                exit(prompt.canCopy ? 1 : 0)
            }
            if let prompt = model.inputPrompt {
                print("✓ 弹出输入框：\(prompt.title)（原名 \(prompt.text)）")
                if case .rename(let newName) = operation {
                    prompt.text = newName
                }
                if case .newFolder(_, let name) = operation {
                    prompt.text = name
                }
                print("  新名称 \(prompt.text) → 校验：\(prompt.validate?(prompt.text) ?? "通过")")
                prompt.message = "headless 新建文件夹测试"
                prompt.onSubmit?(prompt.text, prompt.message)
                operation = .upload   // 后续走通用完成判断
                phase = 2
                break
            }
            if let prompt = model.deletePrompt {
                print("✓ 弹出删除确认：\(prompt.entries.count) 项")
                prompt.message = "headless 删除测试"
                model.confirmDelete(prompt)
                operation = .upload
                phase = 2
                break
            }
            if let prompt = model.transferPrompt {
                let plan = prompt.plan
                print("✓ 弹出确认框：目标 \(plan.targetDir)")
                print("  待上传 \(plan.items.count) 项 / 文件 \(plan.fileCount) / 目录 \(plan.folderCount) / 动作 \(plan.actions.count)")
                if plan.conflicts.isEmpty {
                    print("  无重名冲突")
                } else {
                    print("  ⚠ 重名 \(plan.conflicts.count) 项：\(plan.conflicts.joined(separator: "、"))")
                }
                if !plan.skipped.isEmpty {
                    print("  已跳过：\(plan.skipped.joined(separator: "、"))")
                }
                if plan.hasBlockers {
                    for blocker in plan.blockers {
                        print("  ⛔ 硬冲突：\(blocker.path) — \(blocker.reason)")
                    }
                    print("  （界面上「确定」按钮会被禁用，无法提交）")
                    print("✅ 端到端通过：按预期拦下")
                    exit(0)
                }
                prompt.message = "headless 上传测试"
                print("→ 确认提交")
                model.confirmTransfer(prompt)
                phase = 2
            } else if let box = model.errorBox {
                print("✗ 上传准备失败：\(box.message)")
                exit(1)
            }
        case 2:
            if let prompt = model.transferPrompt, let message = prompt.errorMessage {
                print("✗ 提交失败：\(message)")
                exit(1)
            }
            if let prompt = model.deletePrompt, let message = prompt.errorMessage {
                print("✗ 删除失败：\(message)")
                exit(1)
            }
            if let prompt = model.inputPrompt, let message = prompt.errorMessage {
                print("✗ 提交失败：\(message)")
                exit(1)
            }
            if model.transferPrompt == nil, model.deletePrompt == nil, model.inputPrompt == nil,
               let toast = model.toast {
                print("\(toast.isError ? "✗" : "✓") \(toast.text)")
                verify()
            }
        case 3:
            if model.loginPrompt != nil {
                if let prompt = model.loginPrompt, let message = prompt.errorMessage {
                    print("✗ 登录未通过：\(message)")
                    exit(1)
                }
            } else if model.currentURL != nil {
                print("✓ 验证通过，列出 \(model.entries.count) 项")
                print("✅ 端到端通过")
                exit(0)
            } else if let box = model.errorBox {
                print("✗ 登录后失败：\(box.message)")
                exit(1)
            }
        case 5:
            if let prompt = model.copyPrompt, prompt.isLoading { break }
            if let prompt = model.copyPrompt {
                if let loadError = prompt.loadError {
                    print("  加载目标目录失败：\(loadError)")
                    print("✓ 目标不可用时按钮禁用（canCopy=\(prompt.canCopy)），按预期拦下")
                    print("✅ 端到端通过")
                    exit(prompt.canCopy ? 1 : 0)
                }
                // 改名要在判定冲突之前应用：改名本身可能消除重名冲突
                var renamedNow = false
                if let newName = copyNewName, prompt.newName != newName {
                    guard prompt.allowsRenaming else {
                        print("✗ 多个条目时不支持改名")
                        exit(1)
                    }
                    prompt.newName = newName
                    renamedNow = true
                    print("→ 复制为「\(newName)」")
                }
                if !prompt.blockers.isEmpty {
                    print(renamedNow ? "✗ 改名后被判定为不可用：" : "✗ 目标被判定为不可用：")
                    for blocker in prompt.blockers { print("    \(blocker.path) — \(blocker.reason)") }
                    exit(1)
                }
                print("✓ 目标可用，执行服务端复制")
                model.confirmCopy(prompt)
                phase = 6
            } else if let box = model.errorBox {
                print("✗ \(box.message)")
                exit(1)
            }
        case 6:
            if let prompt = model.copyPrompt, let message = prompt.submitError {
                print("✗ 复制失败：\(message)")
                exit(1)
            }
            if model.copyPrompt == nil, let toast = model.toast {
                print("\(toast.isError ? "✗" : "✓") \(toast.text)")
                verifyCopy()
            }
        case 4:
            if let toast = model.toast {
                print("  提示：\(toast.text)")
                let key = RemotePath.hostKey(repository)
                let stillStored = CredentialStore.loadStored(for: key) != nil
                let cleared = !stillStored
                if cleared {
                    print("✓ 钥匙串里的登录信息已清除")
                } else {
                    print("✗ 钥匙串里仍有残留")
                }
                print(cleared ? "✅ 端到端通过" : "❌ 端到端失败")
                exit(cleared ? 0 : 1)
            }
        default:
            break
        }
        schedule()
    }

    private func verifyCopy() {
        var failed = 0
        guard let name = subjectName, case .copy = operation, let target = copyTarget else {
            print("  · 无目标信息，跳过校验")
            exit(0)
        }
        let destinationName = copyNewName ?? name
        let destinationDir = RemotePath.join(repository, UploadPlanner.encodeComponent(target))
        let sourceURL = RemotePath.join(repository, UploadPlanner.encodeComponent(name))
        let destinationURL = RemotePath.join(destinationDir, UploadPlanner.encodeComponent(destinationName))
        do {
            let targetListing = try SVNClient.shared.listSync(url: destinationDir, options: model.svnOptions(for: destinationDir))
            if targetListing.contains(where: { $0.name == destinationName }) {
                print("  ✓ 目标目录已有「\(destinationName)」")
            } else {
                print("  ✗ 目标目录里没有「\(destinationName)」"); failed += 1
            }
            let sourceListing = try SVNClient.shared.listSync(url: repository, options: model.svnOptions(for: repository))
            if sourceListing.contains(where: { $0.name == name }) {
                print("  ✓ 源仍在原处（是复制而不是移动）")
            } else {
                print("  ✗ 源不见了"); failed += 1
            }
            if destinationName != name {
                print("  ✓ 副本已改名为「\(destinationName)」")
            }
            // 内容一致性：各自导出后逐字节比较
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("macsvn-copy-\(UUID().uuidString)", isDirectory: true)
            let a = tmp.appendingPathComponent("src-\(name)")
            let b = tmp.appendingPathComponent("dst-\(name)")
            try SVNClient.shared.exportSync(url: sourceURL, to: a, options: model.svnOptions(for: repository))
            try SVNClient.shared.exportSync(url: destinationURL, to: b, options: model.svnOptions(for: destinationDir))
            // 文件与文件夹统一处理：把导出结果摊平成「相对路径 → 内容」再比较
            // 两边用同一个 key：改名复制时源名与目标名不同，不能拿名字当 key
            let mapA = treeContents(of: a, key: "(item)"), mapB = treeContents(of: b, key: "(item)")
            if mapA == mapB {
                let bytes = mapA.values.reduce(0) { $0 + $1.count }
                print("  ✓ 源与副本内容一致（\(mapA.count) 个文件，共 \(bytes) 字节）")
            } else {
                print("  ✗ 内容不一致：源 \(mapA.keys.sorted()) / 副本 \(mapB.keys.sorted())")
                failed += 1
            }
            try? FileManager.default.removeItem(at: tmp)
        } catch {
            print("  ✗ 校验失败：\(error.localizedDescription)"); failed += 1
        }
        print(failed == 0 ? "✅ 端到端通过" : "❌ 端到端失败 \(failed) 项")
        exit(failed == 0 ? 0 : 1)
    }

    /// 把导出结果摊平成「相对路径 → 文件内容」，文件夹会递归展开。
    /// 单文件用调用方给的 key，避免两边的临时文件名前缀不同导致比较失败。
    private func treeContents(of url: URL, key: String) -> [String: Data] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [:] }
        if !isDirectory.boolValue {
            return [key: (try? Data(contentsOf: url)) ?? Data()]
        }
        var result: [String: Data] = [:]
        // 解析符号链接并标准化：/var 与 /private/var 混用会让相对路径算错
        let base = url.resolvingSymlinksInPath().standardizedFileURL.path
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let child as URL in enumerator {
                let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir { continue }
                let childPath = child.resolvingSymlinksInPath().standardizedFileURL.path
                guard childPath.hasPrefix(base + "/") else { continue }
                result[String(childPath.dropFirst(base.count + 1))] = (try? Data(contentsOf: child)) ?? Data()
            }
        }
        return result
    }

    private func verifySubjectOperation() {
        var failed = 0
        do {
            let entries = try SVNClient.shared.listSync(url: repository, options: model.svnOptions(for: repository))
            let name = subjectName ?? ""
            let firstName = name.split(separator: "/").first.map(String.init) ?? name
            switch operation {
            case .delete:
                if name.contains("/") {
                    let sub = try SVNClient.shared.listSync(
                        url: RemotePath.join(repository, UploadPlanner.encodeComponent(firstName)),
                        options: model.svnOptions(for: repository))
                    let leaf = name.split(separator: "/").last.map(String.init) ?? ""
                    if sub.contains(where: { $0.name == leaf }) {
                        print("  ✗ \(name) 仍然存在"); failed += 1
                    } else {
                        print("  ✓ \(name) 已删除")
                    }
                } else if entries.contains(where: { $0.name == firstName }) {
                    print("  ✗ \(firstName) 仍然存在"); failed += 1
                } else {
                    print("  ✓ \(firstName) 已删除")
                }
            case .rename(let newName):
                let leaf = newName.split(separator: "/").last.map(String.init) ?? newName
                if entries.contains(where: { $0.name == leaf }) {
                    print("  ✓ \(leaf) 已重命名成功")
                } else {
                    print("  ✗ 未找到重命名后的 \(leaf)"); failed += 1
                }
            case .move(let targetName):
                let leaf = name.split(separator: "/").last.map(String.init) ?? name
                if entries.contains(where: { $0.name == leaf }) {
                    print("  ✗ 源位置仍有 \(leaf)"); failed += 1
                } else {
                    print("  ✓ 源位置已不存在 \(leaf)")
                }
                do {
                    let targetEntries = try SVNClient.shared.listSync(
                        url: RemotePath.join(repository, UploadPlanner.encodeComponent(targetName)),
                        options: model.svnOptions(for: repository))
                    if let moved = targetEntries.first(where: { $0.name == leaf }) {
                        print("  ✓ 已移动到「\(targetName)/\(leaf)」（r\(moved.revision ?? 0)）")
                    } else {
                        print("  ✗ 目标目录中没有 \(leaf)"); failed += 1
                    }
                }
            case .newFolder(let parent, let name):
                let base = parent.map { RemotePath.join(repository, UploadPlanner.encodeComponent($0)) } ?? repository
                do {
                    let listing = try SVNClient.shared.listSync(url: base, options: model.svnOptions(for: base))
                    if let created = listing.first(where: { $0.name == name && $0.isDirectory }) {
                        print("  ✓ 已创建「\(parent.map { $0 + "/" } ?? "")\(name)」（r\(created.revision ?? 0)）")
                    } else {
                        print("  ✗ 未在库中找到 \(name)"); failed += 1
                    }
                } catch {
                    print("  ✗ 校验失败：\(error.localizedDescription)"); failed += 1
                }
                print(failed == 0 ? "✅ 端到端通过" : "❌ 端到端失败 \(failed) 项")
                exit(failed == 0 ? 0 : 1)
            case .upload, .login, .openInspect, .logOut, .copy:
                break
            }
        } catch let error as SVNError {
            print("  ✗ 校验失败：\(error.message)"); failed += 1
        } catch {
            print("  ✗ 校验失败：\(error.localizedDescription)"); failed += 1
        }
        print(failed == 0 ? "✅ 端到端通过" : "❌ 端到端失败 \(failed) 项")
        exit(failed == 0 ? 0 : 1)
    }

    private func verify() {
        var failed = 0
        if subjectName != nil || operation.isSubjectOperation {
            verifySubjectOperation()
            return
        }
        let base = targetName.map { RemotePath.join(repository, UploadPlanner.encodeComponent($0)) } ?? repository
        print("→ 校验 \(base)")
        do {
            let entries = try SVNClient.shared.listSync(url: base, options: model.svnOptions(for: base))
            for file in files {
                let name = file.lastPathComponent
                if let entry = entries.first(where: { $0.name == name }) {
                    print("  ✓ \(name) 已在库中（\(entry.isDirectory ? "文件夹" : Fmt.size(entry.size))，r\(entry.revision ?? 0)）")
                } else {
                    print("  ✗ \(name) 未出现在库中")
                    failed += 1
                }
            }
            let directory = base.replacingOccurrences(of: repository, with: "")
            if !directory.isEmpty {
                let parentEntries = try SVNClient.shared.listSync(url: repository, options: model.svnOptions(for: repository))
                print("  · 仓库根目录当前 \(parentEntries.count) 项")
            }
        } catch let error as SVNError {
            print("  ✗ 校验失败：\(error.message)")
            failed += 1
        } catch {
            print("  ✗ 校验失败：\(error.localizedDescription)")
            failed += 1
        }
        print(failed == 0 ? "✅ 端到端通过" : "❌ 端到端失败 \(failed) 项")
        exit(failed == 0 ? 0 : 1)
    }
}
