import AppKit
import Foundation
import SwiftUI

/// 隐藏的自检：`MacSVN --selftest-menu <仓库URL>`
/// 真实构造界面，找到目录列表，模拟右键并检查菜单内容是否可用。
/// （右键菜单无法在没有交互的情况下用鼠标验证，这里走的是 AppKit 真正的事件入口。）
@MainActor
enum MenuProbe {

    static func run(repositoryURL: String?) -> Never {
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print(condition ? "  ✓ \(message)" : "  ✗ \(message)")
            if !condition { failures += 1 }
        }

        let model = BrowserModel()
        if let repositoryURL, let url = RemotePath.normalize(repositoryURL).url {
            do {
                let entries = try SVNClient.shared.listSync(url: url, options: model.svnOptions(for: url))
                model.applyForRender(url: url, entries: entries)
                print("已载入 \(entries.count) 个条目：\(RemotePath.display(url))")
            } catch {
                print("载入失败：\(error.localizedDescription)")
            }
        }

        let hosting = NSHostingView(rootView: FileTableView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setIsVisible(false)
        hosting.layoutSubtreeIfNeeded()

        guard let table = findTable(in: hosting) else {
            print("  ✗ 没找到目录列表（NSTableView）")
            exit(1)
        }
        print("找到目录列表：\(table.numberOfRows) 行")

        // 表格坐标向下增长，空白处必须取最后一行之下，否则会命中第一行
        func emptyPoint() -> NSPoint {
            guard table.numberOfRows > 0 else { return NSPoint(x: 20, y: 20) }
            let lastRow = table.rect(ofRow: table.numberOfRows - 1)
            let below = NSPoint(x: 20, y: lastRow.maxY + 30)
            return below.y < table.bounds.maxY ? below : NSPoint(x: table.bounds.maxX - 10, y: lastRow.midY)
        }

        func menu(atRow row: Int, label: String) -> NSMenu? {
            let point = row >= 0 ? NSPoint(x: table.rect(ofRow: row).midX, y: table.rect(ofRow: row).midY)
                                 : emptyPoint()
            let windowPoint = table.convert(point, to: nil)
            guard let event = NSEvent.mouseEvent(with: .rightMouseDown,
                                                 location: windowPoint,
                                                 modifierFlags: [],
                                                 timestamp: 0,
                                                 windowNumber: window.windowNumber,
                                                 context: nil,
                                                 eventNumber: 0,
                                                 clickCount: 1,
                                                 pressure: 1) else {
                print("  ✗ 无法构造右键事件（\(label)）")
                failures += 1
                return nil
            }
            return table.menu(for: event)
        }

        func titles(_ menu: NSMenu?) -> [String] {
            (menu?.items ?? []).filter { !$0.isSeparatorItem }.map(\.title)
        }

        print("→ 空白处右键")
        let emptyMenu = menu(atRow: -1, label: "空白处")
        let emptyTitles = titles(emptyMenu)
        print("    菜单项：\(emptyTitles.joined(separator: " / "))")
        check(emptyTitles.contains(NSLocalizedString("New Folder…", comment: "")), "包含「New Folder…」")
        check(emptyTitles.contains(NSLocalizedString("Refresh", comment: "")), "包含「Refresh」")

        if model.entries.contains(where: { $0.isDirectory }) {
            let folderRow = model.entries.firstIndex { $0.isDirectory }!
            print("→ 文件夹行右键（第 \(folderRow + 1) 行：\(model.entries[folderRow].name)）")
            let folderMenu = menu(atRow: folderRow, label: "文件夹行")
            let folderTitles = titles(folderMenu)
            print("    菜单项：\(folderTitles.joined(separator: " / "))")
            check(folderTitles.contains(NSLocalizedString("New Folder…", comment: "")), "包含「New Folder…」")
            let inside = folderTitles.first { $0.hasPrefix(NSLocalizedString("New Folder in", comment: "")) }
            check(inside != nil, "包含在该文件夹内新建的菜单项")
            if let inside { print("    该项标题：\(inside)") }
        } else {
            print("  · 目录里没有文件夹，跳过文件夹行检查")
        }

        if let fileRow = model.entries.firstIndex(where: { !$0.isDirectory }) {
            print("→ 文件行右键（第 \(fileRow + 1) 行：\(model.entries[fileRow].name)）")
            let fileTitles = titles(menu(atRow: fileRow, label: "文件行"))
            print("    菜单项：\(fileTitles.joined(separator: " / "))")
            check(fileTitles.contains(NSLocalizedString("New Folder…", comment: "")), "包含「New Folder…」")
            check(!fileTitles.contains { $0.hasPrefix(NSLocalizedString("New Folder in", comment: "")) },
                  "文件行不提供「在该项内新建」")
        }

        print(failures == 0 ? "\n✅ 全部通过" : "\n❌ 失败 \(failures) 项")
        exit(failures == 0 ? 0 : 1)
    }

    private static func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let found = findTable(in: subview) { return found }
        }
        return nil
    }
}
