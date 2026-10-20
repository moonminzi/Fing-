#if canImport(Darwin)
import Darwin
#endif

/// 라우팅 테이블의 경로 하나(게이트웨이를 찾는 데 필요한 것만).
public struct Route: Hashable, Sendable {
    /// 경로가 나가는 인터페이스 번호(`if_nametoindex`와 같은 값)
    public let interfaceIndex: UInt32
    public let flags: Int32
    public let destination: IPv4?
    public let gateway: IPv4?
    public let netmask: IPv4?

    public init(interfaceIndex: UInt32, flags: Int32, destination: IPv4?, gateway: IPv4?, netmask: IPv4?) {
        self.interfaceIndex = interfaceIndex
        self.flags = flags
        self.destination = destination
        self.gateway = gateway
        self.netmask = netmask
    }

    /// 기본 경로(0.0.0.0/0)
    public var isDefault: Bool {
        destination == IPv4(0) && (netmask ?? IPv4(0)) == IPv4(0)
    }
}

/// 커널 라우팅 테이블을 `sysctl(NET_RT_FLAGS)`로 읽는다.
///
/// iOS SDK에는 `net/route.h`가 없어서 구조체 배치와 상수를 여기 직접 적었다(XNU `bsd/net/route.h`).
/// 바이트를 푸는 `parse`는 플랫폼과 상관없어서 리눅스에서도 시험된다.
public enum RouteTable {
    /// `sizeof(struct rt_msghdr)`: 고정 필드 36바이트 + `struct rt_metrics` 56바이트
    static let headerSize = 92
    /// `RTM_VERSION`
    static let messageVersion: UInt8 = 5
    /// `RTF_GATEWAY`
    static let gatewayFlag: Int32 = 0x2
    static let inetFamily: UInt8 = 2
    // 메시지 뒤에 붙는 sockaddr 순서(RTAX_*)
    static let destinationSlot = 0
    static let gatewaySlot = 1
    static let netmaskSlot = 2
    static let slotCount = 8

    /// `sysctl`이 돌려준 바이트에서 경로들을 꺼낸다. 모르는 버전이나 잘린 메시지는 건너뛴다.
    public static func parse(_ bytes: [UInt8]) -> [Route] {
        var routes: [Route] = []
        var offset = 0
        while offset + 4 <= bytes.count {
            let length = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8   // rtm_msglen(리틀 엔디언)
            guard length > 0, offset + length <= bytes.count else { break }
            if length >= headerSize, bytes[offset + 2] == messageVersion {
                routes.append(parseMessage(bytes, from: offset, to: offset + length))
            }
            offset += length
        }
        return routes
    }

    private static func parseMessage(_ bytes: [UInt8], from start: Int, to end: Int) -> Route {
        let index = UInt32(littleEndian16(bytes, at: start + 4))         // rtm_index
        let flags = Int32(bitPattern: littleEndian32(bytes, at: start + 8))  // rtm_flags
        let present = littleEndian32(bytes, at: start + 12)              // rtm_addrs

        var destination: IPv4?
        var gateway: IPv4?
        var netmask: IPv4?
        var cursor = start + headerSize
        for slot in 0..<slotCount where present & (1 << UInt32(slot)) != 0 {
            guard cursor < end else { break }
            let length = Int(bytes[cursor])
            let available = min(length, end - cursor)
            switch slot {
            case destinationSlot:
                destination = inetAddress(bytes, at: cursor, length: available, zeroLengthMeansAny: true)
            case gatewaySlot:
                gateway = inetAddress(bytes, at: cursor, length: available, zeroLengthMeansAny: false)
            case netmaskSlot:
                netmask = maskAddress(bytes, at: cursor, length: available)
            default:
                break
            }
            // sockaddr는 4바이트 단위로 붙는다(XNU의 ROUNDUP)
            cursor += length > 0 ? 1 + ((length - 1) | 3) : 4
        }
        return Route(interfaceIndex: index, flags: flags, destination: destination, gateway: gateway, netmask: netmask)
    }

    /// AF_INET sockaddr의 주소. 길이 0인 sockaddr는 0.0.0.0을 뜻할 수 있다.
    private static func inetAddress(_ bytes: [UInt8], at cursor: Int, length: Int, zeroLengthMeansAny: Bool) -> IPv4? {
        if length == 0 { return zeroLengthMeansAny ? IPv4(0) : nil }
        guard length >= 8, bytes[cursor + 1] == inetFamily else { return nil }
        return bigEndianAddress(bytes, at: cursor + 4, count: 4)
    }

    /// 넷마스크 sockaddr는 뒤쪽 0바이트를 잘라 짧게 오고, 패밀리 값도 믿을 수 없어서 있는 바이트만 읽는다.
    private static func maskAddress(_ bytes: [UInt8], at cursor: Int, length: Int) -> IPv4 {
        bigEndianAddress(bytes, at: cursor + 4, count: max(0, min(length, 8) - 4))
    }

    private static func bigEndianAddress(_ bytes: [UInt8], at offset: Int, count: Int) -> IPv4 {
        var value: UInt32 = 0
        for i in 0..<4 {
            value = value << 8 | UInt32(i < count ? bytes[offset + i] : 0)
        }
        return IPv4(value)
    }

    private static func littleEndian16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func littleEndian32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << UInt32(8 * $1) }
    }

    #if canImport(Darwin)
    /// 게이트웨이를 거치는 IPv4 경로만 읽는다. 샌드박스 등으로 막히면 nil.
    public static func read() -> [Route]? {
        // CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY
        var mib: [Int32] = [4, 17, 0, 2, 2, gatewayFlag]
        // 두 번 부르는 사이에 테이블이 커질 수 있어서 ENOMEM이면 다시
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return nil }
            guard size > 0 else { return [] }
            var buffer = [UInt8](repeating: 0, count: size)
            let status = buffer.withUnsafeMutableBytes { raw in
                sysctl(&mib, UInt32(mib.count), raw.baseAddress, &size, nil, 0)
            }
            if status == 0 { return parse(Array(buffer.prefix(size))) }
            guard errno == ENOMEM else { return nil }
        }
        return nil
    }
    #else
    public static func read() -> [Route]? { nil }
    #endif

    // MARK: IPv6 기본 경로의 게이트웨이(라우터 링크로컬 fe80::) — NDP 대상 지정에 쓴다

    static let inet6Family: UInt8 = 30

    /// IPv6 라우트 덤프에서 기본 경로(::/0)의 게이트웨이(fe80::)를 꺼낸다. 인터페이스가 맞는 것을 먼저 고른다.
    /// 바이트를 푸는 일이라 플랫폼과 상관없어 리눅스에서도 시험된다.
    public static func parseIPv6Gateway(_ bytes: [UInt8], interfaceIndex: UInt32?) -> IPv6Address? {
        let unspecified = IPv6Address([UInt8](repeating: 0, count: 16))
        var fallback: IPv6Address?
        var offset = 0
        while offset + 4 <= bytes.count {
            let length = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            guard length > 0, offset + length <= bytes.count else { break }
            if length >= headerSize, bytes[offset + 2] == messageVersion,
               let message = ipv6Message(bytes, from: offset, to: offset + length),
               message.destination == nil || message.destination == unspecified,   // ::/0 (기본 경로)
               let gateway = message.gateway, gateway.isLinkLocal {
                if interfaceIndex == nil || message.interfaceIndex == interfaceIndex { return gateway }
                fallback = fallback ?? gateway
            }
            offset += length
        }
        return fallback
    }

    private static func ipv6Message(_ bytes: [UInt8], from start: Int, to end: Int) -> (interfaceIndex: UInt32, destination: IPv6Address?, gateway: IPv6Address?)? {
        let index = UInt32(littleEndian16(bytes, at: start + 4))
        let present = littleEndian32(bytes, at: start + 12)
        var destination: IPv6Address?
        var gateway: IPv6Address?
        var cursor = start + headerSize
        for slot in 0..<slotCount where present & (1 << UInt32(slot)) != 0 {
            guard cursor < end else { break }
            let length = Int(bytes[cursor])
            let available = min(length, end - cursor)
            switch slot {
            case destinationSlot: destination = inet6Address(bytes, at: cursor, length: available)
            case gatewaySlot: gateway = inet6Address(bytes, at: cursor, length: available)
            default: break
            }
            cursor += length > 0 ? 1 + ((length - 1) | 3) : 4
        }
        return (index, destination, gateway)
    }

    /// sockaddr_in6에서 16바이트 주소(len·fam(30)·port(2)·flow(4)·addr@8(16)·scope(4)). 주소가 없으면 nil.
    private static func inet6Address(_ bytes: [UInt8], at cursor: Int, length: Int) -> IPv6Address? {
        guard length >= 24, bytes[cursor + 1] == inet6Family else { return nil }
        return IPv6Address(Array(bytes[(cursor + 8)..<(cursor + 24)]))
    }

    #if canImport(Darwin)
    /// IPv6 기본 경로의 게이트웨이(라우터 fe80::)를 커널 라우팅 테이블에서 읽는다. 막히거나 없으면 nil.
    public static func readIPv6Gateway(interfaceIndex: UInt32?) -> IPv6Address? {
        // CTL_NET, PF_ROUTE, 0, AF_INET6(30), NET_RT_FLAGS, RTF_GATEWAY
        var mib: [Int32] = [4, 17, 0, 30, 2, gatewayFlag]
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return nil }
            guard size > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            let status = buffer.withUnsafeMutableBytes { raw in
                sysctl(&mib, UInt32(mib.count), raw.baseAddress, &size, nil, 0)
            }
            if status == 0 { return parseIPv6Gateway(Array(buffer.prefix(size)), interfaceIndex: interfaceIndex) }
            guard errno == ENOMEM else { return nil }
        }
        return nil
    }
    #else
    public static func readIPv6Gateway(interfaceIndex: UInt32?) -> IPv6Address? { nil }
    #endif
}

/// 공유기(기본 게이트웨이) 주소.
public struct Gateway: Hashable, Sendable {
    public let address: IPv4
    /// 라우팅 테이블에서 못 찾아서 대역의 첫 주소(.1)로 짐작한 값인지
    public let isEstimated: Bool

    public init(address: IPv4, isEstimated: Bool) {
        self.address = address
        self.isEstimated = isEstimated
    }

    /// 이 인터페이스의 기본 경로에서 게이트웨이를 고른다. 못 찾거나 대역 밖이면 대역의 첫 주소로 짐작한다.
    ///
    /// VPN을 켜면 utun 쪽에도 기본 경로가 생기므로 인터페이스 번호와 대역으로 거른다.
    public static func resolve(subnet: Subnet, routes: [Route]?, interfaceIndex: UInt32?) -> Gateway {
        let candidates = (routes ?? []).filter { route in
            guard route.isDefault, let gateway = route.gateway else { return false }
            return subnet.contains(gateway) && gateway != subnet.address
        }
        let match = candidates.first { $0.interfaceIndex == interfaceIndex } ?? candidates.first
        if let address = match?.gateway {
            return Gateway(address: address, isEstimated: false)
        }
        return Gateway(address: subnet.conventionalGateway, isEstimated: true)
    }
}
