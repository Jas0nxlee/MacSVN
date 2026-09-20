import Foundation

/// 调用命令行 svn / svnmucc 完成所有仓库操作。
/// 所有方法都是可重入的，可以在任意线程调用。
final class SVNClient {
    static let shared = SVNClient()

    enum Tool: String {
        case svn
        case svnmucc
    }

    struct Options {
        var credentials: Credentials?
        var trustCertificate = false
        var timeout: TimeInterval = 300
    }

    struct RunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        var ok: Bool { status == 0 }
    }

    // MARK: 可执行文件定位

    private var resolvedPaths: [String: String] = [:]
    private let stateLock = NSLock()
    private var running: [(process: Process, state: RunState)] = []

    /// 供“设置 SVN 路径”使用
    static let toolDirectoryDefaultsKey = "SVNToolDirectory"

    func toolPath(_ tool: Tool) throws -> String {
        stateLock.lock()
        if let cached = resolvedPaths[tool.rawValue] {
            stateLock.unlock()
            return cached
        }
        stateLock.unlock()

        if let found = Self.locate(tool.rawValue) {
            stateLock.lock()
            resolvedPaths[tool.rawValue] = found
            stateLock.unlock()
            return found
        }
        throw SVNError(
            kind: .toolMissing,
            message: String(format: NSLocalizedString("The %@ command was not found. Install Subversion (for example “brew install subversion”), or set its folder in “MacSVN › Set SVN Path…”.", comment: ""), tool.rawValue),
            raw: ""
        )
    }

    func resetToolPaths() {
        stateLock.lock()
        resolvedPaths.removeAll()
        stateLock.unlock()
    }

    static func locate(_ name: String) -> String? {
        // 自检用：模拟本机没有装 Subversion
        if ProcessInfo.processInfo.environment["MACSVN_TEST_NO_SVN"] != nil { return nil }
        var directories: [String] = []
        if let custom = UserDefaults.standard.string(forKey: toolDirectoryDefaultsKey), !custom.isEmpty {
            directories.append((custom as NSString).expandingTildeInPath)
        }
        directories += [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "/usr/bin",
            "/bin",
            "/sw/bin",
        ]
        let fm = FileManager.default
        for dir in directories {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        // 从登录 shell 的 PATH 里再找一次（GUI 启动时 PATH 很干净）
        if let fromShell = lookupViaLoginShell(name) { return fromShell }
        return nil
    }

    private static func lookupViaLoginShell(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?
                  .split(separator: "\n").first.map(String.init),
              !text.isEmpty
        else { return nil }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// 返回 nil 表示环境正常；否则返回给用户看的提示
    func environmentProblem() -> String? {
        do {
            _ = try toolPath(.svn)
        } catch let error as SVNError {
            return error.message
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    func svnVersion() -> String? {
        guard let path = try? toolPath(.svn), let result = runSync(path: path, args: ["--version", "--quiet"]) else {
            return nil
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 进程执行

    private func runSync(path: String, args: [String]) -> RunResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RunResult(status: process.terminationStatus,
                         stdout: String(data: data, encoding: .utf8) ?? "",
                         stderr: "")
    }

    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var timedOut = false
        private var cancelled = false
        func markTimedOut() { lock.lock(); timedOut = true; lock.unlock() }
        func markCancelled() { lock.lock(); cancelled = true; lock.unlock() }
        var isTimedOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    /// 同步登记/注销运行中的进程，避免在 async 上下文里直接用 NSLock
    private func register(_ process: Process, state: RunState) {
        stateLock.lock()
        running.append((process, state))
        stateLock.unlock()
    }

    private func unregister(_ process: Process) {
        stateLock.lock()
        running.removeAll { $0.process === process }
        stateLock.unlock()
    }

    /// 执行一个子进程，stdout/stderr 落到临时文件，避免管道缓冲区死锁
    private func execute(tool: Tool, args: [String], password: String?, timeout: TimeInterval) async throws -> RunResult {
        let binary = try toolPath(tool)
        let tmpDir = FileManager.default.temporaryDirectory
        let stamp = UUID().uuidString
        let outURL = tmpDir.appendingPathComponent("macsvn-\(stamp).out")
        let errURL = tmpDir.appendingPathComponent("macsvn-\(stamp).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardOutput = try FileHandle(forWritingTo: outURL)
        process.standardError = try FileHandle(forWritingTo: errURL)
        process.standardInput = FileHandle.nullDevice
        process.environment = Self.childEnvironment(binaryPath: binary)

        var inputPipe: Pipe?
        if password != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inputPipe = pipe
        }

        let runState = RunState()
        register(process, state: runState)

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { [weak self] proc in
                self?.unregister(proc)

                let stdout = Self.readFile(outURL)
                let stderr = Self.readFile(errURL)
                try? FileManager.default.removeItem(at: outURL)
                try? FileManager.default.removeItem(at: errURL)

                let result = RunResult(status: proc.terminationStatus, stdout: stdout, stderr: stderr)
                if runState.isCancelled {
                    continuation.resume(throwing: SVNError(kind: .cancelled, message: NSLocalizedString("Operation cancelled", comment: ""), raw: stderr))
                } else if runState.isTimedOut {
                    continuation.resume(throwing: SVNError(kind: .timeout, message: String(format: NSLocalizedString("Timed out after %lds and was aborted", comment: ""), Int(timeout)), raw: stderr))
                } else if proc.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: SVNError(kind: .general, message: NSLocalizedString("The svn process was interrupted", comment: ""), raw: stderr))
                } else {
                    continuation.resume(returning: result)
                }
            }

            do {
                try process.run()
            } catch {
                try? FileManager.default.removeItem(at: outURL)
                try? FileManager.default.removeItem(at: errURL)
                continuation.resume(throwing: SVNError(kind: .toolMissing,
                                                       message: String(format: NSLocalizedString("Cannot run %@: %@", comment: ""), binary, error.localizedDescription)))
                return
            }

            if let inputPipe, let password {
                inputPipe.fileHandleForWriting.write(Data((password + "\n").utf8))
                try? inputPipe.fileHandleForWriting.close()
            }

            if timeout > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        runState.markTimedOut()
                        process.terminate()
                    }
                }
            }
        }
    }

    private static func readFile(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    private static func childEnvironment(binaryPath: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let binaryDir = (binaryPath as NSString).deletingLastPathComponent
        var pathParts = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin", binaryDir]
        if let existing = env["PATH"] {
            pathParts += existing.split(separator: ":").map(String.init)
        }
        var seen = Set<String>()
        env["PATH"] = pathParts.filter { seen.insert($0).inserted }.joined(separator: ":")
        // 固定英文提示，便于按错误码判断（同时保证 UTF-8 文件名正常）
        env["LC_ALL"] = "en_US.UTF-8"
        env["LANG"] = "en_US.UTF-8"
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        return env
    }

    func cancelAll() {
        stateLock.lock()
        let items = running
        stateLock.unlock()
        for item in items where item.process.isRunning {
            item.state.markCancelled()
            item.process.terminate()
        }
    }

    // MARK: 参数组装

    private func commonArguments(_ options: Options) -> [String] {
        var args = ["--non-interactive", "--no-auth-cache"]
        if let credentials = options.credentials {
            args += ["--username", credentials.username, "--password-from-stdin"]
        }
        if options.trustCertificate {
            args += ["--trust-server-cert-failures=unknown-ca,cn-mismatch,expired,not-yet-valid,other"]
        }
        return args
    }

    private func check(_ result: RunResult, options: Options) throws -> RunResult {
        guard result.ok else {
            throw SVNError.classify(stderr: result.stderr,
                                    stdout: result.stdout,
                                    hadCredentials: options.credentials != nil)
        }
        return result
    }

    private func call(_ tool: Tool, _ args: [String], options: Options) async throws -> RunResult {
        let result = try await execute(tool: tool,
                                       args: args + commonArguments(options),
                                       password: options.credentials?.password,
                                       timeout: options.timeout)
        return try check(result, options: options)
    }

    // MARK: 读取操作

    func list(url: String, options: Options = Options()) async throws -> [SVNEntry] {
        let result = try await call(.svn, ["list", "--xml", url], options: options)
        return try SVNListParser.parse(result.stdout, baseURL: url)
    }

    /// 递归列出子树中的全部路径（相对 URL），用于重名检测
    /// 同步版本，仅供隐藏的 --render-ui 渲染模式使用
    func listSync(url: String, options: Options = Options()) throws -> [SVNEntry] {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<[SVNEntry], Error> = .failure(SVNError(kind: .general, message: NSLocalizedString("Not executed", comment: "")))
        Task.detached {
            do {
                outcome = .success(try await self.list(url: url, options: options))
            } catch {
                outcome = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try outcome.get()
    }

    /// 递归列出子树的路径与类型（相对 URL），用于重名检测
    func listRecursiveKinds(url: String, options: Options = Options()) async throws -> [String: RemoteKind] {
        let result = try await call(.svn, ["list", "-R", "--xml", url], options: options)
        let entries = try SVNListParser.parse(result.stdout, baseURL: url)
        var map: [String: RemoteKind] = [:]
        for entry in entries {
            map[entry.name] = entry.isDirectory ? .directory : .file
        }
        return map
    }

    func info(url: String, options: Options = Options()) async throws -> RepositoryInfo {
        let result = try await call(.svn, ["info", "--xml", url], options: options)
        return try SVNInfoParser.parse(result.stdout)
    }

    func export(url: String, to destination: URL, options: Options = Options()) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try? fm.removeItem(at: destination)
        }
        try? fm.createDirectory(at: destination.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        _ = try await call(.svn, ["export", "--force", "--quiet", url, destination.path], options: options)
    }

    // MARK: 写操作（svnmucc 一次提交可包含多个动作）

    func commit(actions: [SVNMAction], message: String, options: Options = Options()) async throws -> Int {
        guard !actions.isEmpty else {
            throw SVNError(kind: .general, message: NSLocalizedString("There is nothing to commit", comment: ""))
        }
        var lastRevision = 0
        // 单次命令行不宜过长，分批提交
        let chunkSize = 300
        var index = 0
        while index < actions.count {
            let chunk = Array(actions[index..<min(index + chunkSize, actions.count)])
            index += chunkSize
            var args: [String] = ["-m", message]
            for action in chunk {
                switch action {
                case .mkdir(let remote):
                    args += ["mkdir", remote]
                case .move(let from, let to):
                    args += ["mv", from, to]
                case .remove(let remote):
                    args += ["rm", remote]
                case .put(let local, let remote):
                    args += ["put", local.path, remote]
                }
            }
            let result = try await call(.svnmucc, args, options: options)
            lastRevision = Self.parseRevision(result.stdout + "\n" + result.stderr) ?? lastRevision
        }
        return lastRevision
    }

    static func parseRevision(_ text: String) -> Int? {
        let patterns = ["committed revision (\\d+)", "r(\\d+) committed", "Committed revision (\\d+)"]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: text) {
                return Int(text[range])
            }
        }
        return nil
    }
}

// MARK: - XML 解析

enum SVNListParser {
    static func parse(_ xml: String, baseURL: String) throws -> [SVNEntry] {
        guard let data = xml.data(using: .utf8) else {
            throw SVNError(kind: .general, message: NSLocalizedString("Cannot parse the repository response", comment: ""))
        }
        let delegate = ListDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw SVNError(kind: .general, message: NSLocalizedString("Failed to parse the directory listing", comment: ""),
                           raw: parser.parserError?.localizedDescription ?? "")
        }
        return delegate.entries
    }

    private final class ListDelegate: NSObject, XMLParserDelegate {
        var entries: [SVNEntry] = []
        private var currentElement = ""
        private var text = ""
        private var name = ""
        private var kind = "file"
        private var size: Int64?
        private var revision: Int?
        private var author: String?
        private var date: Date?
        private var depth = 0

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            currentElement = elementName
            text = ""
            switch elementName {
            case "entry":
                depth += 1
                name = ""
                kind = attributes["kind"] ?? "file"
                size = nil
                revision = nil
                author = nil
                date = nil
            case "commit":
                if let value = attributes["revision"] { revision = Int(value) }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "name":
                name = value
            case "size":
                size = Int64(value)
            case "author":
                author = value
            case "date":
                date = Toolkit.parseSvnDate(value)
            case "entry":
                depth -= 1
                if !name.isEmpty {
                    entries.append(SVNEntry(name: name,
                                            isDirectory: kind == "dir",
                                            size: size,
                                            revision: revision,
                                            author: author,
                                            date: date))
                }
            default:
                break
            }
            text = ""
        }
    }
}

enum SVNInfoParser {
    static func parse(_ xml: String) throws -> RepositoryInfo {
        guard let data = xml.data(using: .utf8) else {
            throw SVNError(kind: .general, message: NSLocalizedString("Cannot parse repository information", comment: ""))
        }
        let delegate = InfoDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let info = delegate.info else {
            throw SVNError(kind: .general, message: NSLocalizedString("Failed to parse repository information", comment: ""),
                           raw: parser.parserError?.localizedDescription ?? "")
        }
        return info
    }

    private final class InfoDelegate: NSObject, XMLParserDelegate {
        var info: RepositoryInfo?
        private var currentElement = ""
        private var text = ""
        private var url = ""
        private var root = ""
        private var uuid = ""
        private var revision: Int?
        private var author: String?
        private var date: Date?

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            currentElement = elementName
            text = ""
            if elementName == "commit", let value = attributes["revision"] {
                revision = Int(value)
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "url": url = value
            case "root": root = value
            case "uuid": uuid = value
            case "author": author = value
            case "date": date = Toolkit.parseSvnDate(value)
            case "entry":
                info = RepositoryInfo(url: url, root: root, uuid: uuid,
                                      revision: revision, lastAuthor: author, lastDate: date)
            default:
                break
            }
            text = ""
        }
    }
}
