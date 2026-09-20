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
        appMenu.addItem(withTitle: NSLocalizedString("About MacSVN", comment: ""),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item(NSLocalizedString("Install Subversion…", comment: ""), #selector(installSubversion), ""))
        appMenu.addItem(item(NSLocalizedString("Re-check Environment", comment: ""), #selector(recheckEnvironment), ""))
        appMenu.addItem(item(NSLocalizedString("Set SVN Path…", comment: ""), #selector(openSVNSettings), ""))
        appMenu.addItem(.separator())
        appMenu.addItem(item(NSLocalizedString("Log Out", comment: ""), #selector(logOut), ""))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: NSLocalizedString("Hide MacSVN", comment: ""), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: NSLocalizedString("Hide Others", comment: ""),
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: NSLocalizedString("Quit MacSVN", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: NSLocalizedString("File", comment: ""))
        fileMenu.addItem(item(NSLocalizedString("Open Location…", comment: ""), #selector(focusAddress), "l"))
        fileMenu.addItem(item(NSLocalizedString("Refresh", comment: ""), #selector(reload), "r"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item(NSLocalizedString("Download Selected to…", comment: ""), #selector(downloadSelection), "s"))
        let newFolder = item(NSLocalizedString("New Folder…", comment: ""), #selector(newFolder), "n", modifiers: [.command, .shift])
        fileMenu.addItem(newFolder)
        fileMenu.addItem(item(NSLocalizedString("Rename…", comment: ""), #selector(rename), "e"))
        fileMenu.addItem(item(NSLocalizedString("Delete…", comment: ""), #selector(deleteSelection), "\u{8}", modifiers: [.command]))
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: NSLocalizedString("Close Window", comment: ""), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: NSLocalizedString("Edit", comment: ""))
        editMenu.addItem(withTitle: NSLocalizedString("Undo", comment: ""), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: NSLocalizedString("Redo", comment: ""), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: NSLocalizedString("Cut", comment: ""), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: NSLocalizedString("Copy", comment: ""), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: NSLocalizedString("Paste", comment: ""), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: NSLocalizedString("Select All", comment: ""), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let goMenuItem = NSMenuItem()
        let goMenu = NSMenu(title: NSLocalizedString("Go", comment: ""))
        goMenu.addItem(item(NSLocalizedString("Back", comment: ""), #selector(goBack), "["))
        goMenu.addItem(item(NSLocalizedString("Forward", comment: ""), #selector(goForward), "]"))
        goMenu.addItem(item(NSLocalizedString("Enclosing Folder", comment: ""), #selector(goUp), String(UnicodeScalar(NSUpArrowFunctionKey)!),
                            modifiers: [.command]))
        goMenuItem.submenu = goMenu
        mainMenu.addItem(goMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: NSLocalizedString("Window", comment: ""))
        windowMenu.addItem(withTitle: NSLocalizedString("Minimize", comment: ""), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: NSLocalizedString("Zoom", comment: ""), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
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

    @objc private func logOut() {
        model.logOut()
        activate()
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

// 隐藏的地址编解码自检：MacSVN --selftest-paths
if CommandLine.arguments.contains("--selftest-paths") {
    SelfTest.runPaths()
}

// 隐藏的登录信息自检：MacSVN --selftest-credentials
if CommandLine.arguments.contains("--selftest-credentials") {
    SelfTest.runCredentials()
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
