import AppKit
import SwiftUI

extension Notification.Name {
    static let macSVNFocusAddress = Notification.Name("MacSVNFocusAddress")
    static let macSVNReload = Notification.Name("MacSVNReload")
    static let macSVNBack = Notification.Name("MacSVNBack")
    static let macSVNForward = Notification.Name("MacSVNForward")
    static let macSVNUp = Notification.Name("MacSVNUp")
    static let macSVNDownload = Notification.Name("MacSVNDownload")
    static let macSVNNewFolder = Notification.Name("MacSVNNewFolder")
    static let macSVNDelete = Notification.Name("MacSVNDelete")
    static let macSVNRename = Notification.Name("MacSVNRename")
}

/// 顶部留白区域：拖动它可以移动窗口
struct WindowDragHandle: NSViewRepresentable {
    final class View: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
    func makeNSView(context: Context) -> NSView { View() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct BrowserView: View {
    @ObservedObject var model: BrowserModel
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            WindowDragHandle().frame(height: 26)
            navigationBar
            Divider()
            pathBar
            Divider()
            content
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { toastOverlay }
        .overlay { busyOverlay }
        .alert(model.errorBox?.title ?? "",
               isPresented: Binding(get: { model.errorBox != nil },
                                    set: { if !$0 { model.errorBox = nil } }),
               presenting: model.errorBox) { box in
            if box.offersInstall {
                Button(NSLocalizedString("Install Subversion…", comment: "")) {
                    model.errorBox = nil
                    model.beginInstallSubversion()
                }
            }
            Button(NSLocalizedString("OK", comment: ""), role: .cancel) { model.errorBox = nil }
        } message: { box in
            Text(box.message + (box.detail.isEmpty ? "" : "\n\n" + box.detail))
        }
        .sheet(item: $model.loginPrompt) { prompt in
            LoginSheet(prompt: prompt, model: model)
        }
        .sheet(item: $model.transferPrompt) { prompt in
            TransferSheet(prompt: prompt, model: model)
        }
        .sheet(item: $model.inputPrompt) { prompt in
            InputSheet(prompt: prompt, model: model)
        }
        .sheet(item: $model.deletePrompt) { prompt in
            DeleteSheet(prompt: prompt, model: model)
        }
        .sheet(item: $model.installPrompt) { prompt in
            InstallSheet(prompt: prompt, model: model)
        }
        .onReceive(NotificationCenter.default.publisher(for: .macSVNFocusAddress)) { _ in
            addressFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .macSVNReload)) { _ in model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .macSVNBack)) { _ in model.goBack() }
        .onReceive(NotificationCenter.default.publisher(for: .macSVNForward)) { _ in model.goForward() }
        .onReceive(NotificationCenter.default.publisher(for: .macSVNUp)) { _ in model.goUp() }
        .onReceive(NotificationCenter.default.publisher(for: .macSVNDownload)) { _ in
            model.download(entries: model.selectedEntryList)
        }
        .onReceive(NotificationCenter.default.publisher(for: .macSVNNewFolder)) { _ in model.beginNewFolder() }
        .onReceive(NotificationCenter.default.publisher(for: .macSVNDelete)) { _ in model.beginDelete() }
        .onReceive(NotificationCenter.default.publisher(for: .macSVNRename)) { _ in model.beginRename() }
        .onAppear { model.refreshEnvironment() }
    }

    // MARK: 导航条

    private var navigationBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                Button { model.goBack() } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!model.canGoBack)
                .help(NSLocalizedString("Back", comment: ""))

                Button { model.goForward() } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!model.canGoForward)
                .help(NSLocalizedString("Forward", comment: ""))
            }
            .buttonStyle(.borderless)
            .font(.system(size: 15, weight: .medium))

            addressField

            Button {
                model.download(entries: model.selectedEntryList)
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .disabled(model.selectedEntryList.isEmpty)
            .help(NSLocalizedString("Download selected items", comment: ""))
            .buttonStyle(.borderless)

            Menu {
                if let login = model.savedLogin(for: model.currentURL) {
                    Text(String(format: NSLocalizedString("Signed in as %@", comment: ""), login.username))
                    Text(String(format: NSLocalizedString("Saved login expires on %@", comment: ""), Fmt.date(login.expiresAt)))
                    Divider()
                    Button(NSLocalizedString("Log Out", comment: "")) { model.logOut() }
                } else {
                    Text(NSLocalizedString("No saved login for this server", comment: ""))
                }
            } label: {
                Image(systemName: "person.crop.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
            .help(NSLocalizedString("Login", comment: ""))

            Menu {
                if model.recents.isEmpty {
                    Text(NSLocalizedString("No recent repositories", comment: ""))
                } else {
                    ForEach(model.recents, id: \.self) { url in
                        Button(url) { model.open(url: url) }
                    }
                    Divider()
                    Button(NSLocalizedString("Clear Recents", comment: "")) { model.forgetRecents() }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
            .help(NSLocalizedString("Recent repositories", comment: ""))
        }
        .padding(.leading, 78)   // 避让窗口左上角的红绿灯按钮
        .padding(.trailing, 14)
        .padding(.vertical, 8)
    }

    private var addressField: some View {
        HStack(spacing: 6) {
            if model.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: schemeIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(schemeIconColor)
            }

            TextField(NSLocalizedString("Enter a repository URL, e.g. https://svn.example.com/repo/trunk", comment: ""), text: $model.addressText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($addressFocused)
                .onSubmit { model.submitAddress() }

            if !model.addressText.isEmpty {
                Button {
                    model.addressText = ""
                    addressFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help(NSLocalizedString("Clear", comment: ""))
            }

            if model.currentURL != nil {
                Button {
                    model.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isLoading)
                .help(NSLocalizedString("Reload (⌘R)", comment: ""))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(addressFocused ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: addressFocused ? 2 : 1))
        )
    }

    private var schemeIcon: String {
        guard let url = model.currentURL else { return "network" }
        if url.hasPrefix("https://") || url.hasPrefix("svn+ssh://") { return "lock.fill" }
        if url.hasPrefix("file://") { return "internaldrive" }
        return "lock.open.fill"
    }

    private var schemeIconColor: Color {
        guard let url = model.currentURL else { return .secondary }
        if url.hasPrefix("https://") || url.hasPrefix("svn+ssh://") { return .secondary }
        return .orange
    }

    // MARK: 路径面包屑

    private var pathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                if let current = model.currentURL {
                    ForEach(Array(RemotePath.breadcrumbs(current).enumerated()), id: \.offset) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.compact.right")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        Button {
                            model.open(url: crumb.url)
                        } label: {
                            Text(crumb.name)
                                .font(.system(size: 11.5, weight: index == RemotePath.breadcrumbs(current).count - 1 ? .semibold : .regular))
                                .foregroundStyle(index == RemotePath.breadcrumbs(current).count - 1 ? .primary : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(crumb.url)
                    }
                } else {
                    Text(NSLocalizedString("No repository open", comment: "")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }

    // MARK: 内容

    private var content: some View {
        ZStack {
            FileTableView(model: model)
                .opacity(model.entries.isEmpty && !model.isLoading ? 0.0 : 1.0)
                .allowsHitTesting(!(model.entries.isEmpty && !model.isLoading))

            if model.isLoading && model.entries.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(model.loadingMessage).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else if model.entries.isEmpty {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if model.environmentWarning != nil {
                InstallGuideCard(model: model)
            } else if model.currentURL != nil {
                Image(systemName: "folder")
                    .font(.system(size: 34))
                    .foregroundStyle(.tertiary)
                Text(NSLocalizedString("This folder is empty", comment: "")).font(.system(size: 13))
                Text(NSLocalizedString("Drag files or folders here from Finder to upload", comment: ""))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.system(size: 38))
                    .foregroundStyle(.tertiary)
                Text(NSLocalizedString("Enter a repository URL and press Return", comment: "")).font(.system(size: 13))
                Text(model.svnVersion.map { String(format: NSLocalizedString("svn %@ detected", comment: ""), $0) } ?? NSLocalizedString("svn command not found", comment: ""))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(40)
    }

    // MARK: 状态栏

    private var statusBar: some View {
        HStack(spacing: 12) {
            if model.selection.isEmpty {
                Text(model.currentURL == nil ? NSLocalizedString("Ready", comment: "") : String(format: NSLocalizedString("%ld items", comment: ""), model.entries.count))
            } else {
                Text(String(format: NSLocalizedString("%ld selected", comment: ""), model.selection.count))
            }
            Spacer()
            if let info = model.repoInfo, let revision = info.revision {
                Text(String(format: NSLocalizedString("Repository revision r%ld", comment: ""), revision))
            }
            if let version = model.svnVersion {
                Text("svn \(version)")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    // MARK: 浮层

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = model.toast {
            HStack(spacing: 8) {
                Image(systemName: toast.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                Text(toast.text).font(.system(size: 12))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(toast.isError ? Color.red.opacity(0.92) : Color(nsColor: .darkGray).opacity(0.92))
            )
            .foregroundStyle(.white)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var busyOverlay: some View {
        if model.busy {
            ZStack {
                Color.black.opacity(0.15).ignoresSafeArea()
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(model.busyMessage).font(.system(size: 12))
                    Button(NSLocalizedString("Cancel", comment: "")) { SVNClient.shared.cancelAll() }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
                .shadow(radius: 12)
            }
        }
    }
}

/// 未检测到 svn 时的首屏引导：一键用 Homebrew 安装
struct InstallGuideCard: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)

            Text(NSLocalizedString("Subversion is required", comment: ""))
                .font(.system(size: 15, weight: .semibold))

            Text(NSLocalizedString("MacSVN talks to repositories through the command-line svn / svnmucc, which macOS no longer ships.", comment: ""))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            HStack(spacing: 6) {
                Image(systemName: model.brewPath != nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(model.brewPath != nil ? .green : .orange)
                Text(model.brewPath != nil
                     ? String(format: NSLocalizedString("Homebrew found: %@", comment: ""), model.brewPath!)
                     : NSLocalizedString("Homebrew not found — install it first", comment: ""))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 460)

            HStack(spacing: 10) {
                if model.brewPath != nil {
                    Button {
                        model.beginInstallSubversion()
                    } label: {
                        Label(NSLocalizedString("Install Subversion with Homebrew", comment: ""), systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        model.beginInstallHomebrew()
                    } label: {
                        Label(NSLocalizedString("Install Homebrew (opens Terminal)", comment: ""), systemImage: "terminal")
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button(NSLocalizedString("Re-check", comment: "")) { model.recheckEnvironment() }
                Button(NSLocalizedString("Set SVN Path…", comment: "")) { model.beginSetSVNPath() }
            }
            .font(.system(size: 12))

            Text(model.brewPath != nil
                 ? NSLocalizedString("Or run it yourself: brew install subversion", comment: "")
                 : NSLocalizedString("Installing Homebrew needs an administrator password, so it runs in Terminal", comment: ""))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(40)
    }
}
