#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// 네트워크 인터페이스 하나에 붙은 IPv4 주소.
public struct InterfaceAddress: Hashable, Sendable {
    /// BSD 이름(en0 같은)
    public let name: String
    public let address: IPv4
    public let netmask: IPv4
    public let isUp: Bool
    public let isRunning: Bool

    public init(name: String, address: IPv4, netmask: IPv4, isUp: Bool = true, isRunning: Bool = true) {
        self.name = name
        self.address = address
        self.netmask = netmask
        self.isUp = isUp
        self.isRunning = isRunning
    }
}

public enum Interfaces {
    /// `getifaddrs`로 모든 인터페이스의 IPv4 주소를 읽는다.
    public static func ipv4Addresses() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [InterfaceAddress] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = entry.pointee
            guard let addr = ifa.ifa_addr, Int32(addr.pointee.sa_family) == AF_INET else { continue }
            let address = ipv4(from: addr)
            // 넷마스크가 없으면 나 혼자인 대역(/32)으로 본다
            let netmask = ifa.ifa_netmask.map(ipv4(from:)) ?? IPv4(0xFFFF_FFFF)
            result.append(InterfaceAddress(
                name: String(cString: ifa.ifa_name),
                address: address,
                netmask: netmask,
                isUp: ifa.ifa_flags & UInt32(IFF_UP) != 0,
                isRunning: ifa.ifa_flags & UInt32(IFF_RUNNING) != 0
            ))
        }
        return result
    }

    /// 인터페이스 번호(라우팅 테이블의 `rtm_index`와 같은 값). 없으면 nil.
    public static func index(of name: String) -> UInt32? {
        let index = if_nametoindex(name)
        return index == 0 ? nil : UInt32(index)
    }

    /// 이 기기 한 인터페이스(en0 등)의 자기 MAC. `getifaddrs`의 AF_LINK(sockaddr_dl) 항목에서 꺼낸다.
    /// iOS는 보통 Wi-Fi MAC을 02:00:…으로 가리므로 그때는 nil(그 사실을 그대로 돌려준다).
    /// ARP·NDP 스푸핑처럼 "내 MAC"이 공격자 MAC으로 필요한 인가된 실험에서 쓴다.
    #if canImport(Darwin)
    public static func linkLayerAddress(of name: String) -> MACAddress? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = entry.pointee
            guard String(cString: ifa.ifa_name) == name, let addr = ifa.ifa_addr,
                  addr.pointee.sa_family == ARPCache.linkFamily else { continue }   // AF_LINK(18): sockaddr_dl
            let length = Int(addr.pointee.sa_len)
            let raw = UnsafeRawPointer(addr)
            let bytes = (0..<length).map { raw.load(fromByteOffset: $0, as: UInt8.self) }
            if let mac = ARPCache.rawLinkAddress(bytes, at: 0, length: length).flatMap(MACAddress.init) {
                return mac
            }
        }
        return nil
    }
    #else
    public static func linkLayerAddress(of name: String) -> MACAddress? { nil }
    #endif

    /// 한 인터페이스에 주소가 여러 개일 때 쓸 만한 것 하나: 켜져 있고, 169.254 자동 주소보다 진짜 주소 먼저.
    public static func preferred(on name: String, in list: [InterfaceAddress]) -> InterfaceAddress? {
        let candidates = list.filter { $0.name == name && $0.isUp && !$0.address.isLoopback }
        return candidates.first { !$0.address.isLinkLocal } ?? candidates.first
    }

    private static func ipv4(from sockaddrPointer: UnsafeMutablePointer<sockaddr>) -> IPv4 {
        sockaddrPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            IPv4(networkOrder: $0.pointee.sin_addr.s_addr)
        }
    }
}
