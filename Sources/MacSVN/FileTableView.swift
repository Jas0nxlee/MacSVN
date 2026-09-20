import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 支持右键菜单与键盘操作的 NSTableView

final class FileListTableView: NSTableView {
    var contextMenuBuilder: (() -> NSMenu?)?
    var onOpen: (() -> Void)?
    var onDelete: (() -> Void)?
    var onRename: (() -> Void)?
    var onNewFolder: (() -> Void)?
    var onDownload: (() -> Void)?
    var onCopyURL: (() -> Void)?

    /// 右键点击的行（-1 表示空白处），菜单构建时用来决定可用的操作
    private(set) var contextMenuRow = -1

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        contextMenuRow = clickedRow
        if clickedRow >= 0 {
            if !selectedRowIndexes.contains(clickedRow) {
                selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            }
        }
        return contextMenuBuilder?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:                     // Return / Enter
            onOpen?()
        case 51, 117:                    // Delete / Forward Delete
            onDelete?()
        case 14 where event.modifierFlags.contains(.command):  // Cmd+E
            onRename?()
        case 53:                         // Esc
            deselectAll(nil)
        case 125 where event.modifierFlags.contains(.command): // Cmd+↓ 打开
            onOpen?()
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - SwiftUI 包装

struct FileTableView: NSViewRepresentable {
    @ObservedObject var model: BrowserModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.sync()
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSFilePromiseProviderDelegate {
        final class PromiseInfo {
            let remoteURL: String
            let fileName: String
            let options: SVNClient.Options
            init(remoteURL: String, fileName: String, options: SVNClient.Options) {
                self.remoteURL = remoteURL
                self.fileName = fileName
                self.options = options
            }
        }

        var model: BrowserModel
        private var tableView: FileListTableView!
        private var scrollView: NSScrollView!
        private var entries: [SVNEntry] = []
        private var baseURL: String?
        private var appliedSelection: Set<String> = []
        private var iconCache: [String: NSImage] = [:]
        private var currentSort: (key: String, ascending: Bool) = ("name", true)

        private static let columnWidths: [(id: String, title: String, width: CGFloat)] = [
            ("name", NSLocalizedString("Name", comment: ""), 320),
            ("type", NSLocalizedString("Kind", comment: ""), 70),
            ("size", NSLocalizedString("Size", comment: ""), 90),
            ("revision", NSLocalizedString("Rev", comment: ""), 70),
            ("author", NSLocalizedString("Author", comment: ""), 110),
            ("date", NSLocalizedString("Modified", comment: ""), 150),
        ]

        init(model: BrowserModel) {
            self.model = model
        }

        // MARK: 视图构建

        func makeScrollView() -> NSScrollView {
            let table = FileListTableView()
            table.style = .fullWidth
            table.rowHeight = 24
            table.usesAlternatingRowBackgroundColors = true
            table.allowsMultipleSelection = true
            table.allowsEmptySelection = true
            table.allowsColumnReordering = false
            table.allowsColumnSelection = false
            table.columnAutoresizingStyle = .noColumnAutoresizing
            table.gridStyleMask = []
            table.intercellSpacing = NSSize(width: 3, height: 2)
            table.dataSource = self
            table.delegate = self
            table.target = self
            table.doubleAction = #selector(handleDoubleClick)
            table.setDraggingSourceOperationMask(.copy, forLocal: false)
            table.setDraggingSourceOperationMask(.move, forLocal: true)
            table.registerForDraggedTypes([.fileURL])
            table.contextMenuBuilder = { [weak self] in self?.buildMenu() }
            table.onOpen = { [weak self] in self?.model.openSelected() }
            table.onDelete = { [weak self] in self?.model.beginDelete() }
            table.onRename = { [weak self] in self?.model.beginRename() }
            table.onNewFolder = { [weak self] in self?.model.beginNewFolder() }

            for spec in Self.columnWidths {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
                column.title = spec.title
                column.width = spec.width
                column.minWidth = spec.id == "name" ? 180 : 60
                column.resizingMask = spec.id == "name" ? .autoresizingMask : .userResizingMask
                column.sortDescriptorPrototype = NSSortDescriptor(key: spec.id, ascending: true)
                table.addTableColumn(column)
            }
            table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]

            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
            scroll.drawsBackground = false
            scroll.automaticallyAdjustsContentInsets = false
            // 必须在设置 documentView 之后再挂表头，否则表头不会显示
            table.headerView = NSTableHeaderView()

            scroll.contentView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(clipViewFrameChanged),
                                                   name: NSView.frameDidChangeNotification,
                                                   object: scroll.contentView)

            self.tableView = table
            self.scrollView = scroll
            return scroll
        }

        @objc private func clipViewFrameChanged() {
            adjustColumnWidths()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        // MARK: 与模型同步

        func sync() {
            let newEntries = model.entries
            let newBase = model.currentURL
            var needsReload = false

            if newEntries != entries || newBase != baseURL {
                entries = newEntries
                baseURL = newBase
                needsReload = true
            }

            if (model.sortKey, model.sortAscending) != currentSort {
                currentSort = (model.sortKey, model.sortAscending)
                tableView.sortDescriptors = [NSSortDescriptor(key: model.sortKey, ascending: model.sortAscending)]
                needsReload = true
            }

            if needsReload {
                tableView.reloadData()
                adjustColumnWidths()
            }

            if model.selection != appliedSelection {
                appliedSelection = model.selection
                var indexes = IndexSet()
                for (index, entry) in entries.enumerated() where model.selection.contains(entry.name) {
                    indexes.insert(index)
                }
                tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            }
        }

        private func adjustColumnWidths() {
            guard let tableView, let scrollView else { return }
            let total = Self.columnWidths.dropFirst().reduce(CGFloat(0)) { $0 + $1.width }
            let available = scrollView.contentSize.width - total - CGFloat(Self.columnWidths.count) * 3
            if let column = tableView.tableColumns.first, available > 180 {
                column.width = available
            }
        }

        // MARK: 数据源

        func numberOfRows(in tableView: NSTableView) -> Int {
            entries.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, row >= 0, row < entries.count else { return nil }
            let entry = entries[row]
            let isName = tableColumn.identifier.rawValue == "name"
            let cell = reusableCell(for: tableColumn, withImage: isName)

            switch tableColumn.identifier.rawValue {
            case "name":
                cell.textField?.stringValue = entry.name
                cell.imageView?.image = icon(for: entry)
                cell.textField?.font = NSFont.systemFont(ofSize: 13)
                cell.textField?.textColor = .labelColor
            case "type":
                cell.textField?.stringValue = entry.typeText
                styleSecondary(cell)
            case "size":
                cell.textField?.stringValue = entry.sizeText
                cell.textField?.alignment = .right
                styleSecondary(cell)
            case "revision":
                cell.textField?.stringValue = entry.revisionText
                styleSecondary(cell)
            case "author":
                cell.textField?.stringValue = entry.authorText
                styleSecondary(cell)
            case "date":
                cell.textField?.stringValue = entry.dateText
                styleSecondary(cell)
            default:
                cell.textField?.stringValue = ""
            }
            return cell
        }

        private func styleSecondary(_ cell: NSTableCellView) {
            cell.textField?.font = NSFont.systemFont(ofSize: 12)
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.alignment = .left
        }

        private func reusableCell(for column: NSTableColumn, withImage: Bool) -> NSTableCellView {
            if let cell = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView {
                return cell
            }
            let cell = NSTableCellView()
            cell.identifier = column.identifier

            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingMiddle
            text.cell?.usesSingleLineMode = true
            cell.addSubview(text)
            cell.textField = text

            if withImage {
                let imageView = NSImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.imageScaling = .scaleProportionallyDown
                cell.addSubview(imageView)
                cell.imageView = imageView
                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 16),
                    imageView.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                ])
            } else {
                NSLayoutConstraint.activate([
                    text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                ])
            }
            NSLayoutConstraint.activate([
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func icon(for entry: SVNEntry) -> NSImage? {
            if entry.isDirectory {
                let key = "dir"
                if let cached = iconCache[key] { return cached }
                let image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: NSLocalizedString("Folder", comment: ""))
                image?.isTemplate = true
                iconCache[key] = image
                return image
            }
            let ext = (entry.name as NSString).pathExtension.lowercased()
            if let cached = iconCache[ext] { return cached }
            let image: NSImage
            if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
                image = NSWorkspace.shared.icon(for: type)
            } else {
                image = NSWorkspace.shared.icon(for: .data)
            }
            iconCache[ext] = image
            return image
        }

        // MARK: 选中与排序

        func tableViewSelectionDidChange(_ notification: Notification) {
            var names = Set<String>()
            for index in tableView.selectedRowIndexes where index < entries.count {
                names.insert(entries[index].name)
            }
            appliedSelection = names
            model.selection = names
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key else { return }
            let next = (key, descriptor.ascending)
            guard next != currentSort else { return }
            currentSort = next
            model.applySort(key: key, ascending: descriptor.ascending)
        }

        @objc private func handleDoubleClick() {
            let row = tableView.clickedRow
            guard row >= 0, row < entries.count else { return }
            model.openEntry(entries[row])
        }

        // MARK: 右键菜单

        private func buildMenu() -> NSMenu? {
            let menu = NSMenu()
            let selected = model.entries.filter { model.selection.contains($0.name) }
            let hasSelection = !selected.isEmpty

            if hasSelection {
                let openItem = NSMenuItem(title: selected.count == 1 ? NSLocalizedString("Open", comment: "") : NSLocalizedString("Open Selected", comment: ""), action: #selector(menuOpen), keyEquivalent: "")
                openItem.target = self
                menu.addItem(openItem)

                let download = NSMenuItem(title: NSLocalizedString("Download to…", comment: ""), action: #selector(menuDownload), keyEquivalent: "")
                download.target = self
                menu.addItem(download)

                menu.addItem(.separator())

                if selected.count == 1 {
                    let rename = NSMenuItem(title: NSLocalizedString("Rename…", comment: ""), action: #selector(menuRename), keyEquivalent: "")
                    rename.target = self
                    menu.addItem(rename)
                }
                let delete = NSMenuItem(title: selected.count == 1 ? NSLocalizedString("Delete…", comment: "") : String(format: NSLocalizedString("Delete %ld Items…", comment: ""), selected.count),
                                        action: #selector(menuDelete), keyEquivalent: "")
                delete.target = self
                menu.addItem(delete)

                let copyTo = NSMenuItem(title: NSLocalizedString("Copy to…", comment: ""),
                                        action: #selector(menuCopyTo), keyEquivalent: "")
                copyTo.target = self
                menu.addItem(copyTo)

                menu.addItem(.separator())
                let copy = NSMenuItem(title: NSLocalizedString("Copy Link", comment: ""), action: #selector(menuCopyURL), keyEquivalent: "")
                copy.target = self
                menu.addItem(copy)
                menu.addItem(.separator())
            }

            let newFolder = NSMenuItem(title: NSLocalizedString("New Folder…", comment: ""),
                                       action: #selector(menuNewFolder), keyEquivalent: "")
            newFolder.target = self
            menu.addItem(newFolder)

            // 右键点在文件夹上时，多给一个“在该文件夹内新建”
            if let folder = clickedFolderEntry() {
                let inside = NSMenuItem(title: String(format: NSLocalizedString("New Folder in “%@”…", comment: ""), folder.name),
                                        action: #selector(menuNewFolderInside), keyEquivalent: "")
                inside.target = self
                inside.representedObject = folder.name
                menu.addItem(inside)
            }

            let refresh = NSMenuItem(title: NSLocalizedString("Refresh", comment: ""), action: #selector(menuRefresh), keyEquivalent: "")
            refresh.target = self
            menu.addItem(refresh)
            return menu
        }

        @objc private func menuOpen() { model.openSelected() }
        @objc private func menuDownload() { model.download(entries: selectedEntries()) }
        @objc private func menuRename() { model.beginRename() }
        @objc private func menuDelete() { model.beginDelete() }
        @objc private func menuNewFolder() { model.beginNewFolder() }

        @objc private func menuNewFolderInside(_ sender: NSMenuItem) {
            guard let name = sender.representedObject as? String, let base = baseURL else { return }
            model.beginNewFolder(in: RemotePath.join(base, UploadPlanner.encodeComponent(name)))
        }

        /// 右键落在文件夹行上时返回该条目
        private func clickedFolderEntry() -> SVNEntry? {
            let row = tableView.contextMenuRow
            guard row >= 0, row < entries.count, entries[row].isDirectory else { return nil }
            return entries[row]
        }
        @objc private func menuRefresh() { model.reload() }

        @objc private func menuCopyTo() { model.beginCopy() }

        @objc private func menuCopyURL() {
            guard let base = baseURL else { return }
            let urls = selectedEntries().map { RemotePath.join(base, UploadPlanner.encodeComponent($0.name)) }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(urls.joined(separator: "\n"), forType: .string)
            model.showToast(NSLocalizedString("Link copied", comment: ""))
        }

        private func selectedEntries() -> [SVNEntry] {
            model.entries.filter { model.selection.contains($0.name) }
        }

        // MARK: 拖出（拖到 Finder 或其它 App）

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row >= 0, row < entries.count, let base = baseURL else { return nil }
            let entry = entries[row]
            let remote = RemotePath.join(base, UploadPlanner.encodeComponent(entry.name))
            let fileType: String
            if entry.isDirectory {
                fileType = "public.folder"
            } else {
                fileType = UTType(filenameExtension: (entry.name as NSString).pathExtension)?.identifier ?? "public.data"
            }
            let provider = NSFilePromiseProvider(fileType: fileType, delegate: self)
            provider.userInfo = PromiseInfo(remoteURL: remote,
                                            fileName: entry.name,
                                            options: model.svnOptions(for: remote))
            return provider
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            session.animatesToStartingPositionsOnCancelOrFail = true
        }

        nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            (filePromiseProvider.userInfo as? PromiseInfo)?.fileName ?? "file"
        }

        nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                            completionHandler: @escaping (Error?) -> Void) {
            guard let info = filePromiseProvider.userInfo as? PromiseInfo else {
                completionHandler(SVNError(kind: .general, message: NSLocalizedString("Internal error: missing download information", comment: "")))
                return
            }
            Task {
                do {
                    try await SVNClient.shared.export(url: info.remoteURL, to: url, options: info.options)
                    completionHandler(nil)
                } catch {
                    completionHandler(error)
                }
            }
        }

        // MARK: 拖入（Finder 文件 或 App 内拖动）

        private func targetRow(for row: Int) -> (row: Int, isDirectory: Bool) {
            if row >= 0, row < entries.count, entries[row].isDirectory {
                return (row, true)
            }
            return (-1, false)
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            let isInternal = (info.draggingSource as? FileListTableView) === tableView
            if !isInternal {
                let hasFiles = info.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                                    options: [.urlReadingFileURLsOnly: true])
                guard hasFiles else { return [] }
            }

            let target = targetRow(for: row)
            if target.isDirectory {
                if isInternal, let source = internalEntries(from: info),
                   source.contains(where: { $0.name == entries[target.row].name }) {
                    return []
                }
                tableView.setDropRow(target.row, dropOperation: .on)
            } else {
                tableView.setDropRow(-1, dropOperation: .on)
            }
            return isInternal ? .move : .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            let isInternal = (info.draggingSource as? FileListTableView) === tableView
            let target = targetRow(for: row)
            let targetEntry = target.isDirectory && target.row < entries.count ? entries[target.row] : nil

            if isInternal {
                let moving = internalEntries(from: info) ?? []
                guard !moving.isEmpty else { return false }
                model.handleInternalMove(entries: moving, onto: targetEntry)
            } else {
                let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
                guard !urls.isEmpty else { return false }
                model.handleExternalDrop(urls: urls, onto: targetEntry)
            }
            return true
        }

        /// 内部拖动时，从拖拽源表格读取被拖动的行
        private func internalEntries(from info: NSDraggingInfo) -> [SVNEntry]? {
            guard let source = info.draggingSource as? FileListTableView, source === tableView else { return nil }
            let selected = model.entries.filter { model.selection.contains($0.name) }
            return selected.isEmpty ? nil : selected
        }
    }
}
