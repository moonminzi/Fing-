import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// IPv6 이웃 탐색(NDP) 메시지에서 보낸 기기의 MAC을 꺼낸다.
///
/// NS(135)·RS(133)는 출발지 링크주소 옵션(1), NA(136)는 목표 링크주소 옵션(2)에 그 기기의 MAC이 들어 있다.
/// DHCP의 chaddr처럼 MAC을 L3에 실어 나르고, 멀티캐스트라 앱 소켓에 들어올 "수도" 있다(DHCP 브로드캐스트처럼).
/// iOS가 ND를 커널이 가로채 앱에 안 줄 수도 있어서, 되는지는 실제로 측정한다. 바이트 파싱이라 플랫폼과 무관.
public enum NeighborDiscovery {
    static let routerSolicitation: UInt8 = 133
    static let neighborSolicitation: UInt8 = 135
    static let neighborAdvertisement: UInt8 = 136
    /// 옵션 종류: 1=출발지 링크주소, 2=목표 링크주소
    static let sourceLinkLayer: UInt8 = 1
    static let targetLinkLayer: UInt8 = 2

    /// ND 메시지에서 링크주소 옵션의 MAC을 꺼낸다. 앞에 IPv6 머리(40바이트)가 붙어 있으면 떼고 본다.
    public static func mac(in raw: [UInt8]) -> MACAddress? {
        var bytes = raw
        if let first = bytes.first, first >> 4 == 6, bytes.count > 40 {
            bytes = Array(bytes.dropFirst(40))   // 커널이 IPv6 머리를 붙여 줬으면 뗀다(ND엔 확장헤더 없음)
        }
        guard let type = bytes.first else { return nil }
        let optionStart: Int
        switch type {
        case routerSolicitation: optionStart = 8          // type·code·checksum(4) + reserved(4)
        case neighborSolicitation: optionStart = 24       // 4 + reserved(4) + target(16)
        case neighborAdvertisement: optionStart = 24      // 4 + flags(4) + target(16)
        default: return nil
        }
        return linkLayerMAC(in: bytes, from: optionStart)
    }

    /// ND 옵션들을 걸어 링크주소 옵션(1·2)의 MAC을 찾는다. 옵션: 종류(1) 길이(1, 8바이트 단위) + 데이터.
    private static func linkLayerMAC(in bytes: [UInt8], from start: Int) -> MACAddress? {
        var cursor = start
        while cursor + 2 <= bytes.count {
            let optionType = bytes[cursor]
            let length = Int(bytes[cursor + 1]) * 8        // 8바이트 단위
            guard length > 0, cursor + length <= bytes.count else { break }
            if optionType == sourceLinkLayer || optionType == targetLinkLayer, length >= 8 {
                return MACAddress(Array(bytes[(cursor + 2)..<(cursor + 8)]))
            }
            cursor += length
        }
        return nil
    }
}

/// 이웃 탐색으로 거둔 결과(IPv6 → MAC)와, 소켓을 못 열었는지(iOS가 막음).
public struct NeighborFinding: Sendable, Equatable {
    public let blocked: Bool
    public let found: [IPv6Address: MACAddress]

    public init(blocked: Bool, found: [IPv6Address: MACAddress]) {
        self.blocked = blocked
        self.found = found
    }

    public static let empty = NeighborFinding(blocked: false, found: [:])
}

/// IPv6 이웃을 찔러 MAC을 거두는 쪽. 앱은 ICMPv6 소켓으로, 시험은 가짜로.
public protocol NeighborProbing: Sendable {
    func harvest(on interfaceName: String?, provoking targets: [IPv6Address], for duration: Duration) async -> NeighborFinding
}

/// `SOCK_DGRAM` ICMPv6 소켓(raw 아님, iOS 앱도 열 수 있다)으로 이웃 탐색 메시지를 엿듣는다.
///
/// 먼저 all-nodes(ff02::1)와 알려진 링크로컬에 ICMPv6 에코를 보내 상대가 NS/NA를 쏘게 유도하고(상대가 우리에게
/// 답하려면 우리를 ND로 찾아야 하므로 자기 MAC을 실은 NS를 보낸다), 들어오는 ND에서 MAC을 꺼낸다. 읽기만 한다.
public struct NeighborProber: NeighborProbing {
    public init() {}

    public func harvest(on interfaceName: String?, provoking targets: [IPv6Address], for duration: Duration) async -> NeighborFinding {
        let index = interfaceName.flatMap(Interfaces.index(of:))
        return await withCheckedContinuation { (continuation: CheckedContinuation<NeighborFinding, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.blockingHarvest(targets: targets, interfaceIndex: index, duration: duration))
            }
        }
    }

    #if canImport(Darwin)
    /// all-nodes 멀티캐스트 ff02::1
    static let allNodes: [UInt8] = [0xFF, 0x02] + [UInt8](repeating: 0, count: 13) + [0x01]

    static func blockingHarvest(targets: [IPv6Address], interfaceIndex: UInt32?, duration: Duration) -> NeighborFinding {
        let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)
        guard fd >= 0 else { return NeighborFinding(blocked: true, found: [:]) }
        defer { close(fd) }
        if var index = interfaceIndex {
            // IPV6_BOUND_IF(125): 이 인터페이스로만
            _ = setsockopt(fd, IPPROTO_IPV6, 125, &index, socklen_t(MemoryLayout<UInt32>.size))
        }
        let scope = interfaceIndex ?? 0

        // 찌르기: 에코를 all-nodes와 각 링크로컬에 보내 상대가 ND를 쏘게 한다(체크섬은 ICMPv6 DGRAM이라 커널이 채운다)
        let echo: [UInt8] = [128, 0, 0, 0, 0x4E, 0x47, 0, 1]
        send(echo, to: allNodes, scope: scope, fd: fd)
        for target in targets.prefix(32) { send(echo, to: target.bytes, scope: scope, fd: fd) }

        var found: [IPv6Address: MACAddress] = [:]
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        var buffer = [UInt8](repeating: 0, count: 1500)
        while clock.now < deadline {
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { break }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let wait = Int32(min(200, max(1, remaining.milliseconds)))
            guard poll(&descriptor, 1, wait) > 0 else { continue }
            var source = sockaddr_in6()
            var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let count = withUnsafeMutablePointer(to: &source) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
                }
            }
            guard count > 0 else { continue }
            guard let mac = NeighborDiscovery.mac(in: Array(buffer.prefix(count))) else { continue }
            var bytes = [UInt8](repeating: 0, count: 16)
            withUnsafeBytes(of: source.sin6_addr) { raw in for index in 0..<16 { bytes[index] = raw[index] } }
            if let ip = IPv6Address(bytes) { found[ip] = mac }
        }
        return NeighborFinding(blocked: false, found: found)
    }

    private static func send(_ packet: [UInt8], to address: [UInt8], scope: UInt32, fd: Int32) {
        var destination = sockaddr_in6()
        destination.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        destination.sin6_family = sa_family_t(AF_INET6)
        destination.sin6_scope_id = scope
        withUnsafeMutableBytes(of: &destination.sin6_addr) { raw in
            for (index, byte) in address.prefix(16).enumerated() { raw[index] = byte }
        }
        _ = withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
    }
    #else
    static func blockingHarvest(targets: [IPv6Address], interfaceIndex: UInt32?, duration: Duration) -> NeighborFinding {
        NeighborFinding(blocked: true, found: [:])
    }
    #endif
}
