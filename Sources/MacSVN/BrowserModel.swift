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
    /// 该服务器已保存的登录信息到期时间（用于提示，可为空）
    var savedLoginExpiry: Date?
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
         note: String? = nil, confirmTitle: String = NSLocalizedString("OK", comment: ""), showsMessageField: Bool = true,
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

/// 「复制到…」的目标选择框
final class CopyPrompt: ObservableObject, Identifiable {
    let id = UUID()
    let items: [SVNEntry]
    let sourceDir: String
    @Published var currentDir: String
    @Published var folders: [SVNEntry] = []
    @Published var isLoading = false
    @Published var loadError: String?
    @Published var isCopying = false
    @Published var submitError: String?
    /// 目标目录里已有的名字（用于重名判断）
    @Published var existingNames: Set<String> = []
    /// 复制为的名称（只对单个条目开放改名）
    @Published var newName: String

    init(items: [SVNEntry], sourceDir: String, startDir: String) {
        self.items = items
        self.sourceDir = sourceDir
        self.currentDir = startDir
        self.newName = items.first?.name ?? ""
    }

    /// 只有单个条目时才允许改名
    var allowsRenaming: Bool { items.count == 1 }

    var destinationName: String? { allowsRenaming ? newName : nil }

    var finalName: String {
        allowsRenaming ? newName.trimmingCharacters(in: .whitespacesAndNewlines) : (items.first?.name ?? "")
    }

    /// 改名后要立刻重新校验，所以做成计算属性
    var blockers: [TransferBlocker] {
        guard loadError == nil else { return [] }
        return UploadPlanner.validateCopyDestination(items: items,
                                                     sourceDir: sourceDir,
                                                     destination: currentDir,
                                                     existingNames: existingNames,
                                                     newName: destinationName)
    }

    /// 目录没加载成功（不存在 / 无权限 / 网络失败）时也不能复制
    var canCopy: Bool { !isLoading && !isCopying && blockers.isEmpty && loadError == nil }
    var isDestinationUsable: Bool { loadError == nil && blockers.isEmpty }
    var summary: String {
        let names = items.map(\.name).prefix(3).joined(separator: NSLocalizedString(", ", comment: ""))
        return items.count > 3
            ? String(format: NSLocalizedString("%@ and %ld items total", comment: ""), names, items.count)
            : names
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
    @Published private(set) var loadingMessage = NSLocalizedString("Opening…", comment: "")
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
    @Published var copyPrompt: CopyPrompt?

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
            showToast(String(format: NSLocalizedString("Subversion %@ is ready", comment: ""), version))
        } else if brewPath == nil {
            showToast(NSLocalizedString("svn still not found, and Homebrew is missing too — install Homebrew first", comment: ""), isError: true)
        } else {
            showToast(NSLocalizedString("svn command still not found", comment: ""), isError: true)
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
        prompt.append(String(format: NSLocalizedString("Running %@ install subversion", comment: ""), brewPath ?? "brew"))
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
                    prompt.append(String(format: NSLocalizedString("✓ Subversion %@ is ready", comment: ""), version))
                    self.showToast(String(format: NSLocalizedString("Subversion %@ installed", comment: ""), version))
                } else {
                    prompt.phase = .failed(NSLocalizedString("The install command finished but svn is still missing. It may have been installed elsewhere — use “Set SVN Path…”.", comment: ""))
                }
            case .success(let status):
                prompt.phase = .failed(String(format: NSLocalizedString("brew exited with status %ld; the installation failed.", comment: ""), status))
            case .failure(let error):
                if let svnError = error as? SVNError, svnError.kind == .cancelled {
                    prompt.phase = .cancelled
                    prompt.append(NSLocalizedString("Installation cancelled.", comment: ""))
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
            try HomebrewInstaller.openInTerminal(title: NSLocalizedString("Install Homebrew", comment: ""), script: script)
            showToast(NSLocalizedString("The installer is running in Terminal; click “Re-check” when it finishes", comment: ""))
        } catch {
            showError(ErrorBox(title: NSLocalizedString("Cannot open Terminal", comment: ""),
                               message: error.localizedDescription,
                               detail: HomebrewInstaller.homebrewInstallCommand))
        }
    }

    /// 不走 brew 进程，直接在终端里手动安装（给权限异常等情况留后路）
    func installInTerminal() {
        do {
            try HomebrewInstaller.openInTerminal(title: NSLocalizedString("Install Subversion", comment: ""),
                                                 script: "brew install subversion")
            showToast(NSLocalizedString("Running brew install subversion in Terminal; click “Re-check” when it finishes", comment: ""))
        } catch {
            showError(ErrorBox(title: NSLocalizedString("Cannot open Terminal", comment: ""),
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
        showToast(NSLocalizedString("Install command copied to the clipboard", comment: ""))
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
            showError(ErrorBox(title: NSLocalizedString("Invalid address", comment: ""), message: error ?? NSLocalizedString("Cannot parse the address", comment: ""), detail: input))
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
        loadingMessage = String(format: NSLocalizedString("Opening %@…", comment: ""), RemotePath.prettyPath(url))
        defer { isLoading = false }

        do {
            let list = try await SVNClient.shared.list(url: url, options: options(for: url))
            currentURL = url
            addressText = RemotePath.display(url)
            entries = sortEntries(list)
            selection = []
            repoInfo = nil
            lastError = nil
            statusText = String(format: NSLocalizedString("%ld items", comment: ""), entries.count)
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
            showError(ErrorBox(title: NSLocalizedString("Could not open", comment: ""), message: error.localizedDescription, detail: ""))
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
                                 remember: true,
                                 needsTrust: error.kind == .certificate)
        if let stored { prompt.password = stored.password }
        prompt.savedLoginExpiry = CredentialStore.expiration(for: key)
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
            prompt.errorMessage = NSLocalizedString("Enter a user name", comment: "")
            return
        }
        let credentials = Credentials(username: username, password: prompt.password)
        sessionCredentials[prompt.hostKey] = credentials
        if prompt.trustCertificate {
            trustedHosts.insert(prompt.hostKey)
        }
        loginPrompt = nil

        Task {
            await load(url: prompt.url, allowPrompt: false)

            // 凭据被拒绝时：不要保存，继续让用户修正
            if let lastError, lastError.kind.needsCredentialPrompt {
                self.lastError = nil
                errorBox = nil
                if prompt.remember {
                    CredentialStore.delete(for: prompt.hostKey)
                }
                // 等上一个 sheet 的关闭动画结束，否则新的 sheet 会被系统忽略
                try? await Task.sleep(nanoseconds: 420_000_000)
                presentLogin(for: prompt.url, error: lastError, prefillError: lastError.message)
                return
            }

            // 验证成功后再按用户选择保存（默认记住 1 个月）
            if prompt.remember {
                CredentialStore.save(credentials, for: prompt.hostKey)
                let days = Int(CredentialStore.defaultLifetime / 86_400)
                showToast(String(format: NSLocalizedString("Login saved — no sign-in needed for %ld days", comment: ""), days))
            } else {
                CredentialStore.delete(for: prompt.hostKey)
            }
        }
    }

    private var lastError: SVNError?

    private func options(for url: String, timeout: TimeInterval = 300) -> SVNClient.Options {
        svnOptions(for: url, timeout: timeout)
    }

    /// 供文件列表在拖出时构造下载任务使用
    ///
    /// 会话里没有凭据时会去钥匙串取一次（未过期才返回），这样启动后第一次访问
    /// 就直接带上登录信息，不会再弹登录框。
    func svnOptions(for url: String, timeout: TimeInterval = 300) -> SVNClient.Options {
        let key = RemotePath.hostKey(url)
        if sessionCredentials[key] == nil, let stored = CredentialStore.load(for: key) {
            sessionCredentials[key] = stored
        }
        return SVNClient.Options(credentials: sessionCredentials[key],
                                 trustCertificate: trustedHosts.contains(key),
                                 timeout: timeout)
    }

    // MARK: 登录信息的状态与注销

    /// 当前地址对应的、仍未过期的登录信息
    func savedLogin(for url: String?) -> (username: String, expiresAt: Date)? {
        guard let url else { return nil }
        let key = RemotePath.hostKey(url)
        guard let stored = CredentialStore.loadStored(for: key), !stored.isExpired() else { return nil }
        return (stored.username, stored.expiresAt)
    }

    func forgetSavedLogin(for url: String?) {
        guard let url else {
            showToast(NSLocalizedString("No saved login for the current server", comment: ""), isError: true)
            return
        }
        CredentialStore.delete(for: RemotePath.hostKey(url))
        showToast(NSLocalizedString("Saved login removed", comment: ""))
    }

    /// 退出登录：清掉内存与钥匙串里的凭据，然后重新加载当前目录（通常会重新要求登录）
    func logOut() {
        guard let url = currentURL else {
            showToast(NSLocalizedString("Open a repository first", comment: ""), isError: true)
            return
        }
        let key = RemotePath.hostKey(url)
        let hadSaved = CredentialStore.loadStored(for: key) != nil
        sessionCredentials[key] = nil
        CredentialStore.delete(for: key)
        guard hadSaved else {
            showToast(NSLocalizedString("No saved login for the current server", comment: ""), isError: true)
            return
        }
        showToast(NSLocalizedString("Signed out — you will be asked again next time", comment: ""))
        Task { await load(url: url, allowPrompt: true) }
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
        self.environmentWarning = svnPath == nil ? NSLocalizedString("svn command not found", comment: "") : nil
    }

    /// 仅供隐藏的 --render-ui 渲染模式注入数据
    func applyForRender(url: String, entries: [SVNEntry]) {
        currentURL = url
        addressText = RemotePath.display(url)
        self.entries = sortEntries(entries)
        statusText = String(format: NSLocalizedString("%ld items", comment: ""), entries.count)
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
            showToast(NSLocalizedString("Select an item first", comment: ""), isError: true)
            return
        }
        let prompt = InputPrompt(kind: .rename,
                                 title: entry.isDirectory ? NSLocalizedString("Rename Folder", comment: "") : NSLocalizedString("Rename File", comment: ""),
                                 fieldLabel: NSLocalizedString("New name", comment: ""),
                                 initialText: entry.name,
                                 note: String(format: NSLocalizedString("in %@/", comment: ""), RemotePath.prettyPath(current)),
                                 confirmTitle: NSLocalizedString("Rename", comment: ""),
                                 message: String(format: NSLocalizedString("Rename %@", comment: ""), entry.name))
        prompt.validate = { [weak self] text in
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { return NSLocalizedString("Name cannot be empty", comment: "") }
            if name.contains("/") { return NSLocalizedString("Name cannot contain “/”", comment: "") }
            if name == "." || name == ".." { return NSLocalizedString("Invalid name", comment: "") }
            if name == entry.name { return NSLocalizedString("The name did not change", comment: "") }
            if self?.entries.contains(where: { $0.name == name }) == true { return NSLocalizedString("This folder already contains an item with that name", comment: "") }
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
                                         success: String(format: NSLocalizedString("Renamed to %@", comment: ""), name))
            }
        }
        inputPrompt = prompt
    }

    // MARK: 新建目录

    /// 新建文件夹；`targetDir` 为空时建在当前目录，传入地址则建在该目录下
    func beginNewFolder(in targetDir: String? = nil) {
        guard let current = targetDir ?? currentURL else { return }
        let isCurrent = current == currentURL
        let prompt = InputPrompt(kind: .newFolder,
                                 title: NSLocalizedString("New Folder", comment: ""),
                                 fieldLabel: NSLocalizedString("Folder name", comment: ""),
                                 initialText: "",
                                 note: String(format: NSLocalizedString("Will be created in %@/", comment: ""), RemotePath.prettyPath(current)),
                                 confirmTitle: NSLocalizedString("Create", comment: ""),
                                 message: NSLocalizedString("New folder", comment: ""))
        prompt.validate = { [weak self] text in
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { return NSLocalizedString("Name cannot be empty", comment: "") }
            if name.contains("/") { return NSLocalizedString("Name cannot contain “/”", comment: "") }
            if name == "." || name == ".." { return NSLocalizedString("Invalid name", comment: "") }
            // 只有建在当前目录时才能就地判断重名；其它目录交给服务端报错
            if isCurrent, self?.entries.contains(where: { $0.name == name }) == true {
                return NSLocalizedString("This folder already contains an item with that name", comment: "")
            }
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
                                         success: String(format: NSLocalizedString("Created folder %@", comment: ""), name))
            }
        }
        inputPrompt = prompt
    }

    // MARK: 删除

    func beginDelete() {
        guard let current = currentURL else { return }
        let targets = selectedEntries
        guard !targets.isEmpty else {
            showToast(NSLocalizedString("Select the items to delete first", comment: ""), isError: true)
            return
        }
        let summary = targets.count == 1 ? "“\(targets[0].name)”" : String(format: NSLocalizedString("%ld items", comment: ""), targets.count)
        deletePrompt = DeletePrompt(entries: targets, baseDir: current, message: String(format: NSLocalizedString("Delete %@", comment: ""), summary))
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
                                                                 message: prompt.message.isEmpty ? NSLocalizedString("Delete", comment: "") : prompt.message,
                                                                 options: options(for: prompt.baseDir, timeout: 600))
                self.deletePrompt = nil
                self.showToast(String(format: NSLocalizedString("Deleted (revision r%ld)", comment: ""), revision))
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
            showToast(NSLocalizedString("Only local files and folders can be dropped here", comment: ""), isError: true)
            return
        }
        busy = true
        busyMessage = NSLocalizedString("Checking the repository for same-named files…", comment: "")
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
                showToast(NSLocalizedString("Nothing to upload", comment: ""), isError: true)
                return
            }
            let names = plan.items.map(\.name)
            let joined = names.prefix(3).joined(separator: "、")
            let summary = names.count > 3 ? String(format: NSLocalizedString("%@ and %ld items total", comment: ""), joined, names.count) : joined
            transferPrompt = TransferPrompt(plan: plan, message: String(format: NSLocalizedString("Upload %@", comment: ""), summary))
        } catch let error as SVNError {
            present(error: error)
        } catch {
            showError(ErrorBox(title: NSLocalizedString("Upload preparation failed", comment: ""), message: error.localizedDescription, detail: ""))
        }
    }

    // MARK: 库内拖拽移动

    func handleInternalMove(entries movingEntries: [SVNEntry], onto target: SVNEntry?) {
        guard let current = currentURL, !movingEntries.isEmpty else { return }
        guard let target, target.isDirectory else {
            showToast(NSLocalizedString("Drop onto a folder", comment: ""), isError: true)
            return
        }
        let targetDir = RemotePath.join(current, UploadPlanner.encodeComponent(target.name))
        Task { await prepareMove(entries: movingEntries, from: current, to: targetDir) }
    }

    private func prepareMove(entries movingEntries: [SVNEntry], from sourceDir: String,
                             to targetDir: String) async {
        busy = true
        busyMessage = NSLocalizedString("Checking the target folder…", comment: "")
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
            let summary = plan.items.count > 3 ? String(format: NSLocalizedString("%@ and %ld items total", comment: ""), names, plan.items.count) : names
            transferPrompt = TransferPrompt(plan: plan,
                                            message: String(format: NSLocalizedString("Move %@ to %@/", comment: ""), summary, RemotePath.prettyPath(targetDir)))
        } catch let error as SVNError {
            present(error: error)
        } catch {
            showError(ErrorBox(title: NSLocalizedString("Move preparation failed", comment: ""), message: error.localizedDescription, detail: ""))
        }
    }

    // MARK: 执行提交

    func confirmTransfer(_ prompt: TransferPrompt) {
        guard !prompt.plan.hasBlockers else {
            prompt.errorMessage = prompt.plan.mode == .move
                ? NSLocalizedString("The target folder already contains an item with this name.", comment: "")
                : NSLocalizedString("Some items cannot be overwritten. Rename them and try again.", comment: "")
            return
        }
        guard !prompt.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            prompt.errorMessage = NSLocalizedString("Enter a commit message", comment: "")
            return
        }
        guard !prompt.plan.actions.isEmpty else {
            prompt.errorMessage = NSLocalizedString("There is nothing to commit", comment: "")
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
                    self.showToast(String(format: NSLocalizedString("Uploaded %ld items (revision r%ld)", comment: ""), count, revision))
                case .move:
                    self.showToast(String(format: NSLocalizedString("Moved (revision r%ld)", comment: ""), revision))
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
            prompt.errorMessage = NSLocalizedString("Enter a commit message", comment: "")
            return
        }
        prompt.inProgress = true
        prompt.errorMessage = nil
        do {
            let revision = try await SVNClient.shared.commit(actions: actions, message: text,
                                                             options: options(for: current, timeout: 600))
            inputPrompt = nil
            showToast(String(format: NSLocalizedString("%@ (revision r%ld)", comment: ""), success, revision))
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

    // MARK: 库内复制（服务端 cp，不经过本地）

    func beginCopy() {
        guard let current = currentURL else { return }
        let targets = selectedEntries
        guard !targets.isEmpty else {
            showToast(NSLocalizedString("Select an item first", comment: ""), isError: true)
            return
        }
        let prompt = CopyPrompt(items: targets, sourceDir: current, startDir: current)
        copyPrompt = prompt
        Task { await loadCopyListing(prompt, url: current) }
    }

    /// 在选择框里切换目录（面包屑、进入子目录、上一级都走这里）
    func navigateCopy(to url: String) {
        guard let prompt = copyPrompt else { return }
        Task { await loadCopyListing(prompt, url: url) }
    }

    private func loadCopyListing(_ prompt: CopyPrompt, url: String) async {
        prompt.isLoading = true
        prompt.loadError = nil
        do {
            let entries = try await SVNClient.shared.list(url: url, options: options(for: url))
            prompt.currentDir = url
            prompt.folders = entries
                .filter(\.isDirectory)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            prompt.existingNames = Set(entries.map(\.name))
        } catch let error as SVNError {
            prompt.folders = []
            prompt.existingNames = []
            prompt.loadError = error.message
        } catch {
            prompt.folders = []
            prompt.existingNames = []
            prompt.loadError = error.localizedDescription
        }
        prompt.isLoading = false
    }

    func confirmCopy(_ prompt: CopyPrompt) {
        guard prompt.blockers.isEmpty else {
            prompt.submitError = NSLocalizedString("This destination cannot be used. Pick another folder.", comment: "")
            return
        }
        let actions = prompt.items.map { item -> SVNMAction in
            let name = prompt.allowsRenaming ? prompt.finalName : item.name
            return SVNMAction.copy(from: RemotePath.join(prompt.sourceDir, UploadPlanner.encodeComponent(item.name)),
                                   to: RemotePath.join(prompt.currentDir, UploadPlanner.encodeComponent(name)))
        }
        guard !actions.isEmpty else { return }
        prompt.isCopying = true
        prompt.submitError = nil
        let destination = prompt.currentDir
        Task {
            do {
                let destinationPath = RemotePath.join(destination, UploadPlanner.encodeComponent(prompt.finalName))
                let message = prompt.allowsRenaming
                    ? String(format: NSLocalizedString("Copy %@ to %@", comment: ""),
                             prompt.items[0].name, RemotePath.prettyPath(destinationPath))
                    : String(format: NSLocalizedString("Copy %@ to %@", comment: ""),
                             prompt.items.map(\.name).joined(separator: NSLocalizedString(", ", comment: "")),
                             RemotePath.prettyPath(destination) + "/")
                _ = try await SVNClient.shared.commit(actions: actions,
                                                      message: message,
                                                      options: options(for: destination, timeout: 600))
                self.copyPrompt = nil
                self.showToast(prompt.allowsRenaming
                    ? String(format: NSLocalizedString("Copied %@ to %@", comment: ""),
                             prompt.items[0].name, RemotePath.prettyPath(destinationPath))
                    : String(format: NSLocalizedString("Copied %ld items to %@/", comment: ""),
                             prompt.items.count, RemotePath.prettyPath(destination)))
                if self.currentURL == destination {
                    await self.refreshAfterMutation(url: destination)
                }
            } catch let error as SVNError {
                prompt.isCopying = false
                prompt.submitError = error.message
            } catch {
                prompt.isCopying = false
                prompt.submitError = error.localizedDescription
            }
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
        panel.prompt = NSLocalizedString("Download Here", comment: "")
        panel.message = String(format: NSLocalizedString("Choose a folder to save %ld items", comment: ""), targets.count)
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task {
            busy = true
            busyMessage = String(format: NSLocalizedString("Downloading %ld items…", comment: ""), targets.count)
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
                showToast(String(format: NSLocalizedString("Downloaded %ld items to %@", comment: ""), finished, directory.lastPathComponent))
            } else {
                showToast(String(format: NSLocalizedString("%ld done, %ld failed: %@", comment: ""), finished, failures.count, failures.prefix(3).joined(separator: ", ")), isError: true)
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
            busyMessage = String(format: NSLocalizedString("Downloading %@…", comment: ""), entry.name)
            defer { busy = false }
            do {
                try await SVNClient.shared.export(url: remote, to: destination, options: options(for: base))
                showToast(String(format: NSLocalizedString("Downloaded to %@", comment: ""), destination.lastPathComponent))
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
            busyMessage = String(format: NSLocalizedString("Opening %@…", comment: ""), entry.name)
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
                                 title: NSLocalizedString("Set SVN Command Folder", comment: ""),
                                 fieldLabel: NSLocalizedString("Folder path", comment: ""),
                                 initialText: current,
                                 note: svnVersion.map { String(format: NSLocalizedString("Current svn version: %@", comment: ""), $0) } ?? NSLocalizedString("No svn command detected", comment: ""),
                                 confirmTitle: NSLocalizedString("Save", comment: ""),
                                 showsMessageField: false)
        prompt.validate = { text in
            let path = (text as NSString).expandingTildeInPath
            guard !path.isEmpty else { return NSLocalizedString("Enter a folder path", comment: "") }
            let binary = (path as NSString).appendingPathComponent("svn")
            if !FileManager.default.isExecutableFile(atPath: binary) {
                return NSLocalizedString("No executable svn in that folder", comment: "")
            }
            return nil
        }
        prompt.onSubmit = { [weak self] text, _ in
            let path = (text as NSString).expandingTildeInPath
            UserDefaults.standard.set(path, forKey: SVNClient.toolDirectoryDefaultsKey)
            SVNClient.shared.resetToolPaths()
            self?.refreshEnvironment()
            self?.inputPrompt = nil
            self?.showToast(NSLocalizedString("SVN path updated", comment: ""))
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
        case .notFound: return NSLocalizedString("Path not found", comment: "")
        case .connection: return NSLocalizedString("Connection failed", comment: "")
        case .conflict: return NSLocalizedString("Conflict", comment: "")
        case .authFailed, .authRequired: return NSLocalizedString("Sign-in required", comment: "")
        case .certificate: return NSLocalizedString("Certificate error", comment: "")
        case .toolMissing: return NSLocalizedString("svn command missing", comment: "")
        case .timeout: return NSLocalizedString("Timed out", comment: "")
        case .cancelled: return NSLocalizedString("Cancelled", comment: "")
        case .general: return NSLocalizedString("Operation failed", comment: "")
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
