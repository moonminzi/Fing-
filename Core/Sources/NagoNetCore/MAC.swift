import Foundation

/// 이더넷 MAC 주소.
///
/// iOS는 다른 기기의 ARP 테이블에서 MAC을 지워서 주므로, 기기가 스스로 공개한 것(NetBIOS·Bonjour·UPnP·IPv6·
/// 기기 API·기기 SNMP)이나 공유기에 SNMP로 물어본 것으로 안다(`MACClues`, `MACProber`).
public struct MACAddress: Hashable, Sendable, Codable, CustomStringConvertible {
    public let bytes: [UInt8]

    /// 6바이트. 쓸 수 없는 값이면 nil: 모두 0, 모두 FF, 또는 뒤 5바이트가 모두 0(02:00:00:00:00:00 같은
    /// iOS가 가린 자리표시자 — iOS는 ARP 캐시 항목은 주되 MAC을 0으로 비운다).
    public init?(_ bytes: [UInt8]) {
        guard bytes.count == 6, bytes.contains(where: { $0 != 0xFF }),
              bytes.dropFirst().contains(where: { $0 != 0 }) else { return nil }
        self.bytes = bytes
    }

    /// "AA:BB:CC:DD:EE:FF", "aa-bb-cc-dd-ee-ff", "AABBCCDDEEFF", "a:b:c:d:e:f"
    public init?(_ text: some StringProtocol) {
        let text = String(text)
        let separated = text.split(whereSeparator: { $0 == ":" || $0 == "-" })
        let parts: [Substring]
        if separated.count == 6 {
            parts = separated
        } else if text.count == 12, separated.count == 1 {
            parts = stride(from: 0, to: 12, by: 2).map { offset in
                let start = text.index(text.startIndex, offsetBy: offset)
                return Substring(text[start..<text.index(start, offsetBy: 2)])
            }
        } else {
            return nil
        }
        var bytes: [UInt8] = []
        for part in parts {
            guard (1...2).contains(part.count), let byte = UInt8(part, radix: 16) else { return nil }
            bytes.append(byte)
        }
        self.init(bytes)
    }

    public var description: String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// 앞 3바이트(제조사 번호, OUI)
    public var oui: String {
        bytes.prefix(3).map { String(format: "%02X", $0) }.joined()
    }

    /// 로컬 관리 비트가 켜진 주소: 휴대폰·태블릿이 Wi-Fi마다 바꿔 쓰는 무작위 주소(비공개 Wi-Fi 주소)는 모두 이렇다
    public var isRandomized: Bool {
        bytes[0] & 0x02 != 0
    }
}

/// MAC 앞 6자리로 제조사를 찾는 표(IEEE MA-L 등록 목록).
public struct OUIDatabase: Sendable {
    private let vendors: [String: String]

    public static let empty = OUIDatabase(vendors: [:])

    init(vendors: [String: String]) {
        self.vendors = vendors
    }

    /// "AABBCC\t회사" 줄들. '#'으로 시작하는 줄은 건너뛴다.
    public init(text: String) {
        var vendors: [String: String] = [:]
        vendors.reserveCapacity(45_000)
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            vendors[String(line[..<tab]).uppercased()] = String(line[line.index(after: tab)...])
        }
        self.vendors = vendors
    }

    public var count: Int { vendors.count }

    /// 무작위 주소는 제조사가 없다(nil)
    public func vendor(for mac: MACAddress) -> String? {
        guard !mac.isRandomized else { return nil }
        return vendors[mac.oui]
    }
}

/// 어디서 알게 된 MAC인지.
public enum MACSource: String, Hashable, Sendable {
    case router = "공유기 ARP 표(SNMP)"
    case localARP = "이 기기 ARP 캐시"
    /// DHCP 요청을 엿들어 잡은 MAC(기기가 Wi-Fi에 붙거나 갱신할 때 브로드캐스트한 chaddr) — 공유기 없이 얻음
    case dhcp = "DHCP 요청(스니핑)"
    /// 기기에 SNMP로 물은 자기 인터페이스 MAC(ifPhysAddress) — 프린터·NAS·AP·스위치
    case deviceSNMP = "기기 SNMP(인터페이스 MAC)"
    /// 기기의 정보 API가 알려 준 MAC — Roku·삼성 TV·Hue 브리지·Shelly
    case deviceAPI = "기기 정보 API"
    case netbios = "NetBIOS 응답"
    case airplay = "AirPlay 광고"
    /// Bonjour 광고에 든 MAC — Time Machine 디스크(waMa)·리눅스 워크스테이션·Wi-Fi 동기화·ESPHome·Hue
    case bonjour = "Bonjour 광고"
    /// UPnP 기기 ID·프린터 UUID(버전 1 UUID의 끝 12자리는 만든 기기의 MAC)·Sonos ID
    case deviceID = "기기 ID(UUID)"
    /// IPv6 주소의 EUI-64 인터페이스 ID(…ff:fe…)에 박힌 MAC
    case ipv6 = "IPv6 주소(EUI-64)"
    /// 이전 스캔에서 잡아 이름으로 기억해 둔 MAC(이번엔 못 잡았을 때 되살림)
    case remembered = "기억된 MAC(이전에 잡음)"
}
