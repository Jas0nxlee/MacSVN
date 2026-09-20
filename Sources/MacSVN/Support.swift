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
        guard !text.isEmpty else { return (nil, NSLocalizedString("Enter a repository URL", comment: "")) }

        // 中文、空格等编成 %XX；已经是编码形态的部分保持不动
        text = encodePathForRequest(text)

        if text.hasPrefix("/") {
            text = "file://" + text
        }

        if let range = text.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) {
            let scheme = String(text[text.startIndex..<range.upperBound].dropLast(3))
            guard isSupportedScheme(scheme) else {
                return (nil, String(format: NSLocalizedString("Unsupported scheme \"%@://\". Use http, https, svn or svn+ssh.", comment: ""), scheme))
            }
        } else {
            text = "https://" + text
        }

        while text.hasSuffix("/") && !text.hasSuffix("://") {
            if text.hasSuffix("://") { break }
            text.removeLast()
        }

        guard let parsed = URL(string: text) else {
            return (nil, String(format: NSLocalizedString("Malformed address: %@", comment: ""), raw))
        }
        if (parsed.host ?? "").isEmpty && parsed.scheme != "file" {
            return (nil, String(format: NSLocalizedString("The address is missing a host name: %@", comment: ""), raw))
        }
        return (text, nil)
    }

    /// 显示用：把路径里的百分号编码还原成可读文字（请求仍然使用原始 URL）。
    /// 逐段解码，避免 %2F 之类被误解成路径分隔符。
    static func display(_ url: String) -> String {
        guard url.contains("%") else { return url }
        guard let schemeRange = url.range(of: "://") else { return decodePath(url) }
        let head = String(url[url.startIndex..<schemeRange.upperBound])
        let rest = String(url[schemeRange.upperBound...])
        guard let slash = rest.firstIndex(of: "/") else { return url }
        let authority = String(rest[rest.startIndex..<slash])
        return head + authority + decodePath(String(rest[slash...]))
    }

    private static func decodePath(_ text: String) -> String {
        text.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.removingPercentEncoding ?? String($0) }
            .joined(separator: "/")
    }

    /// 请求用：把可读文本里的非 ASCII、空格等编码；已是 %XX 的保持原样
    static func encodePathForRequest(_ text: String) -> String {
        guard let schemeRange = text.range(of: "://") else {
            return encodeIfNeeded(text)
        }
        let head = String(text[text.startIndex..<schemeRange.upperBound])
        let rest = String(text[schemeRange.upperBound...])
        guard let slash = rest.firstIndex(of: "/") else {
            // 只有主机名：端口、域名都不需要编码
            return text
        }
        let authority = String(rest[rest.startIndex..<slash])
        var path = String(rest[slash...])
        // 保留结尾的斜杠
        let trailingSlash = path.hasSuffix("/") && path.count > 1
        if trailingSlash { path.removeLast() }
        let encoded = encodeIfNeeded(path)
        return head + authority + encoded + (trailingSlash ? "/" : "")
    }

    /// 单段名称编码：中文、空格等编成 %XX，"/?#%" 不保留
    static func encodeComponent(_ name: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
    }

    private static func encodeIfNeeded(_ text: String) -> String {
        text.split(separator: "/", omittingEmptySubsequences: false)
            .map { component -> String in
                let piece = String(component)
                if piece.contains("%"), piece.removingPercentEncoding != nil {
                    return piece                       // 已经是编码形态
                }
                return encodeComponent(piece)
            }
            .joined(separator: "/")
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
            crumbs.append((c.removingPercentEncoding ?? c, current))
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
