import AppKit
import Foundation

/// 通过 Homebrew 帮用户安装 Subversion。
/// 应用本身不打包 svn，而是在缺少时调用 brew 安装（这是 macOS 上最常见的来源）。
enum HomebrewInstaller {

    // MARK: 定位

    static func locateBrew() -> String? {
        // 自检用：模拟本机没有 Homebrew
        if ProcessInfo.processInfo.environment["MACSVN_TEST_NO_BREW"] != nil { return nil }
        var directories: [String] = []
        if let custom = UserDefaults.standard.string(forKey: SVNClient.toolDirectoryDefaultsKey), !custom.isEmpty {
            directories.append((custom as NSString).expandingTildeInPath)
        }
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/home/linuxbrew/.linuxbrew/bin"]
        let fm = FileManager.default
        for directory in directories {
            let candidate = (directory as NSString).appendingPathComponent("brew")
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        // 从登录 shell 里再找一次
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v brew"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let path = String(data: data, encoding: .utf8)?
                  .split(separator: "\n").first.map(String.init)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              FileManager.default.isExecutableFile(atPath: path)
        else { return nil }
        return path
    }

    static func brewVersion() -> String? {
        guard let brew = locateBrew() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").first.map(String.init)
    }

    static func isFormulaInstalled(_ formula: String) -> Bool {
        guard let brew = locateBrew() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["list", formula]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: 命令文本（用于复制/终端回退）

    static let homebrewInstallCommand =
        "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""

    static let subversionInstallCommand = "brew install subversion"

    /// Apple 芯片上新装 Homebrew 后需要把 brew 加进 PATH
    static let homebrewShellenvHint =
        "eval \"$(/opt/homebrew/bin/brew shellenv)\""

    // MARK: 在终端里执行（需要管理员密码等交互时使用）

    /// 生成 .command 脚本文件（可单独测试），再由 openInTerminal 交给终端执行
    @discardableResult
    static func makeCommandFile(title: String, script: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSVN", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = title.replacingOccurrences(of: "/", with: "-")
        let url = directory.appendingPathComponent("\(safeName).command")
        let body = """
        #!/bin/bash
        # 由 MacSVN 生成：\(title)
        clear
        echo "== \(title) =="
        echo
        \(script)
        status=$?
        echo
        if [ $status -eq 0 ]; then
            echo "== 完成，回到 MacSVN 点「重新检测」即可 =="
        else
            echo "== 命令失败（退出码 $status），请把上面的信息发给管理员 =="
        fi
        echo
        read -n 1 -s -r -p "按任意键关闭此窗口…"
        echo
        """
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// 写脚本并用默认终端打开；不申请「控制终端」的自动化权限
    @discardableResult
    static func openInTerminal(title: String, script: String) throws -> URL {
        let url = try makeCommandFile(title: title, script: script)
        NSWorkspace.shared.open(url)
        return url
    }

    /// 安装 Homebrew 的完整终端脚本（含 Apple 芯片的 PATH 处理与随后的 subversion 安装）
    static func installHomebrewScript() -> String {
        var lines = [homebrewInstallCommand, ""]
        lines.append("# Apple 芯片需要把 brew 加进 PATH：")
        lines.append("if [ -x /opt/homebrew/bin/brew ]; then")
        lines.append("    eval \"$(/opt/homebrew/bin/brew shellenv)\"")
        lines.append("    grep -q 'brew shellenv' ~/.zprofile 2>/dev/null || echo 'eval \"$(/opt/homebrew/bin/brew shellenv)\"' >> ~/.zprofile")
        lines.append("fi")
        lines.append(subversionInstallCommand)
        return lines.joined(separator: "\n")
    }

    // MARK: 执行 brew

    /// 流式执行 `brew install <formula>`，逐行回调输出
    final class Runner {
        private let lock = NSLock()
        private var buffer = ""
        private var process: Process?

        /// - Parameter onLine: 在主线程回调每一行输出
        func install(formula: String,
                     onLine: @escaping (String) -> Void,
                     onFinish: @escaping (Result<Int32, Error>) -> Void) {
            guard let brew = HomebrewInstaller.locateBrew() else {
                onFinish(.failure(SVNError(kind: .toolMissing,
                                           message: "未找到 brew 命令，请先安装 Homebrew")))
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: brew)
            process.arguments = ["install", formula]
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            process.environment = Self.childEnvironment(brewPath: brew)
            process.standardInput = FileHandle.nullDevice

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                guard let self else { return }
                for line in self.consume(String(decoding: data, as: UTF8.self)) {
                    DispatchQueue.main.async { onLine(line) }
                }
            }

            self.process = process
            process.terminationHandler = { [weak self] finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                var tail: [String] = []
                if let self { tail = self.consume(self.flushBuffer()) }
                DispatchQueue.main.async {
                    for line in tail { onLine(line) }
                    if finished.terminationReason == .uncaughtSignal {
                        onFinish(.failure(SVNError(kind: .cancelled, message: "安装已中断")))
                    } else {
                        onFinish(.success(finished.terminationStatus))
                    }
                }
            }

            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                onFinish(.failure(SVNError(kind: .general,
                                           message: "无法执行 brew：\(error.localizedDescription)")))
            }
        }

        func cancel() {
            process?.terminate()
        }

        var isRunning: Bool { process?.isRunning ?? false }

        private func flushBuffer() -> String {
            lock.lock()
            defer { lock.unlock() }
            let rest = buffer
            buffer = ""
            return rest
        }

        /// 按 \n 与 \r 切行（brew 的进度行用 \r 原地刷新），并去掉 ANSI 颜色码
        private func consume(_ text: String) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            buffer += text
            var lines: [String] = []
            while let index = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                let raw = String(buffer[buffer.startIndex..<index])
                buffer = String(buffer[buffer.index(after: index)...])
                let line = Self.stripANSI(raw).trimmingCharacters(in: .whitespaces)
                if !line.isEmpty { lines.append(line) }
            }
            if buffer.count > 8192 {
                buffer = String(buffer.suffix(2048))
            }
            return lines
        }

        private static func stripANSI(_ text: String) -> String {
            text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]",
                                      with: "",
                                      options: .regularExpression)
        }

        private static func childEnvironment(brewPath: String) -> [String: String] {
            var env = ProcessInfo.processInfo.environment
            let brewDirectory = (brewPath as NSString).deletingLastPathComponent
            env["PATH"] = ([brewDirectory, "/opt/homebrew/bin", "/usr/local/bin",
                            "/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
            env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"     // 安装过程不要顺带做全量更新
            env["HOMEBREW_NO_ENV_HINTS"] = "1"
            env["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
            env["LANG"] = "en_US.UTF-8"
            env["LC_ALL"] = "en_US.UTF-8"
            return env
        }
    }
}
