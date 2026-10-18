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
    /// `AF_INET6`: sockaddr_in6의 패밀리(IPv6 이웃 캐시 진단용)
    static let inet6Family: UInt8 = 30

    /// `sysctl`이 돌려준 바이트에서 (IP, MAC)들을 꺼낸다. MAC이 없는(0으로 지워진) 항목은 건너뛴다.
    public static func parse(_ bytes: [UInt8]) -> [IPv4: MACAddress] {
        report(bytes).usable
    }

    /// 진단용: `parse`와 같은 길을 걷되, iOS가 MAC을 가린 항목까지 세어 "진짜 MAC이 몇 개나 섞여 나오는지" 본다.
    /// 스캔으로 ARP 캐시를 데운 직후 부르면 iOS가 다른 기기 MAC을 흘리는지/가리는지가 그대로 드러난다.
    public static func report(_ bytes: [UInt8]) -> ARPCacheReport {
        var usable: [IPv4: MACAddress] = [:]
        var hidden: [IPv4] = []
        var offset = 0
        while offset + 4 <= bytes.count {
            let length = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8   // rtm_msglen(리틀 엔디언)
            guard length > 0, offset + length <= bytes.count else { break }
            if length >= RouteTable.headerSize, bytes[offset + 2] == RouteTable.messageVersion {
                let (ip, link) = entryDetail(bytes, from: offset, to: offset + length)
                if let ip, let link {
                    if let mac = MACAddress(link) {
                        usable[ip] = mac
                    } else {
                        hidden.append(ip)   // 항목은 왔는데 iOS가 MAC을 0(02:00:…)으로 가렸다
                    }
                }
            }
            offset += length
        }
        return ARPCacheReport(usable: usable, hidden: hidden)
    }

    /// 항목 하나에서 IP(RTAX_DEST)와 링크 주소 6바이트(RTAX_GATEWAY)를 꺼낸다. MAC 유효성은 보지 않는다.
    private static func entryDetail(_ bytes: [UInt8], from start: Int, to end: Int) -> (ip: IPv4?, link: [UInt8]?) {
        let present = littleEndian32(bytes, at: start + 12)   // rtm_addrs
        var cursor = start + RouteTable.headerSize
        var ip: IPv4?
        var link: [UInt8]?
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
                link = rawLinkAddress(bytes, at: cursor, length: available)
            default:
                break
            }
            cursor += length > 0 ? 1 + ((length - 1) | 3) : 4   // ROUNDUP(4바이트)
        }
        return (ip, link)
    }

    /// 진단용 IPv6 이웃(NDP) 캐시: ARP와 **같은** 라우팅 덤프지만 주소가 IPv6(sockaddr_in6)다.
    /// MAC(sockaddr_dl)은 같은 자리(RTAX_GATEWAY)라 `rawLinkAddress`를 그대로 쓴다. iOS가 v6 쪽도
    /// 가리는지는 ARP와 별개라, 여기서 "진짜 MAC M개 / 가린 것 K개"를 세어 실제로 확인한다.
    public static func reportNDP(_ bytes: [UInt8]) -> NDPReport {
        var usable: [IPv6Address: MACAddress] = [:]
        var hidden: [IPv6Address] = []
        var offset = 0
        while offset + 4 <= bytes.count {
            let length = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            guard length > 0, offset + length <= bytes.count else { break }
            if length >= RouteTable.headerSize, bytes[offset + 2] == RouteTable.messageVersion {
                let (ip, link) = ndpEntry(bytes, from: offset, to: offset + length)
                if let ip, let link {
                    if let mac = MACAddress(link) {
                        usable[ip] = mac
                    } else {
                        hidden.append(ip)   // 항목은 왔는데 MAC이 가려짐
                    }
                }
            }
            offset += length
        }
        return NDPReport(usable: usable, hidden: hidden)
    }

    /// 항목 하나에서 IPv6(RTAX_DEST, sockaddr_in6의 +8부터 16바이트)와 링크 주소(RTAX_GATEWAY)를 꺼낸다.
    private static func ndpEntry(_ bytes: [UInt8], from start: Int, to end: Int) -> (ip: IPv6Address?, link: [UInt8]?) {
        let present = littleEndian32(bytes, at: start + 12)
        var cursor = start + RouteTable.headerSize
        var ip: IPv6Address?
        var link: [UInt8]?
        for slot in 0..<8 where present & (1 << UInt32(slot)) != 0 {
            guard cursor < end else { break }
            let length = Int(bytes[cursor])
            let available = min(length, end - cursor)
            switch slot {
            case 0:   // RTAX_DEST: sockaddr_in6(len·family(30)·port(2)·flow(4)·addr@8(16)·scope(4))
                if available >= 24, bytes[cursor + 1] == inet6Family {
                    ip = IPv6Address(Array(bytes[(cursor + 8)..<(cursor + 24)]))
                }
            case 1:   // RTAX_GATEWAY: sockaddr_dl(MAC)
                link = rawLinkAddress(bytes, at: cursor, length: available)
            default:
                break
            }
            cursor += length > 0 ? 1 + ((length - 1) | 3) : 4   // ROUNDUP(4바이트)
        }
        return (ip, link)
    }

    /// sockaddr_dl에서 MAC 6바이트를 유효성 검사 없이 꺼낸다(0으로 가린 것도 그대로 — 진단이 세야 하니까).
    /// 배치: len·family(18)·index(2)·type·nlen@5·alen@6·slen@7·data@8(이름 nlen + 주소 alen)
    static func rawLinkAddress(_ bytes: [UInt8], at cursor: Int, length: Int) -> [UInt8]? {
        guard length >= 8, bytes[cursor + 1] == linkFamily else { return nil }
        let nameLength = Int(bytes[cursor + 5])
        let addressLength = Int(bytes[cursor + 6])
        guard addressLength == 6 else { return nil }
        let addressStart = cursor + 8 + nameLength
        guard addressStart + 6 <= cursor + length else { return nil }
        return Array(bytes[addressStart..<(addressStart + 6)])
    }

    private static func littleEndian32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << UInt32(8 * $1) }
    }

    #if canImport(Darwin)
    /// 이웃 캐시를 날것(sysctl 바이트)으로 읽는다. family는 AF_INET(2, ARP)·AF_INET6(30, NDP).
    /// 샌드박스 등으로 막히면 nil, 빈 캐시면 빈 배열.
    static func readRaw(family: Int32 = 2) -> [UInt8]? {
        // CTL_NET, PF_ROUTE, 0, family, NET_RT_FLAGS, RTF_LLINFO
        var mib: [Int32] = [4, 17, 0, family, 2, llinfoFlag]
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return nil }
            guard size > 0 else { return [] }
            var buffer = [UInt8](repeating: 0, count: size)
            let status = buffer.withUnsafeMutableBytes { raw in
                sysctl(&mib, UInt32(mib.count), raw.baseAddress, &size, nil, 0)
            }
            if status == 0 { return Array(buffer.prefix(size)) }
            guard errno == ENOMEM else { return nil }   // 두 호출 사이 캐시가 커졌으면 다시
        }
        return nil
    }

    /// 이 기기의 ARP 캐시를 읽는다(IP → MAC). 막히면 nil.
    public static func read() -> [IPv4: MACAddress]? {
        readRaw().map(parse)
    }

    /// 진단: ARP 캐시를 날것으로 읽어 진짜 MAC과 iOS가 가린 항목을 센다. 막히면 nil.
    public static func readReport() -> ARPCacheReport? {
        readRaw().map(report)
    }

    /// 진단: IPv6 이웃(NDP) 캐시를 읽어 진짜 MAC과 가린 항목을 센다(ARP와 별개로 새는지 확인). 막히면 nil.
    public static func readNDPReport() -> NDPReport? {
        readRaw(family: Int32(inet6Family)).map(reportNDP)
    }
    #else
    public static func read() -> [IPv4: MACAddress]? { nil }
    public static func readReport() -> ARPCacheReport? { nil }
    public static func readNDPReport() -> NDPReport? { nil }
    #endif
}

/// 이 기기 ARP 캐시 진단: iOS가 실제로 다른 기기의 MAC을 주는지 센다.
///
/// iOS는 ARP 항목은 주되 MAC을 `02:00:…`으로 가릴 수 있다. `usable`은 진짜로 읽힌 MAC,
/// `hidden`은 항목은 왔지만 MAC이 가려진 IP다. `hidden`만 있고 `usable`이 비어 있으면
/// 그 기기·iOS 버전에서는 공유기 SNMP 없이 다른 기기 MAC을 얻을 수 없다는 뜻이다.
public struct ARPCacheReport: Sendable, Equatable {
    /// 진짜 MAC이 읽힌 항목(IP → MAC)
    public var usable: [IPv4: MACAddress]
    /// 항목은 왔지만 iOS가 MAC을 가린 IP들
    public var hidden: [IPv4]

    public init(usable: [IPv4: MACAddress] = [:], hidden: [IPv4] = []) {
        self.usable = usable
        self.hidden = hidden
    }

    public static let empty = ARPCacheReport()

    /// 링크 주소가 달린 ARP 항목 수(진짜 + 가려진 것)
    public var entries: Int { usable.count + hidden.count }
    public var usableCount: Int { usable.count }
    public var hiddenCount: Int { hidden.count }
}

/// 이 기기 IPv6 이웃(NDP) 캐시 진단: ARP와 별개로 iOS가 v6 쪽 MAC을 흘리는지 센다.
///
/// 가린다는 보장이 ARP와 따로라서 따로 측정한다. `usable`이 하나라도 있으면 공유기 없이
/// 그 IPv6를 광고한 기기의 진짜 MAC을 얻을 수 있다는 뜻이다.
public struct NDPReport: Sendable, Equatable {
    /// 진짜 MAC이 읽힌 이웃(IPv6 → MAC)
    public var usable: [IPv6Address: MACAddress]
    /// 항목은 왔지만 MAC이 가려진 IPv6들
    public var hidden: [IPv6Address]

    public init(usable: [IPv6Address: MACAddress] = [:], hidden: [IPv6Address] = []) {
        self.usable = usable
        self.hidden = hidden
    }

    public static let empty = NDPReport()

    public var entries: Int { usable.count + hidden.count }
    public var usableCount: Int { usable.count }
    public var hiddenCount: Int { hidden.count }
}

/// 이 기기 ARP 캐시를 읽는 쪽. 앱은 sysctl로, 시험은 가짜로.
public protocol ARPCacheReading: Sendable {
    func read() -> [IPv4: MACAddress]
    /// 진단: iOS가 MAC을 가렸는지까지 센다. read()만 구현하면 기본값이 쓰인다.
    func readReport() -> ARPCacheReport
    /// 진단: IPv6 이웃(NDP) 캐시도 가리는지 센다. 기본값은 빈 결과.
    func readNDPReport() -> NDPReport
}

public extension ARPCacheReading {
    func readReport() -> ARPCacheReport { ARPCacheReport(usable: read(), hidden: []) }
    func readNDPReport() -> NDPReport { .empty }
}

/// 진짜 ARP 캐시를 읽는다.
public struct SystemARPCache: ARPCacheReading {
    public init() {}
    public func read() -> [IPv4: MACAddress] { ARPCache.read() ?? [:] }
    public func readReport() -> ARPCacheReport { ARPCache.readReport() ?? .empty }
    public func readNDPReport() -> NDPReport { ARPCache.readNDPReport() ?? .empty }
}
