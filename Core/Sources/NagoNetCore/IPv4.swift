/// IPv4 주소 하나. 값은 사람이 읽는 순서(192.168.0.1 → 0xC0A8_0001)로 들고 있다.
///
/// Network 프레임워크의 `IPv4Address`와 이름이 겹치지 않게 `IPv4`라고 했다.
/// `Strideable`이라서 `a...b`가 그대로 주소 목록(Collection)이 된다.
public struct IPv4: Hashable, Sendable, Strideable, Codable {
    public var value: UInt32

    public init(_ value: UInt32) {
        self.value = value
    }

    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        value = UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
    }

    /// "192.168.0.1"처럼 점으로 나뉜 숫자 네 개만 받는다.
    public init?(_ text: some StringProtocol) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard (1...3).contains(part.count),
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let octet = UInt8(part) else { return nil }
            result = result << 8 | UInt32(octet)
        }
        value = result
    }

    /// `in_addr.s_addr`(네트워크 바이트 순서)에서 만든다.
    public init(networkOrder: UInt32) {
        value = UInt32(bigEndian: networkOrder)
    }

    /// `in_addr.s_addr`에 넣을 값(네트워크 바이트 순서).
    public var networkOrder: UInt32 { value.bigEndian }

    public var octets: [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    /// 169.254.0.0/16: DHCP에서 주소를 못 받았을 때 기기가 스스로 붙이는 주소.
    public var isLinkLocal: Bool { value & 0xFFFF_0000 == 0xA9FE_0000 }

    public var isLoopback: Bool { value >> 24 == 127 }

    public static func < (lhs: IPv4, rhs: IPv4) -> Bool {
        lhs.value < rhs.value
    }

    public func distance(to other: IPv4) -> Int {
        Int(other.value) - Int(value)
    }

    public func advanced(by n: Int) -> IPv4 {
        IPv4(UInt32(Int(value) + n))
    }
}

extension IPv4: CustomStringConvertible {
    public var description: String {
        octets.map(String.init).joined(separator: ".")
    }
}
