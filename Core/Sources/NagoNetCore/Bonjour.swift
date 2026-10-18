import Foundation

/// Bonjour로 찾아 IP까지 풀어낸 서비스 하나.
public struct BonjourService: Hashable, Sendable {
    /// 인스턴스 이름("거실 Apple TV", "001122AABBCC@거실" 같은)
    public let name: String
    /// "_airplay._tcp" 같은 종류
    public let type: String
    public let address: IPv4
    public let port: UInt16?
    /// TXT 레코드(model, fn, ty 같은 키)
    public let txt: [String: String]

    public init(name: String, type: String, address: IPv4, port: UInt16? = nil, txt: [String: String] = [:]) {
        self.name = name
        self.type = type
        self.address = address
        self.port = port
        self.txt = txt
    }

    /// 사람에게 보여 줄 기기 이름
    public var friendlyName: String? {
        let raw: String
        switch type {
        case "_googlecast._tcp":
            // 인스턴스 이름은 "Chromecast-<uuid>"라서 TXT의 fn(친근한 이름)을 쓴다
            raw = txt["fn"] ?? name
        case "_raop._tcp":
            // "MAC주소@이름"
            raw = name.split(separator: "@", maxSplits: 1).last.map(String.init) ?? name
        default:
            raw = name
        }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 서비스 종류를 사람이 읽는 말로
    public var typeTitle: String {
        BonjourCatalog.titles[type] ?? type
    }
}

public enum BonjourCatalog {
    /// 찾는 서비스. Info.plist의 NSBonjourServices와 같아야 한다(없는 종류는 iOS가 검색을 막는다)
    public static let serviceTypes = [
        "_airplay._tcp", "_raop._tcp", "_googlecast._tcp", "_ipp._tcp", "_printer._tcp", "_smb._tcp",
        "_ssh._tcp", "_http._tcp", "_hap._tcp", "_companion-link._tcp", "_spotify-connect._tcp",
    ]

    static let titles: [String: String] = [
        "_airplay._tcp": "AirPlay",
        "_raop._tcp": "AirPlay 오디오",
        "_googlecast._tcp": "Google Cast",
        "_ipp._tcp": "프린터(IPP)",
        "_printer._tcp": "프린터(LPD)",
        "_smb._tcp": "파일 공유(SMB)",
        "_ssh._tcp": "SSH",
        "_http._tcp": "웹",
        "_hap._tcp": "HomeKit",
        "_companion-link._tcp": "Apple 기기",
        "_spotify-connect._tcp": "Spotify Connect",
    ]

    /// 이름을 고를 때 믿는 순서: 사용자가 기기에 붙인 이름이 그대로 들어 있는 서비스 먼저
    static let namingOrder = [
        "_googlecast._tcp", "_companion-link._tcp", "_airplay._tcp", "_raop._tcp", "_hap._tcp",
        "_ipp._tcp", "_printer._tcp", "_spotify-connect._tcp", "_smb._tcp", "_ssh._tcp", "_http._tcp",
    ]

    /// 여러 서비스 중 기기 이름으로 쓸 것 하나
    public static func preferredName(among services: [BonjourService]) -> String? {
        let ranked = services.sorted { rank($0.type) < rank($1.type) }
        return ranked.lazy.compactMap(\.friendlyName).first
    }

    private static func rank(_ type: String) -> Int {
        namingOrder.firstIndex(of: type) ?? namingOrder.count
    }
}

/// 역방향 DNS 이름 다듬기.
public enum HostName {
    /// 공유기 DNS가 붙이는 꼬리(.lan, .local, .home…)를 떼고 첫 덩어리만. IP를 그대로 이름으로 쓴 것이면 nil.
    ///
    /// "Galaxy-S23.lan." → "Galaxy-S23", "192-168-0-7.home" → nil
    public static func display(_ raw: String, for address: IPv4) -> String? {
        let full = raw.hasSuffix(".") ? String(raw.dropLast()) : raw
        guard let first = full.split(separator: ".").first.map(String.init), !first.isEmpty else { return nil }
        if IPv4(full) != nil { return nil }
        let digits = address.octets.map(String.init)
        for separator in ["-", "_", "."] where first.contains(digits.joined(separator: separator)) {
            return nil
        }
        return first
    }
}

/// 같은 Wi-Fi의 Bonjour 서비스를 찾아 IP로 푼다. 앱은 NWBrowser로, 시험은 가짜로.
public protocol BonjourBrowsing: Sendable {
    /// 서비스를 찾아 IPv4로 풀릴 때마다 흘려보낸다. 받는 쪽이 그만두면(취소) 검색을 멈춘다.
    func discover(types: [String]) -> AsyncStream<BonjourService>
}

/// IP로 호스트 이름 찾기(역방향 DNS).
public protocol HostNameResolving: Sendable {
    func hostName(for address: IPv4) async -> String?
}
