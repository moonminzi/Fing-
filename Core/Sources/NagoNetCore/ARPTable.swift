#if canImport(Darwin)
import Darwin
#endif

/// 이 기기 자신의 ARP 캐시(IP → MAC)를 읽는다.
///
/// 스캔하며 각 기기에 TCP로 연결하거나 핑하면, 운영체제가 그 기기의 MAC을 ARP로 알아내 캐시에 담는다.
/// 그래서 스캔 직후 이 캐시를 읽으면 공유기 SNMP 없이도 많은 기기의 MAC을 얻을 수 있다.
/// `arp -a`와 같은 길(라우팅 소켓 sysctl, `NET_RT_FLAGS` + `RTF_LLINFO`)이고, `RouteTable`과 같은 메시지 형식이다.
///
/// iOS는 버전에 따라 이 캐시의 MAC(sockaddr_dl)을 0으로 지워 돌려주기도 한다. 그러면 얻는 게 없을 뿐,
/// 공유기 SNMP·NetBIOS·AirPlay로 알아낸 MAC은 그대로다. 바이트를 푸는 `parse`는 플랫폼과 상관없어 리눅스에서도 시험된다.
public enum ARPCache {
    /// `RTF_LLINFO`: 링크 계층 정보(ARP·NDP 항목)만
    static let llinfoFlag: Int32 = 0x400
    /// `AF_LINK`: sockaddr_dl의 패밀리
    static let linkFamily: UInt8 = 18
    static let inetFamily: UInt8 = 2

    /// `sysctl`이 돌려준 바이트에서 (IP, MAC)들을 꺼낸다. MAC이 없는(0으로 지워진) 항목은 건너뛴다.
    public static func parse(_ bytes: [UInt8]) -> [IPv4: MACAddress] {
        var result: [IPv4: MACAddress] = [:]
        var offset = 0
        while offset + 4 <= bytes.count {
            let length = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8   // rtm_msglen(리틀 엔디언)
            guard length > 0, offset + length <= bytes.count else { break }
            if length >= RouteTable.headerSize, bytes[offset + 2] == RouteTable.messageVersion,
               let (ip, mac) = entry(bytes, from: offset, to: offset + length) {
                result[ip] = mac
            }
            offset += length
        }
        return result
    }

    private static func entry(_ bytes: [UInt8], from start: Int, to end: Int) -> (IPv4, MACAddress)? {
        let present = littleEndian32(bytes, at: start + 12)   // rtm_addrs
        var cursor = start + RouteTable.headerSize
        var ip: IPv4?
        var mac: MACAddress?
        for slot in 0..<8 where present & (1 << UInt32(slot)) != 0 {
            guard cursor < end else { break }
            let length = Int(bytes[cursor])
            let available = min(length, end - cursor)
            switch slot {
            case 0:   // RTAX_DEST: sockaddr_in(IP)
                if available >= 8, bytes[cursor + 1] == inetFamily {
                    ip = IPv4(bytes[cursor + 4], bytes[cursor + 5], bytes[cursor + 6], bytes[cursor + 7])
                }
            case 1:   // RTAX_GATEWAY: sockaddr_dl(MAC)
                mac = linkAddress(bytes, at: cursor, length: available)
            default:
                break
            }
            cursor += length > 0 ? 1 + ((length - 1) | 3) : 4   // ROUNDUP(4바이트)
        }
        guard let ip, let mac else { return nil }
        return (ip, mac)
    }

    /// sockaddr_dl에서 MAC. 배치: len·family(18)·index(2)·type·nlen@5·alen@6·slen@7·data@8(이름 nlen + 주소 alen)
    static func linkAddress(_ bytes: [UInt8], at cursor: Int, length: Int) -> MACAddress? {
        guard length >= 8, bytes[cursor + 1] == linkFamily else { return nil }
        let nameLength = Int(bytes[cursor + 5])
        let addressLength = Int(bytes[cursor + 6])
        guard addressLength == 6 else { return nil }
        let addressStart = cursor + 8 + nameLength
        guard addressStart + 6 <= cursor + length else { return nil }
        return MACAddress(Array(bytes[addressStart..<(addressStart + 6)]))
    }

    private static func littleEndian32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << UInt32(8 * $1) }
    }

    #if canImport(Darwin)
    /// 이 기기의 ARP 캐시를 읽는다. 샌드박스 등으로 막히면 nil.
    public static func read() -> [IPv4: MACAddress]? {
        // CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO
        var mib: [Int32] = [4, 17, 0, 2, 2, llinfoFlag]
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return nil }
            guard size > 0 else { return [:] }
            var buffer = [UInt8](repeating: 0, count: size)
            let status = buffer.withUnsafeMutableBytes { raw in
                sysctl(&mib, UInt32(mib.count), raw.baseAddress, &size, nil, 0)
            }
            if status == 0 { return parse(Array(buffer.prefix(size))) }
            guard errno == ENOMEM else { return nil }   // 두 호출 사이 캐시가 커졌으면 다시
        }
        return nil
    }
    #else
    public static func read() -> [IPv4: MACAddress]? { nil }
    #endif
}

/// 이 기기 ARP 캐시를 읽는 쪽. 앱은 sysctl로, 시험은 가짜로.
public protocol ARPCacheReading: Sendable {
    func read() -> [IPv4: MACAddress]
}

/// 진짜 ARP 캐시를 읽는다.
public struct SystemARPCache: ARPCacheReading {
    public init() {}
    public func read() -> [IPv4: MACAddress] { ARPCache.read() ?? [:] }
}
