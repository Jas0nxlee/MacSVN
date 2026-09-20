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

        var isSubjectOperation: Bool {
            switch self {
            case .rename, .delete, .move: return true
            case .upload, .login, .openInspect, .logOut: return false
            }
        }
    }

    private var operation: Operation = .upload
    private var subjectName: String?
    private var verificationTarget: String?

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
                case .login, .openInspect, .logOut:
                    break
                }
                phase = 1
            } else if let box = model.errorBox {
                print("✗ 打开失败：\(box.message)")
                exit(1)
            }
        case 1:
            if let prompt = model.inputPrompt {
                print("✓ 弹出输入框：\(prompt.title)（原名 \(prompt.text)）")
                if case .rename(let newName) = operation {
                    prompt.text = newName
                }
                print("  新名称 \(prompt.text) → 校验：\(prompt.validate?(prompt.text) ?? "通过")")
                prompt.message = "headless 重命名测试"
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
            case .upload, .login, .openInspect, .logOut:
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
