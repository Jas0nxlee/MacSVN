import AppKit
import Foundation
import SwiftUI

/// 隐藏的界面渲染模式，用于在没有屏幕录制权限时也能检查界面效果：
/// `MacSVN --render-ui <输出目录> [仓库URL]`
enum RenderUI {
    @MainActor
    static func render(outputDirectory: String, repositoryURL: String?) {
        let directory = URL(fileURLWithPath: outputDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let model = BrowserModel()
        if let repositoryURL, let url = RemotePath.normalize(repositoryURL).url {
            do {
                let entries = try SVNClient.shared.listSync(url: url, options: model.svnOptions(for: url))
                model.applyForRender(url: url, entries: entries)
                print("已加载 \(entries.count) 个条目：\(url)")
            } catch let error as SVNError {
                print("加载失败：\(error.message)")
            } catch {
                print("加载失败：\(error.localizedDescription)")
            }
        }
        render(view: BrowserView(model: model), size: NSSize(width: 1100, height: 720),
               to: directory.appendingPathComponent("01-browser.png"))

        // 上传确认框（含重名覆盖提示）
        let plan = TransferPlan(mode: .upload,
                                targetDir: "https://svn.example.com/repo/trunk/docs",
                                actions: [],
                                items: [
                                    UploadItem(localURL: URL(fileURLWithPath: "/tmp/a.txt"), name: "a.txt",
                                               relativePath: "a.txt", isDirectory: false, size: 15360,
                                               willOverwrite: true),
                                    UploadItem(localURL: URL(fileURLWithPath: "/tmp/guide.md"), name: "guide.md",
                                               relativePath: "guide.md", isDirectory: false, size: 2048,
                                               willOverwrite: true),
                                    UploadItem(localURL: URL(fileURLWithPath: "/tmp/specs"), name: "specs",
                                               relativePath: "specs", isDirectory: true, size: 0,
                                               willOverwrite: true),
                                    UploadItem(localURL: URL(fileURLWithPath: "/tmp/new.pdf"), name: "new.pdf",
                                               relativePath: "new.pdf", isDirectory: false, size: 512_000),
                                ],
                                conflicts: ["a.txt", "guide.md", "specs/api.md", "specs/design.md"],
                                mergedDirs: ["specs"],
                                fileCount: 6, folderCount: 1, totalBytes: 1_880_064,
                                skipped: ["specs/.DS_Store"])
        let prompt = TransferPrompt(plan: plan, message: NSLocalizedString("Upload a.txt, guide.md, specs and 1 more", comment: ""))
        render(view: TransferSheet(prompt: prompt, model: model),
               size: NSSize(width: 540, height: 660),
               to: directory.appendingPathComponent("02-upload-confirm.png"))

        // 上传确认框（硬冲突：文件与库中同名文件夹）
        let blockerPlan = TransferPlan(mode: .upload,
                                       targetDir: "https://svn.example.com/repo/trunk",
                                       actions: [],
                                       items: [
                                           UploadItem(localURL: URL(fileURLWithPath: "/tmp/notes"),
                                                      name: "notes", relativePath: "notes",
                                                      isDirectory: false, size: 4096),
                                           UploadItem(localURL: URL(fileURLWithPath: "/tmp/avatar.png"),
                                                      name: "avatar.png", relativePath: "avatar.png",
                                                      isDirectory: false, size: 88_000,
                                                      willOverwrite: true),
                                       ],
                                       conflicts: ["avatar.png"],
                                       blockers: [TransferBlocker(path: "notes",
                                                                  reason: NSLocalizedString("a folder with the same name exists in the repository", comment: ""))],
                                       mergedDirs: [],
                                       fileCount: 2, folderCount: 0, totalBytes: 92_096,
                                       skipped: [])
        let blockerPrompt = TransferPrompt(plan: blockerPlan, message: NSLocalizedString("Upload notes, avatar.png", comment: ""))
        render(view: TransferSheet(prompt: blockerPrompt, model: model),
               size: NSSize(width: 540, height: 560),
               to: directory.appendingPathComponent("06-upload-blocked.png"))

        // 库内移动确认
        let movePlan = TransferPlan(mode: .move,
                                    targetDir: "https://svn.example.com/repo/trunk/archive",
                                    actions: [],
                                    items: [
                                        UploadItem(localURL: URL(fileURLWithPath: "/tmp/report.pdf"),
                                                   name: "report.pdf", relativePath: "report.pdf",
                                                   isDirectory: false, size: 240_000),
                                        UploadItem(localURL: URL(fileURLWithPath: "/tmp/assets"),
                                                   name: "assets", relativePath: "assets",
                                                   isDirectory: true, size: 0),
                                    ],
                                    conflicts: [],
                                    mergedDirs: [],
                                    fileCount: 1, folderCount: 1, totalBytes: 240_000,
                                    skipped: [])
        let movePrompt = TransferPrompt(plan: movePlan, message: NSLocalizedString("Move report.pdf, assets to archive/", comment: ""))
        render(view: TransferSheet(prompt: movePrompt, model: model),
               size: NSSize(width: 540, height: 460),
               to: directory.appendingPathComponent("07-move-confirm.png"))

        // 缺少 svn 的首屏引导（本机无 Homebrew）
        let noBrewModel = BrowserModel()
        noBrewModel.applyEnvironmentForRender(svnPath: nil, brewPath: nil)
        render(view: BrowserView(model: noBrewModel), size: NSSize(width: 1100, height: 720),
               to: directory.appendingPathComponent("08-install-guide-no-brew.png"))

        // 缺少 svn 的首屏引导（已有 Homebrew）
        let brewModel = BrowserModel()
        brewModel.applyEnvironmentForRender(svnPath: nil, brewPath: "/opt/homebrew/bin/brew")
        render(view: BrowserView(model: brewModel), size: NSSize(width: 1100, height: 720),
               to: directory.appendingPathComponent("09-install-guide-with-brew.png"))

        // 安装进行中
        let installPrompt = InstallPrompt(brewPath: "/opt/homebrew/bin/brew")
        installPrompt.append("使用 /opt/homebrew/bin/brew install subversion")
        installPrompt.append("==> Downloading https://ghcr.io/v2/homebrew/core/subversion/manifests/1.14.5")
        installPrompt.append("==> Fetching subversion")
        installPrompt.append("==> Pouring subversion--1.14.5.arm64_sequoia.bottle.tar.gz")
        installPrompt.append("==> Caveats")
        installPrompt.append(NSLocalizedString("svn installed to /opt/homebrew/bin/svn", comment: ""))
        render(view: InstallSheet(prompt: installPrompt, model: model),
               size: NSSize(width: 540, height: 560),
               to: directory.appendingPathComponent("10-install-progress.png"))

        // 安装完成
        installPrompt.phase = .succeeded(version: "1.14.5")
        render(view: InstallSheet(prompt: installPrompt, model: model),
               size: NSSize(width: 540, height: 560),
               to: directory.appendingPathComponent("11-install-done.png"))

        // 「复制到…」目标选择框
        let copyEntries = [
            SVNEntry(name: "报告终稿.docx", isDirectory: false, size: 182_000, revision: 12, author: "yinuo", date: Date()),
            SVNEntry(name: "图集", isDirectory: true, size: nil, revision: 12, author: "yinuo", date: Date()),
        ]
        let copyPrompt = CopyPrompt(items: copyEntries,
                                    sourceDir: "https://svn.example.com/repo/trunk/1142",
                                    startDir: "https://svn.example.com/repo/trunk/1142/archive")
        copyPrompt.folders = [
            SVNEntry(name: "2024", isDirectory: true, size: nil, revision: 8, author: "lisi", date: Date()),
            SVNEntry(name: "2025", isDirectory: true, size: nil, revision: 9, author: "lisi", date: Date()),
            SVNEntry(name: "评审材料", isDirectory: true, size: nil, revision: 10, author: "yinuo", date: Date()),
        ]
        render(view: CopySheet(prompt: copyPrompt, model: model),
               size: NSSize(width: 540, height: 520),
               to: directory.appendingPathComponent("12-copy-to.png"))

        // 目标非法（同一个文件夹 / 重名）
        let blockedCopy = CopyPrompt(items: copyEntries,
                                     sourceDir: "https://svn.example.com/repo/trunk/1142",
                                     startDir: "https://svn.example.com/repo/trunk/1142")
        blockedCopy.folders = []
        // 目标就是源所在目录 → blockers 由校验函数自动算出
        blockedCopy.newName = "报告终稿.docx"
        blockedCopy.existingNames = ["报告终稿.docx"]
        render(view: CopySheet(prompt: blockedCopy, model: model),
               size: NSSize(width: 540, height: 460),
               to: directory.appendingPathComponent("13-copy-blocked.png"))

        // 登录框
        let login = LoginPrompt(url: "https://svn.example.com/repo/trunk",
                                hostKey: "https://svn.example.com",
                                message: NSLocalizedString("This repository requires sign-in", comment: ""),
                                username: "zhangsan",
                                remember: true,
                                needsTrust: false)
        login.password = "secret"
        login.savedLoginExpiry = Date().addingTimeInterval(20 * 86_400)
        render(view: LoginSheet(prompt: login, model: model),
               size: NSSize(width: 540, height: 330),
               to: directory.appendingPathComponent("03-login.png"))

        // 重命名
        let rename = InputPrompt(kind: .rename, title: NSLocalizedString("Rename File", comment: ""), fieldLabel: NSLocalizedString("New name", comment: ""),
                                 initialText: "readme.txt", note: NSLocalizedString("in /trunk/docs/", comment: ""),
                                 confirmTitle: NSLocalizedString("Rename", comment: ""), message: NSLocalizedString("Rename readme.txt", comment: ""))
        render(view: InputSheet(prompt: rename, model: model),
               size: NSSize(width: 540, height: 360),
               to: directory.appendingPathComponent("04-rename.png"))

        // 删除确认
        let entries = [
            SVNEntry(name: "old-notes.md", isDirectory: false, size: 1024, revision: 12,
                     author: "zhangsan", date: Date()),
            SVNEntry(name: "draft", isDirectory: true, size: nil, revision: 9,
                     author: "lisi", date: Date()),
        ]
        let delete = DeletePrompt(entries: entries, baseDir: "https://svn.example.com/repo/trunk",
                                  message: NSLocalizedString("Delete “old-notes.md”", comment: ""))
        render(view: DeleteSheet(prompt: delete, model: model),
               size: NSSize(width: 540, height: 380),
               to: directory.appendingPathComponent("05-delete.png"))

        print("已输出到 \(directory.path)")
    }

    /// 让主线程跑 RunLoop，等待异步加载完成
    private static func pump(until condition: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private static func render<V: View>(view: V, size: NSSize, to url: URL) {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.titlebarAppearsTransparent = true
        window.contentView = hosting
        window.setIsVisible(false)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        pump(until: { false }, timeout: 0.35)   // 给 SwiftUI 一点时间完成布局

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }
}
