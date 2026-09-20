import Foundation

// MARK: - 目录项

struct SVNEntry: Identifiable, Hashable {
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let revision: Int?
    let author: String?
    let date: Date?

    var id: String { name }
    var displayName: String { name }

    var typeText: String { isDirectory ? "文件夹" : "文件" }
    var sizeText: String { isDirectory ? "—" : Fmt.size(size) }
    var revisionText: String { revision.map { "r\($0)" } ?? "—" }
    var authorText: String { author?.isEmpty == false ? author! : "—" }
    var dateText: String { Fmt.date(date) }
}

// MARK: - 凭据

struct Credentials: Equatable {
    var username: String
    var password: String
}

// MARK: - 仓库信息

struct RepositoryInfo {
    var url: String
    var root: String
    var uuid: String
    var revision: Int?
    var lastAuthor: String?
    var lastDate: Date?
}

// MARK: - 错误

enum SVNErrorKind {
    case authRequired      // 需要登录
    case authFailed        // 用户名或密码错误
    case certificate       // 证书不受信任
    case notFound          // 路径不存在
    case connection        // 网络/连接失败
    case conflict          // 目标已存在等冲突
    case cancelled
    case timeout
    case toolMissing       // 找不到 svn 可执行文件
    case general

    var needsCredentialPrompt: Bool {
        self == .authRequired || self == .authFailed || self == .certificate
    }
}

struct SVNError: LocalizedError {
    let kind: SVNErrorKind
    var code: String?
    let message: String
    let raw: String

    var errorDescription: String? { message }
    var detail: String { raw.isEmpty ? message : raw }

    init(kind: SVNErrorKind, code: String? = nil, message: String, raw: String = "") {
        self.kind = kind
        self.code = code
        self.message = message
        self.raw = raw
    }

    /// 依据 svn 的 stderr 判断错误类型，并给出中文提示。
    static func classify(stderr: String, stdout: String = "", hadCredentials: Bool) -> SVNError {
        let text = stderr.isEmpty ? stdout : stderr
        let lower = text.lowercased()
        let code = extractCode(text)

        func make(_ kind: SVNErrorKind, _ message: String) -> SVNError {
            SVNError(kind: kind, code: code, message: message, raw: text)
        }

        // 证书问题
        if lower.contains("certificate verification failed")
            || lower.contains("server certificate verification failed")
            || lower.contains("certificate has expired")
            || lower.contains("e230001")
            || lower.contains("issuer is not trusted") {
            return make(.certificate, "服务器证书不受信任，无法建立安全连接")
        }

        // 认证问题：还没提供凭据时一律视为“需要登录”，
        // 只有真的送过凭据被拒时才判定为登录失败。
        let authCodePresent = lower.contains("e170001") || lower.contains("e215004") || lower.contains("e120171")
        if authCodePresent || lower.contains("no more credentials") {
            guard hadCredentials else {
                return make(.authRequired, "该仓库需要登录后才能访问")
            }
            if lower.contains("password incorrect")
                || lower.contains("authentication error from server")
                || lower.contains("authorization failed")
                || lower.contains("could not authenticate")
                || lower.contains("authentication required") {
                return make(.authFailed, "用户名或密码错误")
            }
            return make(.authFailed, "登录失败，请检查用户名或密码")
        }

        if lower.contains("e160013") || lower.contains("w160013") || lower.contains("path") && lower.contains("not found") {
            return make(.notFound, "路径不存在：" + describePath(in: text))
        }
        if lower.contains("already exists") || lower.contains("e160016") && lower.contains("not a directory") {
            return make(.conflict, "目标已存在同名项")
        }
        if lower.contains("e155010") || lower.contains("file already exists") {
            return make(.conflict, "目标已存在同名文件")
        }
        if lower.contains("e170013") || lower.contains("e670003") || lower.contains("e000061")
            || lower.contains("e175002") || lower.contains("e730061")
            || lower.contains("connection refused") || lower.contains("could not resolve hostname")
            || lower.contains("unable to connect") || lower.contains("timed out") {
            return make(.connection, "无法连接到仓库服务器，请检查地址与网络")
        }
        if lower.contains("e200007") || lower.contains("not a working copy") {
            return make(.general, describePath(in: text))
        }
        return make(.general, firstMessageLine(text))
    }

    private static func extractCode(_ text: String) -> String? {
        guard let range = text.range(of: "[EW][0-9]{6}", options: .regularExpression) else { return nil }
        return String(text[range])
    }

    private static func describePath(in text: String) -> String {
        if let range = text.range(of: "'[^']+'", options: .regularExpression) {
            return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        }
        return firstMessageLine(text)
    }

    private static func firstMessageLine(_ text: String) -> String {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let range = trimmed.range(of: "^[EW][0-9]{6}:\\s*", options: .regularExpression) {
                return String(trimmed[range.upperBound...])
            }
            return trimmed
        }
        return "操作失败"
    }
}

// MARK: - 写操作动作（对应 svnmucc）

enum SVNMAction {
    case mkdir(String)
    case move(from: String, to: String)
    case remove(String)
    case put(local: URL, remote: String)
}

// MARK: - 库中同名项的类型

enum RemoteKind {
    case file
    case directory

    var isDirectory: Bool { self == .directory }
}

/// 无法通过提交解决的冲突（文件与文件夹同名等）
struct TransferBlocker {
    let path: String
    let reason: String
}

// MARK: - 上传/移动的待确认计划

struct UploadItem {
    let localURL: URL
    let name: String
    let relativePath: String
    let isDirectory: Bool
    let size: Int64
    var willOverwrite: Bool = false
}

struct TransferPlan {
    enum Mode {
        case upload
        case move
    }

    var mode: Mode
    var targetDir: String
    var actions: [SVNMAction]
    var items: [UploadItem]
    var conflicts: [String]        // 会被覆盖的相对路径
    var blockers: [TransferBlocker] = []   // 类型冲突，无法提交
    var mergedDirs: [String]       // 库中已存在、将合并的目录
    var fileCount: Int
    var folderCount: Int
    var totalBytes: Int64
    var skipped: [String]          // 被跳过的文件（.DS_Store、.svn 等）

    var hasConflicts: Bool { !conflicts.isEmpty }
    var hasBlockers: Bool { !blockers.isEmpty }
}
