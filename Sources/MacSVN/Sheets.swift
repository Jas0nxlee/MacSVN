import AppKit
import SwiftUI

// MARK: - 通用外壳

private struct SheetShell<Content: View, Buttons: View>: View {
    let title: String
    let subtitle: String?
    let icon: String
    @ViewBuilder var content: () -> Content
    @ViewBuilder var buttons: () -> Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 26))
                        .foregroundStyle(.tint)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.headline)
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                content()
            }
            .padding(20)

            Divider()
            buttons()
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(width: 540)
    }
}

private struct SheetButtons<Content: View>: View {
    let confirmTitle: String
    let destructive: Bool
    let enabled: Bool
    let busy: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @ViewBuilder var extra: () -> Content

    var body: some View {
        HStack(spacing: 10) {
            extra()
            Spacer()
            Button(NSLocalizedString("Cancel", comment: ""), action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(action: onConfirm) {
                if busy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(NSLocalizedString("Committing…", comment: ""))
                    }
                } else {
                    Text(confirmTitle)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!enabled || busy)
            .buttonStyle(.borderedProminent)
            .tint(destructive ? .red : .accentColor)
        }
    }
}

private struct ErrorLine: View {
    let text: String?

    var body: some View {
        if let text {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 登录

struct LoginSheet: View {
    @ObservedObject var prompt: LoginPrompt
    @ObservedObject var model: BrowserModel
    @FocusState private var focus: Field?

    private enum Field { case username, password }

    var body: some View {
        SheetShell(title: NSLocalizedString("Connect to Repository", comment: ""), subtitle: prompt.url, icon: "lock.shield") {
            VStack(alignment: .leading, spacing: 12) {
                Text(prompt.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        Text(NSLocalizedString("User name", comment: "")).gridColumnAlignment(.trailing)
                        TextField(NSLocalizedString("User name", comment: ""), text: $prompt.username)
                            .textFieldStyle(.roundedBorder)
                            .focused($focus, equals: .username)
                            .frame(width: 300)
                    }
                    GridRow {
                        Text(NSLocalizedString("Password", comment: "")).gridColumnAlignment(.trailing)
                        SecureField(NSLocalizedString("Password", comment: ""), text: $prompt.password)
                            .textFieldStyle(.roundedBorder)
                            .focused($focus, equals: .password)
                            .onSubmit { model.submitLoginPrompt(prompt) }
                            .frame(width: 300)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Toggle(NSLocalizedString("Remember login for 1 month (stored in Keychain)", comment: ""), isOn: $prompt.remember)
                    if prompt.needsTrust {
                        Toggle(NSLocalizedString("Trust this server's certificate (ignore validation errors)", comment: ""), isOn: $prompt.trustCertificate)
                    }
                    if let expiry = prompt.savedLoginExpiry {
                        HStack(spacing: 6) {
                            Text(String(format: NSLocalizedString("Saved login expires on %@", comment: ""), Fmt.date(expiry)))
                            Button(NSLocalizedString("Remove", comment: "")) {
                                model.forgetSavedLogin(for: prompt.url)
                                prompt.savedLoginExpiry = nil
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12))

                ErrorLine(text: prompt.errorMessage)
            }
        } buttons: {
            SheetButtons(confirmTitle: NSLocalizedString("Sign In", comment: ""),
                         destructive: false,
                         enabled: !prompt.username.trimmingCharacters(in: .whitespaces).isEmpty,
                         busy: prompt.inProgress,
                         onCancel: { model.cancelLogin() },
                         onConfirm: { model.submitLoginPrompt(prompt) }) { EmptyView() }
        }
        .onAppear { focus = prompt.username.isEmpty ? .username : .password }
    }
}

// MARK: - 上传 / 移动 确认

struct TransferSheet: View {
    @ObservedObject var prompt: TransferPrompt
    @ObservedObject var model: BrowserModel
    @FocusState private var messageFocused: Bool

    private var plan: TransferPlan { prompt.plan }
    private var isUpload: Bool { plan.mode == .upload }

    var body: some View {
        SheetShell(title: isUpload ? NSLocalizedString("Upload to Repository", comment: "") : NSLocalizedString("Move to Another Folder", comment: ""),
                   subtitle: RemotePath.prettyPath(plan.targetDir) + "/",
                   icon: isUpload ? "arrow.up.doc" : "arrow.turn.down.right") {
            VStack(alignment: .leading, spacing: 12) {
                if plan.hasBlockers {
                    blockerBox
                }
                if plan.hasConflicts {
                    warningBox
                }
                if !plan.mergedDirs.isEmpty && !plan.hasConflicts && !plan.hasBlockers {
                    infoBox(String(format: NSLocalizedString("Folder %@ already exists in the repository; its contents will be merged.", comment: ""), preview(plan.mergedDirs)))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(isUpload ? NSLocalizedString("Items to upload", comment: "") : NSLocalizedString("Items to move", comment: ""))
                        .font(.system(size: 12, weight: .semibold))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(plan.items.prefix(200), id: \.relativePath) { item in
                                HStack(spacing: 8) {
                                    Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                                        .foregroundStyle(item.isDirectory ? Color.accentColor : .secondary)
                                        .frame(width: 14)
                                    Text(item.name).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    if isBlocked(item) {
                                        badge(NSLocalizedString("Conflict", comment: ""), color: .red)
                                    } else if item.willOverwrite {
                                        badge(isUpload ? NSLocalizedString("Overwrite", comment: "") : NSLocalizedString("Conflict", comment: ""), color: .orange)
                                    } else if isUpload {
                                        badge(NSLocalizedString("New", comment: ""), color: .green)
                                    }
                                    if !item.isDirectory {
                                        Text(Fmt.size(item.size))
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .font(.system(size: 12))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .frame(height: min(CGFloat(max(plan.items.count, 1)) * 22 + 8, 132))
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                }

                HStack(spacing: 14) {
                    Text(summaryText).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    if !plan.skipped.isEmpty {
                        Text(String(format: NSLocalizedString("%ld skipped", comment: ""), plan.skipped.count))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .help(plan.skipped.prefix(50).joined(separator: "\n"))
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(NSLocalizedString("Commit message", comment: ""))
                        .font(.system(size: 12, weight: .semibold))
                    TextEditor(text: $prompt.message)
                        .font(.system(size: 12))
                        .frame(height: 62)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                        .focused($messageFocused)
                }

                if plan.actions.isEmpty && !isUpload && !plan.hasBlockers {
                    ErrorLine(text: NSLocalizedString("Nothing to move", comment: ""))
                }
                ErrorLine(text: prompt.errorMessage)
            }
        } buttons: {
            SheetButtons(confirmTitle: confirmTitle,
                         destructive: false,
                         enabled: !prompt.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                   && !plan.actions.isEmpty
                                   && !plan.hasBlockers,
                         busy: prompt.inProgress,
                         onCancel: { model.transferPrompt = nil },
                         onConfirm: { model.confirmTransfer(prompt) }) { EmptyView() }
        }
    }

    private var confirmTitle: String {
        if plan.hasBlockers { return isUpload ? NSLocalizedString("Name Conflict", comment: "") : NSLocalizedString("Cannot Move", comment: "") }
        if !isUpload { return NSLocalizedString("Move", comment: "") }
        return plan.hasConflicts ? NSLocalizedString("Overwrite and Upload", comment: "") : NSLocalizedString("Upload", comment: "")
    }

    private var blockerBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(isUpload ? NSLocalizedString("These items clash with same-named items of a different kind and cannot be committed", comment: "")
                           : NSLocalizedString("The target folder already has an item with this name", comment: ""),
                  systemImage: "xmark.octagon.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.red)
            ForEach(plan.blockers.prefix(8), id: \.path) { blocker in
                Text("\(blocker.path) — \(blocker.reason)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            if plan.blockers.count > 8 {
                Text(String(format: NSLocalizedString("and %ld more", comment: ""), plan.blockers.count)).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.10)))
    }

    private var warningBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(isUpload
                    ? NSLocalizedString("Same-named files already exist in the repository and will be overwritten", comment: "")
                    : NSLocalizedString("The target folder already has an item with this name — cancel to continue", comment: ""),
                  systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            Text(preview(plan.conflicts))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    private func infoBox(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func isBlocked(_ item: UploadItem) -> Bool {
        plan.blockers.contains {
            $0.path == item.relativePath || $0.path.hasPrefix(item.relativePath + "/")
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    private func preview(_ items: [String]) -> String {
        let shown = items.prefix(10).joined(separator: "、")
        return items.count > 10 ? String(format: NSLocalizedString("%@ and %ld more", comment: ""), shown, items.count) : shown
    }

    private var summaryText: String {
        var parts: [String] = []
        if plan.fileCount > 0 { parts.append(String(format: NSLocalizedString("%ld files", comment: ""), plan.fileCount)) }
        if plan.folderCount > 0 { parts.append(String(format: NSLocalizedString("%ld folders", comment: ""), plan.folderCount)) }
        if plan.totalBytes > 0 { parts.append(String(format: NSLocalizedString("%@ total", comment: ""), Fmt.size(plan.totalBytes))) }
        return parts.isEmpty ? "—" : parts.joined(separator: "，")
    }
}

// MARK: - 单行输入（重命名 / 新建文件夹 / 设置路径）

struct InputSheet: View {
    @ObservedObject var prompt: InputPrompt
    @ObservedObject var model: BrowserModel
    @FocusState private var textFocused: Bool

    var body: some View {
        SheetShell(title: prompt.title,
                   subtitle: prompt.note,
                   icon: prompt.kind == .newFolder ? "folder.badge.plus" : "pencil") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(prompt.fieldLabel).font(.system(size: 12, weight: .semibold))
                    TextField("", text: $prompt.text)
                        .textFieldStyle(.roundedBorder)
                        .focused($textFocused)
                        .onSubmit { submit() }
                }

                if prompt.showsMessageField {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(NSLocalizedString("Commit message", comment: ""))
                            .font(.system(size: 12, weight: .semibold))
                        TextEditor(text: $prompt.message)
                            .font(.system(size: 12))
                            .frame(height: 58)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                    }
                }

                ErrorLine(text: prompt.errorMessage)
            }
        } buttons: {
            SheetButtons(confirmTitle: prompt.confirmTitle,
                         destructive: false,
                         enabled: true,
                         busy: prompt.inProgress,
                         onCancel: { model.inputPrompt = nil },
                         onConfirm: { submit() }) { EmptyView() }
        }
        .onAppear { textFocused = true }
    }

    private func submit() {
        guard !prompt.inProgress else { return }
        if let error = prompt.validate?(prompt.text) {
            prompt.errorMessage = error
            return
        }
        prompt.errorMessage = nil
        prompt.onSubmit?(prompt.text, prompt.message)
    }
}

// MARK: - 删除确认

// MARK: - 安装 Subversion

struct InstallSheet: View {
    @ObservedObject var prompt: InstallPrompt
    @ObservedObject var model: BrowserModel

    var body: some View {
        SheetShell(title: NSLocalizedString("Install Subversion", comment: ""),
                   subtitle: prompt.brewPath.map { String(format: NSLocalizedString("Installing via Homebrew (%@)", comment: ""), $0) }
                             ?? NSLocalizedString("Homebrew not found", comment: ""),
                   icon: "shippingbox") {
            VStack(alignment: .leading, spacing: 12) {
                steps

                if !prompt.log.isEmpty {
                    logView
                }

                if case .failed(let message) = prompt.phase {
                    ErrorLine(text: message)
                }
                if case .succeeded = prompt.phase {
                    Label(NSLocalizedString("You can close this window and continue browsing", comment: ""), systemImage: "checkmark.seal.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                }
            }
        } buttons: {
            sheetButtons
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 6) {
            stepRow(index: 0,
                    title: NSLocalizedString("Detect Homebrew", comment: ""),
                    detail: prompt.brewPath ?? NSLocalizedString("brew not found", comment: ""),
                    state: prompt.brewPath == nil ? .blocked : .done)
            stepRow(index: 1,
                    title: NSLocalizedString("Run brew install subversion", comment: ""),
                    detail: phaseDetail,
                    state: stepState)
            stepRow(index: 2,
                    title: NSLocalizedString("Verify the svn command", comment: ""),
                    detail: finalDetail,
                    state: finalState)
        }
    }

    private var phaseDetail: String {
        switch prompt.phase {
        case .running: return NSLocalizedString("Downloading and installing, this may take a few minutes…", comment: "")
        case .succeeded: return NSLocalizedString("Done", comment: "")
        case .failed: return NSLocalizedString("Failed", comment: "")
        case .cancelled: return NSLocalizedString("Cancelled", comment: "")
        }
    }

    private var stepState: StepState {
        switch prompt.phase {
        case .running: return .running
        case .succeeded: return .done
        case .failed, .cancelled: return .failed
        }
    }

    private var finalDetail: String {
        switch prompt.phase {
        case .succeeded(let version): return "svn \(version)"
        default: return NSLocalizedString("Waiting for installation", comment: "")
        }
    }

    private var finalState: StepState {
        if case .succeeded = prompt.phase { return .done }
        return .pending
    }

    private enum StepState { case pending, running, done, failed, blocked }

    private func stepRow(index: Int, title: String, detail: String, state: StepState) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .running:
                    ProgressView().controlSize(.small)
                case .failed:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                case .blocked:
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                case .pending:
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(index + 1). \(title)").font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
            }
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(prompt.log.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(8)
            }
            .frame(height: 170)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .onChange(of: prompt.log.count) { _ in
                withAnimation(nil) {
                    proxy.scrollTo(prompt.log.count - 1, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private var sheetButtons: some View {
        HStack(spacing: 10) {
            switch prompt.phase {
            case .running:
                Button(NSLocalizedString("Install in Terminal", comment: "")) { model.installInTerminal() }
                Spacer()
                Button(NSLocalizedString("Cancel", comment: "")) { prompt.onCancel?() }
                Button(NSLocalizedString("Continue in Background", comment: "")) { model.installPrompt = nil }
                    .buttonStyle(.borderedProminent)
            case .succeeded:
                Button(NSLocalizedString("Set SVN Path…", comment: "")) { model.installPrompt = nil; model.beginSetSVNPath() }
                Spacer()
                Button(NSLocalizedString("Done", comment: "")) { model.installPrompt = nil }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            case .failed:
                Button(NSLocalizedString("Copy Command", comment: "")) { model.copyInstallCommand() }
                Button(NSLocalizedString("Install in Terminal", comment: "")) { model.installInTerminal() }
                Spacer()
                Button(NSLocalizedString("Close", comment: "")) { model.installPrompt = nil }
                    .keyboardShortcut(.cancelAction)
            case .cancelled:
                Spacer()
                Button(NSLocalizedString("Close", comment: "")) { model.installPrompt = nil }
                    .keyboardShortcut(.cancelAction)
                Button(NSLocalizedString("Try Again", comment: "")) { prompt.onRetry?() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct DeleteSheet: View {
    @ObservedObject var prompt: DeletePrompt
    @ObservedObject var model: BrowserModel

    var body: some View {
        SheetShell(title: NSLocalizedString("Confirm Deletion", comment: ""),
                   subtitle: NSLocalizedString("Deleting commits to the repository immediately and cannot be undone.", comment: ""),
                   icon: "trash") {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(prompt.entries) { entry in
                            HStack(spacing: 8) {
                                Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                                    .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                                    .frame(width: 14)
                                Text(entry.name).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(entry.revisionText).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(height: min(CGFloat(max(prompt.entries.count, 1)) * 22 + 8, 120))
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))

                VStack(alignment: .leading, spacing: 5) {
                    Text(NSLocalizedString("Commit message", comment: ""))
                        .font(.system(size: 12, weight: .semibold))
                    TextEditor(text: $prompt.message)
                        .font(.system(size: 12))
                        .frame(height: 58)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                }

                ErrorLine(text: prompt.errorMessage)
            }
        } buttons: {
            SheetButtons(confirmTitle: prompt.entries.count == 1 ? NSLocalizedString("Delete", comment: "") : String(format: NSLocalizedString("Delete %ld Items", comment: ""), prompt.entries.count),
                         destructive: true,
                         enabled: !prompt.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                         busy: prompt.inProgress,
                         onCancel: { model.deletePrompt = nil },
                         onConfirm: { model.confirmDelete(prompt) }) { EmptyView() }
        }
    }
}
