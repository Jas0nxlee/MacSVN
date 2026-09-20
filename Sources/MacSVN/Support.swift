import Foundation

// MARK: - 格式化

enum Fmt {
    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    private static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func size(_ value: Int64?) -> String {
        guard let value, value >= 0 else { return "—" }
        return bytes.string(fromByteCount: value)
    }

    static func date(_ value: Date?) -> String {
        guard let value else { return "—" }
        return dateTime.string(from: value)
    }
}

// MARK: - 远程路径工具

enum RemotePath {
    /// 可接受的协议；svn+xxx 形式统一放行
    static func isSupportedScheme(_ scheme: String) -> Bool {
        let s = scheme.lowercased()
        return ["http", "https", "svn", "file"].contains(s) || s.hasPrefix("svn+")
    }

    /// 把用户输入整理成规范的仓库地址。返回 nil 时 error 里是中文提示。
    static func normalize(_ raw: String) -> (url: String?, error: String?) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return (nil, "请输入仓库地址") }

        if text.contains(" ") {
            text = text.replacingOccurrences(of: " ", with: "%20")
        }

        if text.hasPrefix("/") {
            text = "file://" + text
        }

        if let range = text.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) {
            let scheme = String(text[text.startIndex..<range.upperBound].dropLast(3))
            guard isSupportedScheme(scheme) else {
                return (nil, "不支持的协议“\(scheme)://”，请使用 http、https、svn 或 svn+ssh")
            }
        } else {
            text = "https://" + text
        }

        while text.hasSuffix("/") && !text.hasSuffix("://") {
            if text.hasSuffix("://") { break }
            text.removeLast()
        }

        guard let parsed = URL(string: text) else {
            return (nil, "地址格式不正确：\(raw)")
        }
        if (parsed.host ?? "").isEmpty && parsed.scheme != "file" {
            return (nil, "地址中缺少主机名：\(raw)")
        }
        return (text, nil)
    }

    static func join(_ base: String, _ component: String) -> String {
        var b = base
        while b.hasSuffix("/") { b.removeLast() }
        var c = component
        while c.hasPrefix("/") { c.removeFirst() }
        return b + "/" + c
    }

    static func parent(of url: String) -> String? {
        guard let schemeRange = url.range(of: "://") else { return nil }
        let pathStart = schemeRange.upperBound
        guard let lastSlash = url[pathStart...].lastIndex(of: "/") else { return nil }
        if lastSlash == url.index(before: pathStart) { return nil }
        let parent = String(url[url.startIndex..<lastSlash])
        return parent.isEmpty ? nil : parent
    }

    static func lastComponent(_ url: String) -> String {
        var u = url
        while u.hasSuffix("/") { u.removeLast() }
        guard let slash = u.lastIndex(of: "/") else { return u }
        return String(u[u.index(after: slash)...])
    }

    /// 面包屑：[("trunk", "https://host/repo/trunk"), ...]
    static func breadcrumbs(_ url: String) -> [(name: String, url: String)] {
        guard let schemeRange = url.range(of: "://") else { return [] }
        let scheme = String(url[url.startIndex..<schemeRange.lowerBound])
        let rest = String(url[schemeRange.upperBound...])
        var components = rest.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return [(scheme + "://", url)] }

        let authority = components.removeFirst()
        var crumbs: [(String, String)] = [(authority, "\(scheme)://\(authority)")]
        var current = "\(scheme)://\(authority)"
        if scheme == "file" {
            // file:// 没有主机名，第一段其实是路径的一部分
            crumbs = [("/", "\(scheme)://")]
            current = "\(scheme)://"
        }
        for c in components {
            current += "/" + c
            crumbs.append((c, current))
        }
        return crumbs
    }

    /// 判断 child 是否等于 base 或位于 base 之下
    static func isDescendant(_ child: String, of base: String) -> Bool {
        let b = base.hasSuffix("/") ? base : base + "/"
        return child == base || child.hasPrefix(b)
    }

    /// 用于凭据归组的键
    static func hostKey(_ url: String) -> String {
        guard let schemeRange = url.range(of: "://") else { return url }
        let scheme = String(url[url.startIndex..<schemeRange.lowerBound])
        let rest = url[schemeRange.upperBound...]
        let authority = rest.split(separator: "/").first.map(String.init) ?? ""
        return "\(scheme)://\(authority)"
    }

    /// 展示用：把完整地址压缩成 主机/…/末级
    static func prettyPath(_ url: String) -> String {
        let crumbs = breadcrumbs(url)
        guard crumbs.count > 1 else { return url }
        return crumbs.dropFirst().map(\.name).joined(separator: "/")
    }
}

// MARK: - 其它

enum Toolkit {
    static func runOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    /// svn 服务端返回的时间戳：2026-09-18T10:03:00.891433Z
    static let svnDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let svnDateFormatterNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseSvnDate(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return svnDateFormatter.date(from: text) ?? svnDateFormatterNoFraction.date(from: text)
    }
}
