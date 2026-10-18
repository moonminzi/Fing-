import Foundation

/// 추정한 기기 종류. 순서는 "종류별" 정렬 순서다.
public enum DeviceKind: String, CaseIterable, Sendable, Codable {
    case router
    case iPhone
    case phone
    case tablet
    case mac
    case computer
    case tv
    case speaker
    case printer
    case nas
    case unknown

    public var title: String {
        switch self {
        case .router: "공유기·AP"
        case .iPhone: "iPhone"
        case .phone: "휴대폰"
        case .tablet: "태블릿"
        case .mac: "Mac"
        case .computer: "컴퓨터"
        case .tv: "TV"
        case .speaker: "스피커"
        case .printer: "프린터"
        case .nas: "NAS"
        case .unknown: "알 수 없음"
        }
    }
}

/// 종류와 그렇게 본 근거.
public struct DeviceClassification: Hashable, Sendable {
    public let kind: DeviceKind
    /// "모델 iPad13,1", "이름에 'iPad'" 같은 근거(점수 높은 순)
    public let reasons: [String]
}

public protocol DeviceClassifying: Sendable {
    func classify(_ device: Device) -> DeviceClassification
}

/// 모델 식별자·이름·Bonjour 서비스·열린 포트·배너에 점수를 매겨 종류를 고른다.
///
/// 점수: 게이트웨이 100, 모델 식별자 90, Bonjour 서비스 40~70, UPnP 45~60, 배너 45, NetBIOS 45, 이름 40,
/// MAC 제조사 25~40, 포트 20~50, 무작위 MAC 20.
/// 가장 높은 종류가 20점 미만이면 "알 수 없음".
public struct DeviceClassifier: DeviceClassifying {
    public init() {}

    public func classify(_ device: Device) -> DeviceClassification {
        var evidence = Evidence()

        if device.isGateway {
            evidence.add(.router, 100, "기본 게이트웨이")
        }
        if let model = device.model, let kind = Self.kind(forModel: model) {
            evidence.add(kind, 90, "모델 \(model)")
        }
        for name in [device.bonjourName, device.upnpName, device.displayHostName].compactMap({ $0 }) {
            if let (kind, keyword) = Self.kind(forName: name) {
                evidence.add(kind, 40, "이름에 '\(keyword)'")
            }
        }
        if device.netbiosName != nil {
            evidence.add(.computer, 45, "NetBIOS(Windows) 이름")
        }
        Self.addServiceEvidence(device.services, to: &evidence)
        Self.addPortEvidence(Set(device.allOpenPorts), to: &evidence)
        for banner in device.banners {
            for hint in banner.hints {
                if let (kind, keyword) = Self.kind(forName: hint) ?? Self.kind(forServerSoftware: hint) {
                    evidence.add(kind, 45, "포트 \(banner.port) 배너에 '\(keyword)'")
                }
            }
        }
        if let upnp = device.upnp {
            Self.addUPnPEvidence(upnp, to: &evidence)
        }
        if let mac = device.mac?.address {
            if let vendor = device.macVendor, let (kind, score) = Self.kind(forVendor: vendor) {
                evidence.add(kind, score, "MAC 제조사 \(vendor)")
            } else if mac.isRandomized, device.netbiosName == nil {
                evidence.add(.phone, 20, "무작위 MAC(비공개 Wi-Fi 주소)를 쓰는 휴대기기")
            }
        }
        return evidence.result
    }

    // MARK: UPnP

    private static func addUPnPEvidence(_ upnp: UPnPDevice, to evidence: inout Evidence) {
        let type = upnp.shortType ?? ""
        switch type {
        case "InternetGatewayDevice", "WANDevice", "WANConnectionDevice", "WFADevice":
            evidence.add(.router, 60, "UPnP 공유기(\(type))")
        case "Printer":
            evidence.add(.printer, 60, "UPnP 프린터")
        case "MediaRenderer":
            evidence.add(.tv, 30, "UPnP 미디어 재생기")
        case "MediaServer":
            evidence.add(.nas, 25, "UPnP 미디어 서버")
        case "ZonePlayer":
            evidence.add(.speaker, 60, "Sonos 스피커")
        default:
            break
        }
        for hint in upnp.hints {
            if let (kind, keyword) = kind(forName: hint) ?? kind(forServerSoftware: hint) {
                evidence.add(kind, 45, "UPnP 설명에 '\(keyword)'")
                break
            }
        }
    }

    // MARK: MAC 제조사

    /// 제조사로 짐작하는 종류. 휴대폰과 TV를 다 만드는 회사(삼성·LG·애플)는 짐작하지 않는다.
    static func kind(forVendor vendor: String) -> (DeviceKind, Int)? {
        let lower = vendor.lowercased()
        let rules: [([String], DeviceKind, Int)] = [
            (["ubiquiti", "aruba", "cisco", "tp-link", "netgear", "efm networks", "mikrotik", "ruckus", "juniper",
              "fortinet", "zyxel", "d-link", "extreme networks", "meraki", "huawei technologies"], .router, 40),
            (["canon", "seiko epson", "brother", "ricoh", "xerox", "kyocera", "sindoh", "lexmark", "konica"], .printer, 40),
            (["synology", "qnap", "western digital", "buffalo"], .nas, 40),
            (["sonos", "bose", "harman", "bang & olufsen"], .speaker, 40),
            (["roku", "vizio", "tcl", "hisense", "skyworth"], .tv, 35),
            (["raspberry pi", "intel", "dell", "lenovo", "micro-star", "giga-byte", "microsoft", "liteon", "azurewave"],
             .computer, 25),
            (["xiaomi", "oppo", "vivo mobile", "oneplus", "motorola", "realme", "zte"], .phone, 25),
        ]
        return rules.first { rule in rule.0.contains { lower.contains($0) } }.map { ($0.1, $0.2) }
    }

    // MARK: 모델 식별자

    static func kind(forModel model: String) -> DeviceKind? {
        let lower = model.lowercased()
        let prefixes: [(String, DeviceKind)] = [
            ("iphone", .iPhone), ("ipad", .tablet), ("ipod", .iPhone), ("macbook", .mac), ("imac", .mac),
            ("macmini", .mac), ("macpro", .mac), ("mac", .mac), ("appletv", .tv), ("audioaccessory", .speaker),
            ("chromecast", .tv), ("google home", .speaker), ("google nest", .speaker), ("nest audio", .speaker),
        ]
        if let match = prefixes.first(where: { lower.hasPrefix($0.0) }) { return match.1 }
        return kind(forName: model)?.0
    }

    // MARK: 이름

    private enum Match {
        /// 단어 하나로 같아야 함("tv", "pc"처럼 짧아 다른 말에 섞이기 쉬운 것)
        case word(String)
        /// 어디든 들어 있으면 됨
        case text(String)
    }

    /// 더 구체적인 것 먼저(갤럭시 탭·갤럭시 북이 "galaxy"보다 앞)
    private static let nameRules: [(Match, DeviceKind)] = [
        (.text("iphone"), .iPhone), (.text("ipad"), .tablet), (.text("galaxy tab"), .tablet), (.word("tab"), .tablet),
        (.text("macbook"), .mac), (.text("imac"), .mac), (.text("mac mini"), .mac), (.text("mac-mini"), .mac),
        (.text("macmini"), .mac), (.text("mac studio"), .mac), (.text("mac pro"), .mac), (.word("mbp"), .mac),
        (.text("맥북"), .mac),
        (.text("galaxy book"), .computer), (.text("desktop"), .computer), (.text("laptop"), .computer),
        (.word("pc"), .computer), (.text("notebook"), .computer), (.text("thinkpad"), .computer),
        (.text("surface"), .computer), (.word("windows"), .computer), (.word("gram"), .computer),
        (.text("노트북"), .computer), (.text("데스크탑"), .computer),
        (.text("apple tv"), .tv), (.text("appletv"), .tv), (.text("chromecast"), .tv), (.text("bravia"), .tv),
        (.text("webos"), .tv), (.text("android tv"), .tv), (.text("fire tv"), .tv), (.text("roku"), .tv),
        (.text("smart tv"), .tv), (.text("[tv]"), .tv), (.word("tv"), .tv), (.text("티비"), .tv),
        (.text("homepod"), .speaker), (.text("sonos"), .speaker), (.text("speaker"), .speaker),
        (.text("google home"), .speaker), (.text("nest mini"), .speaker), (.text("nest audio"), .speaker),
        (.word("echo"), .speaker), (.text("bose"), .speaker), (.text("스피커"), .speaker),
        (.text("printer"), .printer), (.text("laserjet"), .printer), (.text("deskjet"), .printer),
        (.text("officejet"), .printer), (.text("epson"), .printer), (.text("canon"), .printer),
        (.text("brother"), .printer), (.text("ricoh"), .printer), (.text("xerox"), .printer),
        (.text("kyocera"), .printer), (.text("sindoh"), .printer), (.text("lexmark"), .printer),
        (.word("hp"), .printer), (.text("프린터"), .printer), (.text("복합기"), .printer),
        (.text("diskstation"), .nas), (.text("synology"), .nas), (.text("qnap"), .nas), (.text("truenas"), .nas),
        (.text("freenas"), .nas), (.text("mycloud"), .nas), (.text("my cloud"), .nas), (.text("readynas"), .nas),
        (.word("nas"), .nas),
        (.text("router"), .router), (.text("gateway"), .router), (.text("iptime"), .router), (.text("unifi"), .router),
        (.word("ubnt"), .router), (.text("aruba"), .router), (.text("cisco"), .router), (.text("meraki"), .router),
        (.text("tp-link"), .router), (.text("tplink"), .router), (.text("netgear"), .router),
        (.text("mikrotik"), .router), (.text("openwrt"), .router), (.text("ruckus"), .router),
        (.text("access point"), .router), (.word("ap"), .router), (.text("wi-fi"), .router), (.text("wifi"), .router),
        (.text("공유기"), .router), (.text("giga wifi"), .router),
        (.text("android"), .phone), (.text("galaxy"), .phone), (.word("sm"), .phone), (.text("pixel"), .phone),
        (.text("redmi"), .phone), (.text("xiaomi"), .phone), (.text("oneplus"), .phone), (.text("phone"), .phone),
        (.text("갤럭시"), .phone), (.text("폰"), .phone),
    ]

    /// 이름(또는 배너 글)에 든 낱말로 종류를 짐작한다. (종류, 걸린 낱말)
    static func kind(forName name: String) -> (DeviceKind, String)? {
        // "Galaxy-Tab-S9", "galaxy_book" 같은 호스트 이름도 띄어 쓴 것처럼 본다
        let lower = spaced(name.lowercased())
        let words = Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        for (match, kind) in nameRules {
            switch match {
            case .word(let word) where words.contains(word):
                return (kind, word)
            case .text(let text) where lower.contains(spaced(text)):
                return (kind, text)
            default:
                continue
            }
        }
        return nil
    }

    private static func spaced(_ text: String) -> String {
        String(text.map { $0 == "-" || $0 == "_" ? " " : $0 })
    }

    /// 웹·SSH 서버 프로그램 이름으로 짐작하는 종류(임베디드 웹 서버는 공유기·AP에 흔하다)
    static func kind(forServerSoftware text: String) -> (DeviceKind, String)? {
        let lower = text.lowercased()
        let rules: [(String, DeviceKind)] = [
            ("cups", .printer), ("hp http server", .printer), ("epson_linux", .printer), ("canon http", .printer),
            ("microsoft-httpapi", .computer), ("microsoft-iis", .computer), ("ubuntu", .computer),
            ("debian", .computer), ("raspbian", .computer), ("fedora", .computer),
            ("dropbear", .router), ("uhttpd", .router), ("rompager", .router), ("goahead", .router),
            ("mini_httpd", .router), ("micro_httpd", .router), ("boa/", .router), ("rosssh", .router),
        ]
        return rules.first { lower.contains($0.0) }.map { ($0.1, $0.0) }
    }

    // MARK: Bonjour 서비스

    private static func addServiceEvidence(_ services: [BonjourService], to evidence: inout Evidence) {
        let types = Set(services.map(\.type))
        if types.contains("_googlecast._tcp") {
            let model = services.first { $0.type == "_googlecast._tcp" }?.txt["md"]?.lowercased() ?? ""
            let isSpeaker = ["home", "nest", "speaker", "audio"].contains { model.contains($0) }
            evidence.add(isSpeaker ? .speaker : .tv, 60, "Google Cast")
        }
        if types.contains("_ipp._tcp") || types.contains("_printer._tcp") {
            evidence.add(.printer, 70, "프린터 서비스(IPP·LPD)")
        }
        if types.contains("_spotify-connect._tcp") {
            evidence.add(.speaker, 40, "Spotify Connect")
        }
        if types.contains("_raop._tcp"), !types.contains("_companion-link._tcp") {
            evidence.add(.speaker, 30, "AirPlay 오디오")
        }
        if types.contains("_airplay._tcp"), !types.contains("_companion-link._tcp") {
            evidence.add(.tv, 25, "AirPlay 받기")
        }
        if types.contains("_smb._tcp"), !types.contains("_companion-link._tcp") {
            evidence.add(.nas, 20, "파일 공유(SMB)")
        }
    }

    // MARK: 포트

    private static func addPortEvidence(_ ports: Set<UInt16>, to evidence: inout Evidence) {
        if ports.contains(62078) {
            evidence.add(.iPhone, 30, "iPhone·iPad 동기화 포트(62078)")
            evidence.add(.tablet, 25, "iPhone·iPad 동기화 포트(62078)")
        }
        if !ports.isDisjoint(with: [631, 9100, 515]) {
            evidence.add(.printer, 50, "프린터 포트")
        }
        if ports.contains(3389) {
            evidence.add(.computer, 50, "원격 데스크톱(3389)")
        }
        if ports.contains(445), !ports.isDisjoint(with: [135, 139]) {
            evidence.add(.computer, 30, "Windows 파일 공유")
        }
        if ports.contains(5357) || ports.contains(2869) {
            evidence.add(.computer, 20, "Windows 장치 서비스")
        }
        if !ports.isDisjoint(with: [5000, 5001]) {
            evidence.add(.nas, 35, "Synology DSM 포트")
        }
        if ports.contains(548) {
            evidence.add(.mac, 25, "Mac 파일 공유(AFP)")
            evidence.add(.nas, 20, "AFP 파일 공유")
        }
        if ports.contains(8009) {
            evidence.add(.tv, 40, "Google Cast 포트(8009)")
        }
        if !ports.isDisjoint(with: [8001, 8002, 8060]) {
            evidence.add(.tv, 40, "스마트 TV 포트")
        }
        if ports.contains(7547) || ports.contains(8291) {
            evidence.add(.router, 40, "공유기 관리 포트")
        }
        if ports.contains(53), !ports.isDisjoint(with: [80, 443]) {
            evidence.add(.router, 25, "DNS + 웹 관리")
        }
        if ports.contains(5555) {
            evidence.add(.tv, 20, "안드로이드 디버그(ADB)")
        }
    }

    /// 종류별 점수와 근거를 모은다.
    private struct Evidence {
        private var scores: [DeviceKind: Int] = [:]
        private var reasons: [DeviceKind: [(Int, String)]] = [:]

        mutating func add(_ kind: DeviceKind, _ score: Int, _ reason: String) {
            scores[kind, default: 0] += score
            reasons[kind, default: []].append((score, reason))
        }

        var result: DeviceClassification {
            let ranked = DeviceKind.allCases.filter { scores[$0] != nil }.sorted { scores[$0]! > scores[$1]! }
            guard let best = ranked.first, scores[best]! >= 20 else {
                return DeviceClassification(kind: .unknown, reasons: [])
            }
            let why = reasons[best, default: []].sorted { $0.0 > $1.0 }.map(\.1)
            return DeviceClassification(kind: best, reasons: why)
        }
    }
}
