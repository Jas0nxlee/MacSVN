import Foundation

/// 隐藏的自检模式：`MacSVN --selftest <仓库URL> [用户名] [密码]`
/// 对真实仓库跑一遍 上传 / 覆盖 / 重命名 / 删除 的完整流程，用于验证核心逻辑。
enum SelfTest {
    private static var failures = 0

    static func run(arguments: [String]) {
        guard let base = arguments.first else {
            print("用法: MacSVN --selftest <仓库URL> [用户名] [密码]")
            exit(2)
        }
        let credentials: Credentials? = arguments.count >= 3
            ? Credentials(username: arguments[1], password: arguments[2])
            : nil

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await execute(base: base, credentials: credentials)
            semaphore.signal()
        }
        semaphore.wait()
        print(failures == 0 ? "\n✅ 全部通过" : "\n❌ 失败 \(failures) 项")
        exit(failures == 0 ? 0 : 1)
    }

    /// 边界用例：类型冲突、特殊文件名、空目录、二进制、大批量分批提交
    private static func runEdgeCases(client: SVNClient, localRoot: URL, workDir: String,
                                     options: SVNClient.Options, stamp: String) async throws {
        let fm = FileManager.default

        print("→ 类型冲突：库中是目录，拖入同名文件")
        let conflictDir = RemotePath.join(workDir, "conflictDir")
        _ = try await client.commit(actions: [.mkdir(conflictDir)], message: "selftest: conflict dir", options: options)
        let fileNamedLikeDir = localRoot.appendingPathComponent("conflictDir")
        try "i am a file\n".write(to: fileNamedLikeDir, atomically: true, encoding: .utf8)
        let planA = UploadPlanner.buildUploadPlan(roots: [fileNamedLikeDir],
                                                  targetDir: workDir,
                                                  remoteKinds: ["conflictDir": .directory])
        check(planA.hasBlockers, "文件 vs 库中同名目录 → 判定为硬冲突")
        check(planA.actions.isEmpty, "不生成任何提交动作（实际 \(planA.actions.count) 个）")
        check(planA.blockers.first?.path == "conflictDir", "冲突项名称正确")

        print("→ 类型冲突：库中是文件，拖入同名目录")
        let remoteFile = RemotePath.join(workDir, "conflictFile")
        _ = try await client.commit(actions: [.put(local: fileNamedLikeDir, remote: remoteFile)],
                                    message: "selftest: conflict file", options: options)
        let dirNamedLikeFile = localRoot.appendingPathComponent("conflictFile", isDirectory: true)
        try fm.createDirectory(at: dirNamedLikeFile, withIntermediateDirectories: true)
        try "inside\n".write(to: dirNamedLikeFile.appendingPathComponent("inner.txt"),
                             atomically: true, encoding: .utf8)
        let planB = UploadPlanner.buildUploadPlan(roots: [dirNamedLikeFile],
                                                  targetDir: workDir,
                                                  remoteKinds: ["conflictFile": .file])
        check(planB.hasBlockers, "目录 vs 库中同名文件 → 判定为硬冲突")
        check(planB.actions.isEmpty, "冲突子树内不生成动作（实际 \(planB.actions.count) 个）")

        print("→ 特殊文件名（中文与空格）")
        let specialDir = localRoot.appendingPathComponent("子目录 含空格", isDirectory: true)
        try fm.createDirectory(at: specialDir, withIntermediateDirectories: true)
        let specialFile = specialDir.appendingPathComponent("说明 文档.txt")
        try "中文内容测试\n".write(to: specialFile, atomically: true, encoding: .utf8)
        let planC = UploadPlanner.buildUploadPlan(roots: [specialDir], targetDir: workDir, remoteKinds: [:])
        let encodedOK = planC.actions.contains {
            if case .put(_, let remote) = $0 { return remote.contains("%20") }
            return false
        }
        check(encodedOK, "远程路径已做百分号编码")
        _ = try await client.commit(actions: planC.actions, message: "selftest: special names", options: options)
        let listing = try await client.list(url: workDir, options: options)
        check(listing.contains { $0.name == "子目录 含空格" && $0.isDirectory }, "中文目录名正确入库")
        let specialRemote = RemotePath.join(workDir, "子目录 含空格/说明 文档.txt")
        let specialLocal = fm.temporaryDirectory.appendingPathComponent("macsvn-special-\(stamp).txt")
        try await client.export(url: specialRemote, to: specialLocal, options: options)
        check((try? String(contentsOf: specialLocal, encoding: .utf8))?.hasPrefix("中文内容") == true,
              "中文文件内容一致")

        print("→ 空目录")
        let emptyDir = localRoot.appendingPathComponent("empty-dir", isDirectory: true)
        try fm.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        let planD = UploadPlanner.buildUploadPlan(roots: [emptyDir], targetDir: workDir, remoteKinds: [:])
        check(planD.actions.count == 1, "空目录只生成 1 个 mkdir 动作，实际 \(planD.actions.count)")
        _ = try await client.commit(actions: planD.actions, message: "selftest: empty dir", options: options)
        let afterEmpty = try await client.list(url: workDir, options: options)
        check(afterEmpty.contains { $0.name == "empty-dir" && $0.isDirectory }, "空目录已入库")

        print("→ 二进制文件完整性")
        var blob = Data(count: 256 * 1024)
        blob.withUnsafeMutableBytes { buffer in
            for index in 0..<buffer.count { buffer[index] = UInt8((index &* 37 &+ 11) % 256) }
        }
        let blobURL = localRoot.appendingPathComponent("blob.bin")
        try blob.write(to: blobURL)
        let planE = UploadPlanner.buildUploadPlan(roots: [blobURL], targetDir: workDir, remoteKinds: [:])
        _ = try await client.commit(actions: planE.actions, message: "selftest: binary", options: options)
        let blobBack = fm.temporaryDirectory.appendingPathComponent("macsvn-blob-\(stamp).bin")
        try await client.export(url: RemotePath.join(workDir, "blob.bin"), to: blobBack, options: options)
        let roundTrip = try Data(contentsOf: blobBack)
        check(roundTrip == blob, "256KB 二进制内容往返一致（\(roundTrip.count) 字节）")

        print("→ 大批量上传（350 个文件，触发分批提交）")
        let big = localRoot.appendingPathComponent("big", isDirectory: true)
        try fm.createDirectory(at: big, withIntermediateDirectories: true)
        for index in 0..<350 {
            try "file \(index)\n".write(to: big.appendingPathComponent("f-\(index).txt"),
                                         atomically: true, encoding: .utf8)
        }
        let planF = UploadPlanner.buildUploadPlan(roots: [big], targetDir: workDir, remoteKinds: [:])
        check(planF.actions.count == 351, "1 个 mkdir + 350 个 put，实际 \(planF.actions.count)")
        let bigRevision = try await client.commit(actions: planF.actions, message: "selftest: bulk", options: options)
        check(bigRevision > 0, "分批提交完成，最后版本 r\(bigRevision)")
        let bigTree = try await client.listRecursiveKinds(url: RemotePath.join(workDir, "big"), options: options)
        check(bigTree.count == 350, "库中实际 350 个文件，实际 \(bigTree.count)")
        check(bigTree["f-349.txt"] == .file, "最后一个文件也在库中")
    }

    /// `MacSVN --selftest-brew [formula]`
    /// 真跑一遍 brew 安装流程，验证输出流式读取、退出码、装完后的重新检测。
    static func runBrew(arguments: [String]) {
        let formula = arguments.first ?? "subversion"
        print("→ Homebrew 检测")
        let brew = HomebrewInstaller.locateBrew()
        check(brew != nil, "找到 brew：\(brew ?? "无")")
        if let version = HomebrewInstaller.brewVersion() {
            check(true, "brew 版本：\(version)")
        } else {
            check(false, "无法获取 brew 版本")
        }

        print("→ 模拟本机没有 Homebrew 的分支")
        setenv("MACSVN_TEST_NO_BREW", "1", 1)
        check(HomebrewInstaller.locateBrew() == nil, "无 Homebrew 时 locateBrew 返回 nil")
        unsetenv("MACSVN_TEST_NO_BREW")
        check(HomebrewInstaller.locateBrew() != nil, "取消模拟后又能找到 brew")

        print("→ 终端安装脚本（不实际打开终端）")
        let homebrewScript = HomebrewInstaller.installHomebrewScript()
        check(homebrewScript.contains("install.sh"), "含 Homebrew 安装命令")
        check(homebrewScript.contains("brew install subversion"), "含 subversion 安装命令")
        check(homebrewScript.contains("brew shellenv"), "含 Apple 芯片 PATH 处理")
        if let url = try? HomebrewInstaller.makeCommandFile(title: "安装 Subversion 测试",
                                                            script: "echo hello") {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
            check(FileManager.default.fileExists(atPath: url.path), "生成 .command 文件：\(url.lastPathComponent)")
            check(permissions & 0o111 != 0, "脚本可执行（权限 \(String(permissions, radix: 8))）")
            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            check(content.contains("echo hello"), "脚本内容正确")
            check(content.hasPrefix("#!/bin/bash"), "带 shebang")
            try? FileManager.default.removeItem(at: url)
        } else {
            check(false, "生成 .command 文件失败")
        }

        let alreadyInstalled = HomebrewInstaller.isFormulaInstalled(formula)
        print("→ \(formula) 已安装：\(alreadyInstalled ? "是" : "否")")

        print("→ 执行 brew install \(formula)（流式输出）")
        let runner = HomebrewInstaller.Runner()
        var lineCount = 0
        var finished = false
        var reported: Result<Int32, Error>?

        runner.install(formula: formula) { line in
            lineCount += 1
            if lineCount <= 40 { print("  │ \(line)") }
        } onFinish: { result in
            reported = result
            finished = true
        }

        let deadline = Date().addingTimeInterval(300)
        while !finished && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if !finished {
            print("✗ 超时，取消安装")
            runner.cancel()
            exit(1)
        }

        check(lineCount > 0, "读到 \(lineCount) 行输出")
        guard let reported else {
            check(false, "没有收到结束回调")
            exit(1)
        }
        switch reported {
        case .success(let status):
            if formula == "subversion" {
                check(status == 0, "brew 退出码 \(status)")
            } else {
                check(status != 0, "不存在的 formula 返回非 0（\(status)）")
            }
        case .failure(let error):
            check(false, "执行失败：\(error.localizedDescription)")
        }

        if formula == "subversion" {
            print("→ 装完后重新检测")
            SVNClient.shared.resetToolPaths()
            let version = SVNClient.shared.svnVersion()
            check(version != nil, "svn 可用：\(version ?? "未找到")")
            if let path = try? SVNClient.shared.toolPath(.svn) {
                check(FileManager.default.isExecutableFile(atPath: path), "svn 可执行：\(path)")
            }
        }

        print(failures == 0 ? "\n✅ 全部通过" : "\n❌ 失败 \(failures) 项")
        exit(failures == 0 ? 0 : 1)
    }

    /// `MacSVN --selftest-credentials`
    /// 验证登录信息的保存 / 读取 / 过期清理 / 删除（使用钥匙串，条目用完即删）
    static func runCredentials() {
        let key = "macsvn-selftest://credentials"
        CredentialStore.delete(for: key)
        defer { CredentialStore.delete(for: key) }

        print("→ 初始状态")
        check(CredentialStore.load(for: key) == nil, "没有已保存的登录信息")
        check(!CredentialStore.hasValid(for: key), "hasValid 为 false")
        check(CredentialStore.expiration(for: key) == nil, "没有到期时间")

        print("→ 保存（默认 30 天）")
        let credentials = Credentials(username: "alice", password: "s3cret")
        CredentialStore.save(credentials, for: key)
        check(CredentialStore.load(for: key) == credentials, "能读回用户名与密码")
        check(CredentialStore.hasValid(for: key), "hasValid 为 true")
        if let stored = CredentialStore.loadStored(for: key) {
            let days = stored.expiresAt.timeIntervalSince(stored.savedAt) / 86_400
            check(abs(days - 30) < 0.01, String(format: "有效期约 30 天（实际 %.2f 天）", days))
        } else {
            check(false, "能读到原始记录")
        }
        if let expiry = CredentialStore.expiration(for: key) {
            check(expiry.timeIntervalSinceNow > 29 * 86_400, "到期时间在 30 天之后")
        } else {
            check(false, "能读到到期时间")
        }

        print("→ 到期后应失效并自动清理")
        let later = Date().addingTimeInterval(31 * 86_400)
        check(CredentialStore.load(for: key, now: later) == nil, "31 天后读不到密码")
        check(CredentialStore.loadStored(for: key) == nil, "过期条目已被删除")
        check(CredentialStore.hasValid(for: key, now: later) == false, "31 天后 hasValid 为 false")

        print("→ 自定义有效期")
        CredentialStore.save(credentials, for: key, lifetime: 3600)
        check(CredentialStore.load(for: key) == credentials, "1 小时内可读")
        check(CredentialStore.load(for: key, now: Date().addingTimeInterval(3700)) == nil, "1 小时后失效")
        check(CredentialStore.loadStored(for: key) == nil, "失效后被清理")

        print("→ 注销（删除）")
        CredentialStore.save(credentials, for: key)
        check(CredentialStore.loadStored(for: key) != nil, "删除前存在")
        CredentialStore.delete(for: key)
        check(CredentialStore.loadStored(for: key) == nil, "删除后不存在")
        check(CredentialStore.load(for: key) == nil, "删除后读不到凭据")

        print(failures == 0 ? "\n✅ 全部通过" : "\n❌ 失败 \(failures) 项")
        exit(failures == 0 ? 0 : 1)
    }

    private static func check(_ condition: Bool, _ message: String) {
        print(condition ? "  ✓ \(message)" : "  ✗ \(message)")
        if !condition { failures += 1 }
    }

    private static func execute(base: String, credentials: Credentials?) async {
        let client = SVNClient.shared
        var options = SVNClient.Options()
        options.credentials = credentials
        options.timeout = 60

        let stamp = String(Int(Date().timeIntervalSince1970))
        let workDir = RemotePath.join(base, "selftest-\(stamp)")
        let localRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsvn-selftest-\(stamp)", isDirectory: true)
        let fm = FileManager.default

        do {
            print("→ 准备本地测试文件")
            let docs = localRoot.appendingPathComponent("docs", isDirectory: true)
            try fm.createDirectory(at: docs, withIntermediateDirectories: true)
            try "hello v1\n".write(to: localRoot.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try "guide v1\n".write(to: docs.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
            try "忽略我\n".write(to: docs.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)

            if credentials != nil {
                print("→ 未提供凭据时应提示需要登录")
                var anonymous = SVNClient.Options()
                anonymous.timeout = 30
                do {
                    _ = try await client.list(url: base, options: anonymous)
                    print("  · 匿名可读，跳过登录校验")
                } catch let error as SVNError {
                    check(error.kind == .authRequired || error.kind == .connection,
                          "识别为需要登录（\(error.kind)）")
                }

                print("→ 错误密码应识别为登录失败")
                var wrong = SVNClient.Options()
                wrong.timeout = 30
                wrong.credentials = Credentials(username: credentials!.username, password: "definitely-wrong")
                do {
                    _ = try await client.list(url: base, options: wrong)
                    check(false, "错误密码不应成功")
                } catch let error as SVNError {
                    check(error.kind == .authFailed, "识别为 authFailed，实际 \(error.kind)")
                }
            }

            print("→ 创建测试目录 \(workDir)")
            _ = try await client.commit(actions: [.mkdir(workDir)], message: "selftest: mkdir", options: options)

            print("→ 首次上传（含子目录）")
            let dropped = [localRoot.appendingPathComponent("a.txt"), docs]
            let plan1 = UploadPlanner.buildUploadPlan(roots: dropped,
                                                      targetDir: workDir,
                                                      remoteKinds: [:])
            check(plan1.items.count == 2, "顶层项 2 个（a.txt 与 docs）")
            check(plan1.fileCount == 2, "文件数 2（a.txt + docs/guide.md），实际 \(plan1.fileCount)")
            check(plan1.folderCount == 1, "文件夹数 1（docs），实际 \(plan1.folderCount)")
            check(plan1.actions.count == 3, "动作 3 个（1 mkdir + 2 put），实际 \(plan1.actions.count)")
            check(plan1.skipped.contains { $0.hasSuffix(".DS_Store") }, "子目录中的 .DS_Store 被跳过：\(plan1.skipped)")
            check(plan1.conflicts.isEmpty, "首次上传无重名")
            check(plan1.skipped.contains { $0.contains(".DS_Store") }, ".DS_Store 被跳过")
            let rev1 = try await client.commit(actions: plan1.actions, message: "selftest: upload", options: options)
            check(rev1 > 0, "提交成功，版本 r\(rev1)")

            let listed = try await client.list(url: workDir, options: options)
            check(listed.contains { $0.name == "a.txt" && !$0.isDirectory }, "a.txt 已在库中")
            check(listed.contains { $0.name == "docs" && $0.isDirectory }, "docs 目录已在库中")
            check(listed.first { $0.name == "a.txt" }?.size == 9, "a.txt 大小正确")

            print("→ 重名检测（再次上传同一份文件）")
            var remoteKinds = UploadPlanner.kindMap(in: listed)
            check(remoteKinds["a.txt"] == .file, "库中已有 a.txt（文件）")
            check(remoteKinds["docs"] == .directory, "库中已有 docs（目录）")
            let subKinds = try await client.listRecursiveKinds(
                url: RemotePath.join(workDir, "docs"), options: options)
            check(subKinds["guide.md"] == .file, "递归列出 docs/guide.md")
            for (path, kind) in subKinds { remoteKinds["docs/" + path] = kind }
            let plan2 = UploadPlanner.buildUploadPlan(roots: dropped,
                                                      targetDir: workDir,
                                                      remoteKinds: remoteKinds)
            check(plan2.conflicts.contains("a.txt"), "检测到 a.txt 重名")
            check(plan2.conflicts.contains("docs/guide.md"), "检测到 docs/guide.md 重名")
            check(plan2.mergedDirs.contains("docs"), "docs 将被合并")
            check(plan2.items.first { $0.name == "docs" }?.willOverwrite == true, "docs 标记为覆盖/合并")
            check(!plan2.actions.contains { if case .mkdir = $0 { return true }; return false },
                  "已存在的目录不重复 mkdir")

            print("→ 覆盖上传（内容改为 v2）")
            try "hello v2 - overwritten\n".write(to: localRoot.appendingPathComponent("a.txt"),
                                                atomically: true, encoding: .utf8)
            try "guide v2\n".write(to: docs.appendingPathComponent("guide.md"),
                                   atomically: true, encoding: .utf8)
            let rev2 = try await client.commit(actions: plan2.actions, message: "selftest: overwrite", options: options)
            check(rev2 > rev1, "覆盖提交产生新版本 r\(rev2)")

            let exportURL = fm.temporaryDirectory.appendingPathComponent("macsvn-check-\(stamp).txt")
            try await client.export(url: RemotePath.join(workDir, "a.txt"), to: exportURL, options: options)
            let content = try String(contentsOf: exportURL, encoding: .utf8)
            check(content.hasPrefix("hello v2"), "覆盖后内容为 v2")

            print("→ 重命名")
            let renamed = try await client.commit(
                actions: [.move(from: RemotePath.join(workDir, "a.txt"),
                                to: RemotePath.join(workDir, "b.txt"))],
                message: "selftest: rename", options: options)
            check(renamed > rev2, "重命名提交 r\(renamed)")
            let afterRename = try await client.list(url: workDir, options: options)
            check(!afterRename.contains { $0.name == "a.txt" }, "a.txt 已不存在")
            check(afterRename.contains { $0.name == "b.txt" }, "b.txt 已存在")

            print("→ 重名移动应被识别为冲突")
            let movePlan = UploadPlanner.buildMovePlan(entries: afterRename.filter { $0.name == "b.txt" },
                                                       from: workDir,
                                                       to: workDir,
                                                       remoteKinds: UploadPlanner.kindMap(in: afterRename))
            check(movePlan.blockers.contains { $0.path == "b.txt" }, "目标已有同名项 → 移动被拦下")
            check(movePlan.actions.isEmpty, "移动计划不含动作（实际 \(movePlan.actions.count) 个）")

            print("→ 删除")
            let deleted = try await client.commit(
                actions: [.remove(RemotePath.join(workDir, "b.txt")),
                          .put(local: localRoot.appendingPathComponent("a.txt"),
                               remote: RemotePath.join(workDir, "c.txt"))],
                message: "selftest: delete+add", options: options)
            check(deleted > renamed, "删除并新增提交 r\(deleted)")
            let afterDelete = try await client.list(url: workDir, options: options)
            check(!afterDelete.contains { $0.name == "b.txt" }, "b.txt 已删除")
            check(afterDelete.contains { $0.name == "c.txt" }, "c.txt 已新增")

            print("→ 路径不存在时的错误分类")
            do {
                _ = try await client.list(url: RemotePath.join(workDir, "not-exist"), options: options)
                check(false, "应当抛出错误")
            } catch let error as SVNError {
                check(error.kind == .notFound, "错误类型为 notFound，实际 \(error.kind)")
            }

            try await runEdgeCases(client: client, localRoot: localRoot, workDir: workDir,
                                   options: options, stamp: stamp)

            print("→ 清理测试目录")
            _ = try await client.commit(actions: [.remove(workDir)], message: "selftest: cleanup", options: options)
            let final = try await client.list(url: base, options: options)
            check(!final.contains { $0.name.hasPrefix("selftest-\(stamp)") }, "测试目录已清理")

            try? fm.removeItem(at: localRoot)
            try? fm.removeItem(at: exportURL)
        } catch let error as SVNError {
            failures += 1
            print("  ✗ 异常终止：\(error.message) (\(error.code ?? "-"))\n\(error.raw)")
        } catch {
            failures += 1
            print("  ✗ 异常终止：\(error.localizedDescription)")
        }
    }
}
