import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let model = BrowserModel()
    private let headlessScenario = HeadlessScenario.parse(CommandLine.arguments)

    /// 顶层代码不是 main actor 上下文，这里显式放开初始化
    nonisolated override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        buildMainMenu()

        if let scenario = headlessScenario {
            NSApp.setActivationPolicy(.accessory)
            scenario.start()
            return
        }
        // 带了演练参数却没被识别（例如拼写错误），直接报错而不是默默启动界面
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--headless") }) {
            FileHandle.standardError.write(Data(
                "未知的演练参数。可用：--headless-upload / --headless-op / --headless-move / --headless-login\n".utf8))
            exit(2)
        }

        let hosting = NSHostingView(rootView: BrowserView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.title = "MacSVN"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 880, height: 520)
        window.contentView = hosting
        window.setFrameAutosaveName("MacSVNMainWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: 菜单

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 MacSVN",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item("安装 Subversion…", #selector(installSubversion), ""))
        appMenu.addItem(item("重新检测运行环境", #selector(recheckEnvironment), ""))
        appMenu.addItem(item("设置 SVN 路径…", #selector(openSVNSettings), ""))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 MacSVN", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "隐藏其它",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 MacSVN", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(item("打开地址栏…", #selector(focusAddress), "l"))
        fileMenu.addItem(item("刷新", #selector(reload), "r"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("下载所选到…", #selector(downloadSelection), "s"))
        let newFolder = item("新建文件夹…", #selector(newFolder), "n", modifiers: [.command, .shift])
        fileMenu.addItem(newFolder)
        fileMenu.addItem(item("重命名…", #selector(rename), "e"))
        fileMenu.addItem(item("删除…", #selector(deleteSelection), "\u{8}", modifiers: [.command]))
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let goMenuItem = NSMenuItem()
        let goMenu = NSMenu(title: "前往")
        goMenu.addItem(item("后退", #selector(goBack), "["))
        goMenu.addItem(item("前进", #selector(goForward), "]"))
        goMenu.addItem(item("上一级目录", #selector(goUp), String(UnicodeScalar(NSUpArrowFunctionKey)!),
                            modifiers: [.command]))
        goMenuItem.submenu = goMenu
        mainMenu.addItem(goMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    private func item(_ title: String, _ action: Selector, _ key: String,
                      modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.keyEquivalentModifierMask = modifiers
        menuItem.target = self
        return menuItem
    }

    @objc private func focusAddress() { post(.macSVNFocusAddress) }
    @objc private func reload() { post(.macSVNReload) }
    @objc private func goBack() { post(.macSVNBack) }
    @objc private func goForward() { post(.macSVNForward) }
    @objc private func goUp() { post(.macSVNUp) }
    @objc private func downloadSelection() { post(.macSVNDownload) }
    @objc private func newFolder() { post(.macSVNNewFolder) }
    @objc private func deleteSelection() { post(.macSVNDelete) }
    @objc private func rename() { post(.macSVNRename) }

    @objc private func installSubversion() {
        model.beginInstallSubversion()
        activate()
    }

    @objc private func recheckEnvironment() {
        model.recheckEnvironment()
    }

    private func activate() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func openSVNSettings() {
        model.beginSetSVNPath()
        activate()
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
}

// 隐藏的界面渲染入口：MacSVN --render-ui <输出目录> [仓库URL]
if let index = CommandLine.arguments.firstIndex(of: "--render-ui") {
    let rest = Array(CommandLine.arguments.dropFirst(index + 1))
    var finished = false
    Task { @MainActor in
        RenderUI.render(outputDirectory: rest.first ?? "/tmp/macsvn-ui",
                        repositoryURL: rest.count > 1 ? rest[1] : nil)
        finished = true
    }
    while !finished {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    exit(0)
}

// 隐藏的 brew 自检：MacSVN --selftest-brew [formula]
if let index = CommandLine.arguments.firstIndex(of: "--selftest-brew") {
    SelfTest.runBrew(arguments: Array(CommandLine.arguments.dropFirst(index + 1)))
}

// 隐藏的自检入口：MacSVN --selftest <仓库URL> [用户名] [密码]
if let index = CommandLine.arguments.firstIndex(of: "--selftest") {
    SelfTest.run(arguments: Array(CommandLine.arguments.dropFirst(index + 1)))
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.regular)
application.run()
