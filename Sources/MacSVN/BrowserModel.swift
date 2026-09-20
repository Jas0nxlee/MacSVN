import AppKit
import Combine
import Foundation

// MARK: - 弹窗模型

final class LoginPrompt: ObservableObject, Identifiable {
    let id = UUID()
    let url: String
    let hostKey: String
    let message: String
    @Published var username: String
    @Published var password: String = ""
    @Published var remember: Bool
    @Published var trustCertificate: Bool
    @Published var needsTrust: Bool
    @Published var errorMessage: String?
    @Published var inProgress = false
    var onSubmit: (() -> Void)?

    init(url: String, hostKey: String, message: String, username: String, remember: Bool, needsTrust: Bool) {
        self.url = url
        self.hostKey = hostKey
        self.message = message
        self.username = username
        self.remember = remember
        self.needsTrust = needsTrust
        self.trustCertificate = needsTrust
    }
}

/// 上传 / 库内移动 的确认框
final class TransferPrompt: ObservableObject, Identifiable {
    let id = UUID()
    let plan: TransferPlan
    @Published var message: String
    @Published var inProgress = false
    @Published var errorMessage: String?
    @Published var showDetails = false

    init(plan: TransferPlan, message: String) {
        self.plan = plan
        self.message = message
    }
}

/// 通用单行输入（重命名 / 新建目录 / 设置 svn 路径）
final class InputPrompt: ObservableObject, Identifiable {
    enum Kind { case rename, newFolder, svnPath }

    let id = UUID()
    let kind: Kind
    let title: String
    let fieldLabel: String
    let note: String?
    let confirmTitle: String
    let showsMessageField: Bool
    var validate: ((String) -> String?)?
    var onSubmit: ((String, String) -> Void)?
    @Published var text: String
    @Published var message: String
    @Published var errorMessage: String?
    @Published var inProgress = false

    init(kind: Kind, title: String, fieldLabel: String, initialText: String,
         note: String? = nil, confirmTitle: String = "确定", showsMessageField: Bool = true,
         message: String = "") {
        self.kind = kind
        self.title = title
        self.fieldLabel = fieldLabel
        self.text = initialText
        self.note = note
        self.confirmTitle = confirmTitle
        self.showsMessageField = showsMessageField
        self.message = message
    }
}

/// Homebrew 安装 Subversion 的进度框
final class InstallPrompt: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case running
        case succeeded(version: String)
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let brewPath: String?
    @Published var phase: Phase = .running
    @Published var log: [String] = []
    var onCancel: (() -> Void)?
    var onRetry: (() -> Void)?

    init(brewPath: String?) {
        self.brewPath = brewPath
    }

    func append(_ line: String) {
        log.append(line)
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }
}

/// 删除确认框
final class DeletePrompt: ObservableObject, Identifiable {
    let id = UUID()
    let entries: [SVNEntry]
    let baseDir: String
    @Published var message: String
    @Published var inProgress = false
    @Published var errorMessage: String?

    init(entries: [SVNEntry], baseDir: String, message: String) {
        self.entries = entries
        self.baseDir = baseDir
        self.message = message
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var isError = false
}

struct ErrorBox: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var detail: String
    /// 缺 svn 命令时，弹窗里直接给一个安装入口
    var offersInstall = false
}

// MARK: - 主模型

@MainActor
final class BrowserModel: ObservableObject {

    // 导航状态
    @Published private(set) var currentURL: String?
    @Published var addressText: String = ""
    @Published private(set) var entries: [SVNEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadingMessage = "正在打开…"
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var repoInfo: RepositoryInfo?
    @Published var selection: Set<String> = []
    @Published var addressFocusRequest = 0

    // 排序
    @Published private(set) var sortKey: String = "name"
    @Published private(set) var sortAscending = true

    // 提示
    @Published var toast: Toast?
    @Published var errorBox: ErrorBox?
    @Published var statusText = ""
    @Published var busy = false
    @Published var busyMessage = ""
    @Published var environmentWarning: String?
    @Published var svnVersion: String?
    @Published private(set) var svnPath: String?
    @Published private(set) var brewPath: String?
    @Published private(set) var isInstalling = false
    @Published var installPrompt: InstallPrompt?

    // 弹窗
    @Published var loginPrompt: LoginPrompt?
    @Published var transferPrompt: TransferPrompt?
    @Published var inputPrompt: InputPrompt?
    @Published var deletePrompt: DeletePrompt?

    // 最近打开的仓库
    @Published private(set) var recents: [String] = []

    // 会话内的凭据与信任
    private var sessionCredentials: [String: Credentials] = [:]
    private var trustedHosts: Set<String> = []
    private var history: [String] = []
    private var historyIndex = -1
    private var toastTask: Task<Void, Never>?
    private var openFileCache: [String: URL] = [:]

    private static let recentsKey = "RecentRepositories"

    init() {
        recents = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        refreshEnvironment()
    }

    // MARK: 环境

    /// 渲染预览时不要用真实环境覆盖注入状态
    private var suppressEnvironmentRefresh = false

    func refreshEnvironment() {
        guard !suppressEnvironmentRefresh else { return }
        environmentWarning = SVNClient.shared.environmentProblem()
        svnVersion = SVNClient.shared.svnVersion()
        svnPath = try? SVNClient.shared.toolPath(.svn)
        brewPath = HomebrewInstaller.locateBrew()
    }

    var isSVNReady: Bool { svnPath != nil }

    /// 重新检测（用户在终端里装完东西后回来点）
    func recheckEnvironment() {
        SVNClient.shared.resetToolPaths()
        refreshEnvironment()
        if let version = svnVersion {
            showToast("Subversion \(version) 已就绪")
        } else if brewPath == nil {
            showToast("仍未检测到 svn；本机也没有 Homebrew，需要先安装 Homebrew", isError: true)
        } else {
            showToast("仍未检测到 svn 命令", isError: true)
        }
    }

    // MARK: 安装 Subversion

    func beginInstallSubversion() {
        guard !isInstalling else { return }
        guard brewPath != nil else {
            beginInstallHomebrew()
            return
        }
        let prompt = InstallPrompt(brewPath: brewPath)
        prompt.append("使用 \(brewPath ?? "brew") install subversion")
        let runner = HomebrewInstaller.Runner()
        prompt.onCancel = {
            runner.cancel()
        }
        prompt.onRetry = { [weak self] in
            self?.installPrompt = nil
            self?.beginInstallSubversion()
        }
        installPrompt = prompt
        isInstalling = true

        runner.install(formula: "subversion") { [weak prompt] line in
            prompt?.append(line)
        } onFinish: { [weak self] result in
            guard let self else { return }
            self.isInstalling = false
            switch result {
            case .success(0):
                SVNClient.shared.resetToolPaths()
                self.refreshEnvironment()
                if let version = self.svnVersion {
                    prompt.phase = .succeeded(version: version)
                    prompt.append("✓ Subversion \(version) 已就绪")
                    self.showToast("Subversion \(version) 安装完成")
                } else {
                    prompt.phase = .failed("安装命令已结束，但仍未找到 svn。可能装到了非标准目录，可用“设置 SVN 路径…”指定。")
                }
            case .success(let status):
                prompt.phase = .failed("brew 退出码 \(status)，安装未成功。")
            case .failure(let error):
                if let svnError = error as? SVNError, svnError.kind == .cancelled {
                    prompt.phase = .cancelled
                    prompt.append("已取消安装。")
                } else {
                    prompt.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// 本机没有 Homebrew：必须在终端里装（需要管理员密码），装完回来点「重新检测」
    func beginInstallHomebrew() {
        let script = HomebrewInstaller.installHomebrewScript()
        do {
            try HomebrewInstaller.openInTerminal(title: "安装 Homebrew", script: script)
            showToast("已在终端中打开安装脚本；装完后回到 MacSVN 点「重新检测」")
        } catch {
            showError(ErrorBox(title: "无法打开终端",
                               message: error.localizedDescription,
                               detail: HomebrewInstaller.homebrewInstallCommand))
        }
    }

    /// 不走 brew 进程，直接在终端里手动安装（给权限异常等情况留后路）
    func installInTerminal() {
        do {
            try HomebrewInstaller.openInTerminal(title: "安装 Subversion",
                                                 script: "brew install subversion")
            showToast("已在终端中执行 brew install subversion；装完后点「重新检测」")
        } catch {
            showError(ErrorBox(title: "无法打开终端",
                               message: error.localizedDescription,
                               detail: HomebrewInstaller.subversionInstallCommand))
        }
    }

    func copyInstallCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let command = brewPath == nil
            ? HomebrewInstaller.homebrewInstallCommand + "\n" + HomebrewInstaller.subversionInstallCommand
            : HomebrewInstaller.subversionInstallCommand
        pasteboard.setString(command, forType: .string)
        showToast("安装命令已复制到剪贴板")
    }

    // MARK: 打开 / 导航

    func submitAddress() {
        let raw = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        open(url: raw)
    }

    func open(url input: String) {
        let (url, error) = RemotePath.normalize(input)
        guard let url else {
            showError(ErrorBox(title: "地址无效", message: error ?? "无法解析地址", detail: input))
            return
        }
        pushHistory(url)
        Task { await load(url: url, allowPrompt: true) }
    }

    func reload() {
        guard let url = currentURL else { return }
        Task { await load(url: url, allowPrompt: true) }
    }

    func goBack() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        let url = history[historyIndex]
        Task { await load(url: url, allowPrompt: true) }
    }

    func goForward() {
        guard historyIndex >= 0, historyIndex < history.count - 1 else { return }
        historyIndex += 1
        let url = history[historyIndex]
        Task { await load(url: url, allowPrompt: true) }
    }

    func goUp() {
        guard let current = currentURL, let parent = RemotePath.parent(of: current) else { return }
        open(url: parent)
    }

    func openEntry(_ entry: SVNEntry) {
        guard let current = currentURL else { return }
        let target = RemotePath.join(current, UploadPlanner.encodeComponent(entry.name))
        if entry.isDirectory {
            open(url: target)
        } else {
            downloadAndOpen(entry: entry, remoteURL: target)
        }
    }

    func openSelected() {
        guard let entry = selectedEntries.first else { return }
        openEntry(entry)
    }

    /// 当前选中的项（按列表顺序）
    var selectedEntryList: [SVNEntry] {
        entries.filter { selection.contains($0.name) }
    }

    private var selectedEntries: [SVNEntry] { selectedEntryList }

    private func pushHistory(_ url: String) {
        if historyIndex >= 0, historyIndex < history.count, history[historyIndex] == url { return }
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(url)
        if history.count > 200 { history.removeFirst(history.count - 200) }
        historyIndex = history.count - 1
        updateHistoryFlags()
    }

    private func updateHistoryFlags() {
        canGoBack = historyIndex > 0
        canGoForward = historyIndex >= 0 && historyIndex < history.count - 1
    }

    // MARK: 加载目录

    private func load(url: String, allowPrompt: Bool) async {
        isLoading = true
        loadingMessage = "正在打开 \(RemotePath.prettyPath(url))…"
        defer { isLoading = false }

        do {
            let list = try await SVNClient.shared.list(url: url, options: options(for: url))
            currentURL = url
            addressText = url
            entries = sortEntries(list)
            selection = []
            repoInfo = nil
            lastError = nil
            statusText = "共 \(entries.count) 项"
            debugLog("加载成功 \(url) 条目=\(entries.count)")
            addRecent(url)
            if url.range(of: "://[^/]+/?$", options: .regularExpression) != nil {
                repoInfo = try? await SVNClient.shared.info(url: url, options: options(for: url))
            }
        } catch let error as SVNError {
            if allowPrompt, error.kind.needsCredentialPrompt {
                presentLogin(for: url, error: error)
            } else {
                present(error: error)
            }
        } catch {
            showError(ErrorBox(title: "打开失败", message: error.localizedDescription, detail: ""))
        }
    }

    // MARK: 登录

    private func presentLogin(for url: String, error: SVNError, prefillError: String? = nil) {
        let key = RemotePath.hostKey(url)
        let stored = CredentialStore.load(for: key)
        let prompt = LoginPrompt(url: url,
                                 hostKey: key,
                                 message: error.message,
                                 username: stored?.username ?? sessionCredentials[key]?.username ?? "",
                                 remember: stored != nil,
                                 needsTrust: error.kind == .certificate)
        if let stored { prompt.password = stored.password }
        prompt.errorMessage = prefillError
        prompt.onSubmit = { [weak self] in
            guard let self else { return }
            self.submitLogin(prompt)
        }
        loginPrompt = prompt
    }

    func submitLoginPrompt(_ prompt: LoginPrompt) {
        submitLogin(prompt)
    }

    func cancelLogin() {
        loginPrompt = nil
    }

    private func submitLogin(_ prompt: LoginPrompt) {
        let username = prompt.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            prompt.errorMessage = "请输入用户名"
            return
        }
        let credentials = Credentials(username: username, password: prompt.password)
        sessionCredentials[prompt.hostKey] = credentials
        if prompt.remember {
            CredentialStore.save(credentials, for: prompt.hostKey)
        } else {
            CredentialStore.delete(for: prompt.hostKey)
        }
        if prompt.trustCertificate {
            trustedHosts.insert(prompt.hostKey)
        }
        loginPrompt = nil

        Task {
            await load(url: prompt.url, allowPrompt: false)
            // 凭据仍然被拒绝时，继续让用户修正，而不是抛一个通用错误
            if let lastError, lastError.kind.needsCredentialPrompt {
                self.lastError = nil
                errorBox = nil
                // 等上一个 sheet 的关闭动画结束，否则新的 sheet 会被系统忽略
                try? await Task.sleep(nanoseconds: 420_000_000)
                presentLogin(for: prompt.url, error: lastError, prefillError: lastError.message)
            }
        }
    }

    private var lastError: SVNError?

    private func options(for url: String, timeout: TimeInterval = 300) -> SVNClient.Options {
        svnOptions(for: url, timeout: timeout)
    }

    /// 供文件列表在拖出时构造下载任务使用
    func svnOptions(for url: String, timeout: TimeInterval = 300) -> SVNClient.Options {
        let key = RemotePath.hostKey(url)
        return SVNClient.Options(credentials: sessionCredentials[key],
                                 trustCertificate: trustedHosts.contains(key),
                                 timeout: timeout)
    }

    // MARK: 排序

    func sort(by key: String) {
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            sortAscending = true
        }
        entries = sortEntries(entries)
    }

    /// 仅供隐藏的 --render-ui 渲染模式注入环境状态
    func applyEnvironmentForRender(svnPath: String?, brewPath: String?) {
        suppressEnvironmentRefresh = true
        self.svnPath = svnPath
        self.brewPath = brewPath
        self.svnVersion = svnPath == nil ? nil : "1.14.5"
        self.environmentWarning = svnPath == nil ? "未找到 svn 命令" : nil
    }

    /// 仅供隐藏的 --render-ui 渲染模式注入数据
    func applyForRender(url: String, entries: [SVNEntry]) {
        currentURL = url
        addressText = url
        self.entries = sortEntries(entries)
        statusText = "共 \(entries.count) 项"
        selection = []
    }

    /// 由表头点击驱动
    func applySort(key: String, ascending: Bool) {
        guard key != sortKey || ascending != sortAscending else { return }
        sortKey = key
        sortAscending = ascending
        entries = sortEntries(entries)
    }

    private func sortEntries(_ list: [SVNEntry]) -> [SVNEntry] {
        list.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let result: ComparisonResult
            switch sortKey {
            case "size":
                result = compare(lhs.size ?? -1, rhs.size ?? -1)
            case "revision":
                result = compare(lhs.revision ?? -1, rhs.revision ?? -1)
            case "author":
                result = (lhs.author ?? "").localizedStandardCompare(rhs.author ?? "")
            case "date":
                result = compare(lhs.date?.timeIntervalSince1970 ?? 0, rhs.date?.timeIntervalSince1970 ?? 0)
            case "type":
                result = lhs.typeText.localizedStandardCompare(rhs.typeText)
            default:
                result = lhs.name.localizedStandardCompare(rhs.name)
            }
            if result == .orderedSame { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            return sortAscending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    // MARK: 重命名

    func beginRename() {
        guard let current = currentURL, selectedEntries.count == 1, let entry = selectedEntries.first else {
            showToast("请先选择一项", isError: true)
            return
        }
        let prompt = InputPrompt(kind: .rename,
                                 title: entry.isDirectory ? "重命名文件夹" : "重命名文件",
                                 fieldLabel: "新名称",
                                 initialText: entry.name,
                                 note: "位于 \(RemotePath.prettyPath(current))/",
                                 confirmTitle: "重命名",
                                 message: "重命名 \(entry.name)")
        prompt.validate = { [weak self] text in
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { return "名称不能为空" }
            if name.contains("/") { return "名称中不能包含“/”" }
            if name == "." || name == ".." { return "名称无效" }
            if name == entry.name { return "名称没有变化" }
            if self?.entries.contains(where: { $0.name == name }) == true { return "当前目录已存在同名项" }
            return nil
        }
        prompt.onSubmit = { [weak self] text, message in
            guard let self else { return }
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let source = RemotePath.join(current, UploadPlanner.encodeComponent(entry.name))
            let destination = RemotePath.join(current, UploadPlanner.encodeComponent(name))
            Task {
                await self.performCommit(prompt: prompt,
                                         actions: [.move(from: source, to: destination)],
                                         message: message,
                                         success: "已重命名为“\(name)”")
            }
        }
        inputPrompt = prompt
    }

    // MARK: 新建目录

    func beginNewFolder() {
        guard let current = currentURL else { return }
        let prompt = InputPrompt(kind: .newFolder,
                                 title: "新建文件夹",
                                 fieldLabel: "文件夹名称",
                                 initialText: "",
                                 note: "将在 \(RemotePath.prettyPath(current))/ 下创建",
                                 confirmTitle: "创建",
                                 message: "新建目录")
        prompt.validate = { [weak self] text in
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { return "名称不能为空" }
            if name.contains("/") { return "名称中不能包含“/”" }
            if name == "." || name == ".." { return "名称无效" }
            if self?.entries.contains(where: { $0.name == name }) == true { return "当前目录已存在同名项" }
            return nil
        }
        prompt.onSubmit = { [weak self] text, message in
            guard let self else { return }
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = RemotePath.join(current, UploadPlanner.encodeComponent(name))
            Task {
                await self.performCommit(prompt: prompt,
                                         actions: [.mkdir(target)],
                                         message: message,
                                         success: "已创建文件夹“\(name)”")
            }
        }
        inputPrompt = prompt
    }

    // MARK: 删除

    func beginDelete() {
        guard let current = currentURL else { return }
        let targets = selectedEntries
        guard !targets.isEmpty else {
            showToast("请先选择要删除的项", isError: true)
            return
        }
        let summary = targets.count == 1 ? "“\(targets[0].name)”" : "\(targets.count) 项"
        deletePrompt = DeletePrompt(entries: targets, baseDir: current, message: "删除 \(summary)")
    }

    func confirmDelete(_ prompt: DeletePrompt) {
        let actions = prompt.entries.map {
            SVNMAction.remove(RemotePath.join(prompt.baseDir, UploadPlanner.encodeComponent($0.name)))
        }
        prompt.inProgress = true
        prompt.errorMessage = nil
        Task {
            do {
                let revision = try await SVNClient.shared.commit(actions: actions,
                                                                 message: prompt.message.isEmpty ? "删除" : prompt.message,
                                                                 options: options(for: prompt.baseDir, timeout: 600))
                self.deletePrompt = nil
                self.showToast("已删除，版本 r\(revision)")
                await self.refreshAfterMutation(url: prompt.baseDir)
            } catch let error as SVNError {
                prompt.inProgress = false
                prompt.errorMessage = error.message
            } catch {
                prompt.inProgress = false
                prompt.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: 上传（拖入）

    func handleExternalDrop(urls: [URL], onto target: SVNEntry?) {
        guard let current = currentURL else { return }
        let targetDir = target?.isDirectory == true
            ? RemotePath.join(current, UploadPlanner.encodeComponent(target!.name))
            : current
        let knownEntries = targetDir == current ? entries : nil
        Task { await prepareUpload(urls: urls, targetDir: targetDir, knownEntries: knownEntries) }
    }

    private func prepareUpload(urls: [URL], targetDir: String, knownEntries: [SVNEntry]?) async {
        let fileURLs = urls.filter { $0.isFileURL }
        guard !fileURLs.isEmpty else {
            showToast("只支持拖入本地文件或文件夹", isError: true)
            return
        }
        busy = true
        busyMessage = "正在检查库中是否已有同名文件…"
        defer { busy = false }
        do {
            let options = options(for: targetDir)
            var remoteKinds: [String: RemoteKind]
            if let knownEntries {
                remoteKinds = UploadPlanner.kindMap(in: knownEntries)
            } else {
                remoteKinds = UploadPlanner.kindMap(in: try await SVNClient.shared.list(url: targetDir, options: options))
            }

            // 目录合并：把已存在目录的整棵子树也拉下来，用于精确判断覆盖范围
            for url in fileURLs {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                let name = url.lastPathComponent
                // 只有当库里同名项也是目录时才需要合并
                guard remoteKinds[name]?.isDirectory == true else { continue }
                let subURL = RemotePath.join(targetDir, UploadPlanner.encodeComponent(name))
                if let subKinds = try? await SVNClient.shared.listRecursiveKinds(url: subURL, options: options) {
                    for (path, kind) in subKinds { remoteKinds[name + "/" + path] = kind }
                }
            }

            let plan = UploadPlanner.buildUploadPlan(roots: fileURLs,
                                                     targetDir: targetDir,
                                                     remoteKinds: remoteKinds)
            guard !plan.items.isEmpty else {
                showToast("没有可上传的内容", isError: true)
                return
            }
            let names = plan.items.map(\.name)
            let joined = names.prefix(3).joined(separator: "、")
            let summary = names.count > 3 ? "\(joined) 等 \(names.count) 项" : joined
            transferPrompt = TransferPrompt(plan: plan, message: "上传 \(summary)")
        } catch let error as SVNError {
            present(error: error)
        } catch {
            showError(ErrorBox(title: "上传准备失败", message: error.localizedDescription, detail: ""))
        }
    }

    // MARK: 库内拖拽移动

    func handleInternalMove(entries movingEntries: [SVNEntry], onto target: SVNEntry?) {
        guard let current = currentURL, !movingEntries.isEmpty else { return }
        guard let target, target.isDirectory else {
            showToast("请拖到某个文件夹上", isError: true)
            return
        }
        let targetDir = RemotePath.join(current, UploadPlanner.encodeComponent(target.name))
        Task { await prepareMove(entries: movingEntries, from: current, to: targetDir) }
    }

    private func prepareMove(entries movingEntries: [SVNEntry], from sourceDir: String,
                             to targetDir: String) async {
        busy = true
        busyMessage = "正在检查目标目录…"
        defer { busy = false }
        do {
            let options = options(for: targetDir)
            // 目标目录是子目录，内容必须现查（不能用当前目录的列表代替）
            let kinds = UploadPlanner.kindMap(in: try await SVNClient.shared.list(url: targetDir, options: options))
            let plan = UploadPlanner.buildMovePlan(entries: movingEntries,
                                                   from: sourceDir,
                                                   to: targetDir,
                                                   remoteKinds: kinds)
            let names = plan.items.map(\.name).prefix(3).joined(separator: "、")
            let summary = plan.items.count > 3 ? "\(names) 等 \(plan.items.count) 项" : names
            transferPrompt = TransferPrompt(plan: plan,
                                            message: "移动 \(summary) 到 \(RemotePath.prettyPath(targetDir))/")
        } catch let error as SVNError {
            present(error: error)
        } catch {
            showError(ErrorBox(title: "移动准备失败", message: error.localizedDescription, detail: ""))
        }
    }

    // MARK: 执行提交

    func confirmTransfer(_ prompt: TransferPrompt) {
        guard !prompt.plan.hasBlockers else {
            prompt.errorMessage = prompt.plan.mode == .move
                ? "目标目录已存在同名项，无法移动。"
                : "存在无法覆盖的同名项，请重命名后再上传。"
            return
        }
        guard !prompt.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            prompt.errorMessage = "请填写提交信息（commit message）"
            return
        }
        guard !prompt.plan.actions.isEmpty else {
            prompt.errorMessage = "没有需要提交的内容"
            return
        }
        prompt.inProgress = true
        prompt.errorMessage = nil
        let url = prompt.plan.targetDir
        let message = prompt.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let plan = prompt.plan
        Task {
            do {
                let revision = try await SVNClient.shared.commit(actions: plan.actions,
                                                                 message: message,
                                                                 options: options(for: url, timeout: 3600))
                self.transferPrompt = nil
                switch plan.mode {
                case .upload:
                    let count = plan.items.count
                    self.showToast("上传成功：\(count) 项，版本 r\(revision)")
                case .move:
                    self.showToast("移动成功，版本 r\(revision)")
                }
                await self.refreshAfterMutation(url: self.currentURL ?? url)
            } catch let error as SVNError {
                prompt.inProgress = false
                prompt.errorMessage = error.message
                prompt.showDetails = true
            } catch {
                prompt.inProgress = false
                prompt.errorMessage = error.localizedDescription
            }
        }
    }

    private func performCommit(prompt: InputPrompt, actions: [SVNMAction], message: String, success: String) async {
        guard let current = currentURL else { return }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            prompt.errorMessage = "请填写提交信息（commit message）"
            return
        }
        prompt.inProgress = true
        prompt.errorMessage = nil
        do {
            let revision = try await SVNClient.shared.commit(actions: actions, message: text,
                                                             options: options(for: current, timeout: 600))
            inputPrompt = nil
            showToast("\(success)，版本 r\(revision)")
            await refreshAfterMutation(url: current)
        } catch let error as SVNError {
            prompt.inProgress = false
            prompt.errorMessage = error.message + (error.code.map { "（\($0)）" } ?? "")
        } catch {
            prompt.inProgress = false
            prompt.errorMessage = error.localizedDescription
        }
    }

    private func refreshAfterMutation(url: String) async {
        if let current = currentURL, current == url {
            await load(url: url, allowPrompt: false)
        }
    }

    // MARK: 下载

    func download(entries targets: [SVNEntry]) {
        guard let current = currentURL, !targets.isEmpty else { return }
        if targets.count == 1, let entry = targets.first {
            saveSingle(entry: entry, from: current)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "下载到此处"
        panel.message = "选择保存 \(targets.count) 项的文件夹"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task {
            busy = true
            busyMessage = "正在下载 \(targets.count) 项…"
            defer { busy = false }
            var finished = 0
            var failures: [String] = []
            for entry in targets {
                let remote = RemotePath.join(current, UploadPlanner.encodeComponent(entry.name))
                let destination = directory.appendingPathComponent(entry.name)
                do {
                    try await SVNClient.shared.export(url: remote, to: destination, options: options(for: current))
                    finished += 1
                } catch {
                    failures.append(entry.name)
                }
            }
            if failures.isEmpty {
                showToast("已下载 \(finished) 项到 \(directory.lastPathComponent)")
            } else {
                showToast("\(finished) 项完成，\(failures.count) 项失败：\(failures.prefix(3).joined(separator: "、"))", isError: true)
            }
        }
    }

    private func saveSingle(entry: SVNEntry, from base: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.isDirectory ? entry.name + ".zip" : entry.name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let remote = RemotePath.join(base, UploadPlanner.encodeComponent(entry.name))
        Task {
            busy = true
            busyMessage = "正在下载 \(entry.name)…"
            defer { busy = false }
            do {
                try await SVNClient.shared.export(url: remote, to: destination, options: options(for: base))
                showToast("已下载到 \(destination.lastPathComponent)")
            } catch let error as SVNError {
                present(error: error)
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    /// 双击文件：导出到临时目录并交给系统默认程序打开
    private func downloadAndOpen(entry: SVNEntry, remoteURL: String) {
        if let cached = openFileCache[remoteURL], FileManager.default.fileExists(atPath: cached.path) {
            NSWorkspace.shared.open(cached)
            return
        }
        Task {
            busy = true
            busyMessage = "正在打开 \(entry.name)…"
            defer { busy = false }
            let cacheDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacSVN-open", isDirectory: true)
            let destination = cacheDir.appendingPathComponent(entry.name)
            do {
                try await SVNClient.shared.export(url: remoteURL, to: destination,
                                                  options: options(for: remoteURL))
                openFileCache[remoteURL] = destination
                NSWorkspace.shared.open(destination)
            } catch let error as SVNError {
                present(error: error)
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    // MARK: 设置 SVN 路径

    func beginSetSVNPath() {
        let current = UserDefaults.standard.string(forKey: SVNClient.toolDirectoryDefaultsKey) ?? ""
        let prompt = InputPrompt(kind: .svnPath,
                                 title: "设置 SVN 命令目录",
                                 fieldLabel: "目录路径",
                                 initialText: current,
                                 note: svnVersion.map { "当前 svn 版本：\($0)" } ?? "当前未检测到 svn 命令",
                                 confirmTitle: "保存",
                                 showsMessageField: false)
        prompt.validate = { text in
            let path = (text as NSString).expandingTildeInPath
            guard !path.isEmpty else { return "请输入目录路径" }
            let binary = (path as NSString).appendingPathComponent("svn")
            if !FileManager.default.isExecutableFile(atPath: binary) {
                return "该目录下没有可执行的 svn"
            }
            return nil
        }
        prompt.onSubmit = { [weak self] text, _ in
            let path = (text as NSString).expandingTildeInPath
            UserDefaults.standard.set(path, forKey: SVNClient.toolDirectoryDefaultsKey)
            SVNClient.shared.resetToolPaths()
            self?.refreshEnvironment()
            self?.inputPrompt = nil
            self?.showToast("已更新 SVN 路径")
        }
        inputPrompt = prompt
    }

    // MARK: 提示

    private func debugLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["MACSVN_DEBUG"] != nil else { return }
        FileHandle.standardError.write(Data("[MacSVN] \(message)\n".utf8))
    }

    func showToast(_ text: String, isError: Bool = false) {
        toast = Toast(text: text, isError: isError)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_600_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.toast = nil }
        }
    }

    private func showError(_ box: ErrorBox) {
        errorBox = box
    }

    private func present(error: SVNError) {
        lastError = error
        showError(ErrorBox(title: errorTitle(for: error.kind),
                           message: error.message,
                           detail: error.detail,
                           offersInstall: error.kind == .toolMissing))
    }

    private func errorTitle(for kind: SVNErrorKind) -> String {
        switch kind {
        case .notFound: return "路径不存在"
        case .connection: return "连接失败"
        case .conflict: return "存在冲突"
        case .authFailed, .authRequired: return "需要登录"
        case .certificate: return "证书错误"
        case .toolMissing: return "缺少 svn 命令"
        case .timeout: return "操作超时"
        case .cancelled: return "已取消"
        case .general: return "操作失败"
        }
    }

    func toggleSort(column: String) {
        sort(by: column)
    }

    private func addRecent(_ url: String) {
        guard recents.first != url else { return }
        recents.removeAll { $0 == url }
        recents.insert(url, at: 0)
        if recents.count > 15 { recents.removeLast(recents.count - 15) }
        UserDefaults.standard.set(recents, forKey: Self.recentsKey)
    }

    func forgetRecents() {
        recents = []
        UserDefaults.standard.removeObject(forKey: Self.recentsKey)
    }
}
