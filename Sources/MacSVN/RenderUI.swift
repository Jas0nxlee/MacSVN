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
        let prompt = TransferPrompt(plan: plan, message: "上传 a.txt、guide.md、specs 等 4 项")
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
                                                                  reason: "库中是同名文件夹，无法覆盖为文件")],
                                       mergedDirs: [],
                                       fileCount: 2, folderCount: 0, totalBytes: 92_096,
                                       skipped: [])
        let blockerPrompt = TransferPrompt(plan: blockerPlan, message: "上传 notes、avatar.png")
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
        let movePrompt = TransferPrompt(plan: movePlan, message: "移动 report.pdf、assets 到 archive/")
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
        installPrompt.append("svn 已装入 /opt/homebrew/bin/svn")
        render(view: InstallSheet(prompt: installPrompt, model: model),
               size: NSSize(width: 540, height: 560),
               to: directory.appendingPathComponent("10-install-progress.png"))

        // 安装完成
        installPrompt.phase = .succeeded(version: "1.14.5")
        render(view: InstallSheet(prompt: installPrompt, model: model),
               size: NSSize(width: 540, height: 560),
               to: directory.appendingPathComponent("11-install-done.png"))

        // 登录框
        let login = LoginPrompt(url: "https://svn.example.com/repo/trunk",
                                hostKey: "https://svn.example.com",
                                message: "该仓库需要登录后才能访问",
                                username: "zhangsan",
                                remember: true,
                                needsTrust: false)
        login.password = "secret"
        render(view: LoginSheet(prompt: login, model: model),
               size: NSSize(width: 540, height: 330),
               to: directory.appendingPathComponent("03-login.png"))

        // 重命名
        let rename = InputPrompt(kind: .rename, title: "重命名文件", fieldLabel: "新名称",
                                 initialText: "readme.txt", note: "位于 /trunk/docs/",
                                 confirmTitle: "重命名", message: "重命名 readme.txt")
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
                                  message: "删除 “old-notes.md”")
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
