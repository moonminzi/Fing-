import Foundation

/// 열린 포트에 직접 연결해 읽은 소개 글(배너). 이름이 없는 공유기·AP·프린터·NAS를 알아보는 단서다.
public struct ServiceBanner: Hashable, Sendable {
    public let port: UInt16
    /// HTTP `Server` 헤더("lighttpd/1.4.59" 같은)
    public var server: String?
    /// 웹 페이지 `<title>`
    public var title: String?
    /// HTTP 인증 창의 영역 이름(`WWW-Authenticate: Basic realm="..."`). 공유기는 모델명을 넣는 일이 많다
    public var realm: String?
    /// HTTPS 인증서의 이름
    public var certificate: String?
    /// SSH 버전 문자열("OpenSSH_9.6p1 Ubuntu-3ubuntu13" 같은)
    public var ssh: String?

    public init(port: UInt16, server: String? = nil, title: String? = nil, realm: String? = nil,
                certificate: String? = nil, ssh: String? = nil) {
        self.port = port
        self.server = server
        self.title = title
        self.realm = realm
        self.certificate = certificate
        self.ssh = ssh
    }

    /// 기기 이름으로 쓸 만한 제품명. 로그인·오류 같은 흔한 제목이나 IP 모양 인증서 이름은 버린다.
    public var productName: String? {
        [realm, title, certificate].lazy.compactMap { $0 }.first(where: Self.isMeaningful)
    }

    /// 종류를 짐작할 때 훑어볼 글 전부
    public var hints: [String] {
        [server, title, realm, certificate, ssh].compactMap { $0 }
    }

    static func isMeaningful(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard text.count >= 2, !text.contains("\u{FFFD}"), IPv4(text) == nil else { return false }
        if lower.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) { return false }
        let generic = [
            "login", "log in", "sign in", "index of", "not found", "error", "redirect", "untitled", "document",
            "welcome", "loading", "web server", "default", "home page", "forbidden", "unauthorized", "moved",
            "bad request", "localhost", "please wait", "it works", "test page", "web ui", "web management",
            "로그인", "접속", "오류",
        ]
        if generic.contains(where: { lower.contains($0) }) { return false }
        if ["404", "403", "401", "400", "500", "502", "503"].contains(where: { lower.hasPrefix($0) }) { return false }
        return true
    }
}

extension ServiceBanner {
    /// HTTP 응답(머리 + 몸 앞부분)에서 배너를 만든다. HTTP 응답이 아니면 nil.
    public static func http(port: UInt16, response bytes: [UInt8], certificate: String? = nil) -> ServiceBanner? {
        let text = String(decoding: bytes.prefix(64 * 1024), as: UTF8.self)
        guard text.hasPrefix("HTTP/") else {
            return certificate.map { ServiceBanner(port: port, certificate: clean($0)) }
        }
        let headerEnd = text.range(of: "\r\n\r\n") ?? text.range(of: "\n\n")
        let head = headerEnd.map { String(text[..<$0.lowerBound]) } ?? text
        let body = headerEnd.map { String(text[$0.upperBound...]) } ?? ""

        var server: String?
        var realm: String?
        for line in head.split(whereSeparator: \.isNewline).dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "server": server = clean(value)
            case "www-authenticate": realm = quotedValue(named: "realm", in: value).flatMap(clean)
            default: break
            }
        }
        return ServiceBanner(port: port, server: server, title: title(in: body), realm: realm,
                             certificate: certificate.flatMap(clean))
    }

    /// SSH 서버가 연결하자마자 보내는 첫 줄("SSH-2.0-...")에서 배너를 만든다.
    public static func ssh(port: UInt16, greeting bytes: [UInt8]) -> ServiceBanner? {
        let text = String(decoding: bytes.prefix(512), as: UTF8.self)
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("SSH-") }) else { return nil }
        let parts = line.split(separator: "-", maxSplits: 2)
        guard parts.count == 3 else { return nil }
        return ServiceBanner(port: port, ssh: clean(String(parts[2])))
    }

    static func title(in body: String) -> String? {
        guard let open = body.range(of: "<title", options: .caseInsensitive),
              let openEnd = body[open.upperBound...].firstIndex(of: ">"),
              let close = body.range(of: "</title>", options: .caseInsensitive, range: openEnd..<body.endIndex)
        else { return nil }
        return clean(decodeEntities(String(body[body.index(after: openEnd)..<close.lowerBound])))
    }

    static func quotedValue(named key: String, in header: String) -> String? {
        guard let start = header.range(of: "\(key)=", options: .caseInsensitive) else { return nil }
        let rest = header[start.upperBound...]
        if rest.first == "\"" {
            return rest.dropFirst().split(separator: "\"", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
        }
        return rest.split(whereSeparator: { $0 == "," || $0 == " " }).first.map(String.init)
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, value) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
                                ("&apos;", "'"), ("&nbsp;", " ")] {
            result = result.replacingOccurrences(of: entity, with: value, options: .caseInsensitive)
        }
        return result
    }

    /// 공백을 하나로, 앞뒤 공백 없이, 너무 길면 자른다. 비면 nil.
    static func clean(_ text: String) -> String? {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > 80 ? String(collapsed.prefix(80)) + "…" : collapsed
    }
}

/// 포트 하나에 연결해 배너를 읽는다. 앱은 NWConnection(TCP/TLS)으로, 시험은 가짜로.
public protocol BannerGrabbing: Sendable {
    func banner(of address: IPv4, port: UInt16) async -> ServiceBanner?
}

public enum BannerPorts {
    /// 평문 HTTP로 읽는 포트
    public static let http: Set<UInt16> = [80, 81, 8000, 8008, 8080, 8081, 8088, 8888, 9000, 9080, 9090]
    /// HTTPS로 읽는 포트(자체 서명 인증서도 받는다)
    public static let https: Set<UInt16> = [443, 4443, 5001, 8443, 9443]
    public static let ssh: Set<UInt16> = [22]

    /// 열린 포트 중 배너를 읽어 볼 것: 웹은 평문·HTTPS 하나씩, SSH 하나
    public static func worthReading(among openPorts: [UInt16]) -> [UInt16] {
        let sorted = openPorts.sorted()
        return [
            sorted.first { http.contains($0) },
            sorted.first { https.contains($0) },
            sorted.first { ssh.contains($0) },
        ].compactMap { $0 }
    }
}
