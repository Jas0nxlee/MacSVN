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
            Button("取消", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(action: onConfirm) {
                if busy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("提交中…")
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
        SheetShell(title: "连接到版本库", subtitle: prompt.url, icon: "lock.shield") {
            VStack(alignment: .leading, spacing: 12) {
                Text(prompt.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        Text("用户名").gridColumnAlignment(.trailing)
                        TextField("用户名", text: $prompt.username)
                            .textFieldStyle(.roundedBorder)
                            .focused($focus, equals: .username)
                            .frame(width: 300)
                    }
                    GridRow {
                        Text("密码").gridColumnAlignment(.trailing)
                        SecureField("密码", text: $prompt.password)
                            .textFieldStyle(.roundedBorder)
                            .focused($focus, equals: .password)
                            .onSubmit { model.submitLoginPrompt(prompt) }
                            .frame(width: 300)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("记住密码（保存到系统钥匙串）", isOn: $prompt.remember)
                    if prompt.needsTrust {
                        Toggle("信任该服务器的证书（忽略证书校验错误）", isOn: $prompt.trustCertificate)
                    }
                }
                .font(.system(size: 12))

                ErrorLine(text: prompt.errorMessage)
            }
        } buttons: {
            SheetButtons(confirmTitle: "登录",
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
        SheetShell(title: isUpload ? "上传到版本库" : "移动到其它目录",
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
                    infoBox("文件夹 \(preview(plan.mergedDirs)) 在库中已存在，将合并内容。")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(isUpload ? "待上传内容" : "待移动内容")
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
                                        badge("冲突", color: .red)
                                    } else if item.willOverwrite {
                                        badge(isUpload ? "覆盖" : "冲突", color: .orange)
                                    } else if isUpload {
                                        badge("新增", color: .green)
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
                        Text("已跳过 \(plan.skipped.count) 项")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .help(plan.skipped.prefix(50).joined(separator: "\n"))
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("提交信息（commit message）")
                        .font(.system(size: 12, weight: .semibold))
                    TextEditor(text: $prompt.message)
                        .font(.system(size: 12))
                        .frame(height: 62)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                        .focused($messageFocused)
                }

                if plan.actions.isEmpty && !isUpload && !plan.hasBlockers {
                    ErrorLine(text: "没有可移动的内容")
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
        if plan.hasBlockers { return isUpload ? "存在同名项冲突" : "无法移动" }
        if !isUpload { return "移动" }
        return plan.hasConflicts ? "覆盖并上传" : "上传"
    }

    private var blockerBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(isUpload ? "以下项目与库中同名的文件夹/文件类型不一致，无法提交"
                           : "目标目录已存在同名项，无法移动",
                  systemImage: "xmark.octagon.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.red)
            ForEach(plan.blockers.prefix(8), id: \.path) { blocker in
                Text("\(blocker.path) — \(blocker.reason)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            if plan.blockers.count > 8 {
                Text("等 \(plan.blockers.count) 项").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.10)))
    }

    private var warningBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(isUpload
                    ? "库中已存在同名文件，提交后将覆盖原文件"
                    : "目标目录已存在同名项，无法移动，请先取消",
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
        return items.count > 10 ? "\(shown) 等 \(items.count) 项" : shown
    }

    private var summaryText: String {
        var parts: [String] = []
        if plan.fileCount > 0 { parts.append("\(plan.fileCount) 个文件") }
        if plan.folderCount > 0 { parts.append("\(plan.folderCount) 个文件夹") }
        if plan.totalBytes > 0 { parts.append("共 \(Fmt.size(plan.totalBytes))") }
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
                        Text("提交信息（commit message）")
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
        SheetShell(title: "安装 Subversion",
                   subtitle: prompt.brewPath.map { "通过 Homebrew 安装（\($0)）" }
                             ?? "未检测到 Homebrew",
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
                    Label("可以关闭此窗口，回到主界面继续浏览仓库了", systemImage: "checkmark.seal.fill")
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
                    title: "检测 Homebrew",
                    detail: prompt.brewPath ?? "未找到 brew 命令",
                    state: prompt.brewPath == nil ? .blocked : .done)
            stepRow(index: 1,
                    title: "执行 brew install subversion",
                    detail: phaseDetail,
                    state: stepState)
            stepRow(index: 2,
                    title: "校验 svn 命令可用",
                    detail: finalDetail,
                    state: finalState)
        }
    }

    private var phaseDetail: String {
        switch prompt.phase {
        case .running: return "正在下载并安装，可能需要几分钟…"
        case .succeeded: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
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
        default: return "等待安装完成"
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
                Button("在终端中安装") { model.installInTerminal() }
                Spacer()
                Button("取消") { prompt.onCancel?() }
                Button("后台继续") { model.installPrompt = nil }
                    .buttonStyle(.borderedProminent)
            case .succeeded:
                Button("设置 SVN 路径…") { model.installPrompt = nil; model.beginSetSVNPath() }
                Spacer()
                Button("完成") { model.installPrompt = nil }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            case .failed:
                Button("复制命令") { model.copyInstallCommand() }
                Button("在终端中安装") { model.installInTerminal() }
                Spacer()
                Button("关闭") { model.installPrompt = nil }
                    .keyboardShortcut(.cancelAction)
            case .cancelled:
                Spacer()
                Button("关闭") { model.installPrompt = nil }
                    .keyboardShortcut(.cancelAction)
                Button("重试") { prompt.onRetry?() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct DeleteSheet: View {
    @ObservedObject var prompt: DeletePrompt
    @ObservedObject var model: BrowserModel

    var body: some View {
        SheetShell(title: "确认删除",
                   subtitle: "删除会立即提交到版本库，且无法撤销。",
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
                    Text("提交信息（commit message）")
                        .font(.system(size: 12, weight: .semibold))
                    TextEditor(text: $prompt.message)
                        .font(.system(size: 12))
                        .frame(height: 58)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                }

                ErrorLine(text: prompt.errorMessage)
            }
        } buttons: {
            SheetButtons(confirmTitle: prompt.entries.count == 1 ? "删除" : "删除 \(prompt.entries.count) 项",
                         destructive: true,
                         enabled: !prompt.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                         busy: prompt.inProgress,
                         onCancel: { model.deletePrompt = nil },
                         onConfirm: { model.confirmDelete(prompt) }) { EmptyView() }
        }
    }
}
