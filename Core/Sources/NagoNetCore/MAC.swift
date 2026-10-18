import Foundation

/// 이더넷 MAC 주소.
///
/// iOS는 다른 기기의 ARP 테이블을 읽지 못하므로, 기기가 스스로 알려 준 것(NetBIOS·AirPlay)이나
/// 공유기에 SNMP로 물어본 것만 안다.
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
    case netbios = "NetBIOS 응답"
    case airplay = "AirPlay 광고"
}
