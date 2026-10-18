import Testing
@testable import NagoNetCore

/// `sysctl(NET_RT_FLAGS)`가 돌려주는 바이트를 XNU 배치대로 만들어 푼다.
struct RouteTableTests {
    // MARK: 바이트 만들기

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(v >> (8 * $0) & 0xFF) } }

    /// sockaddr_in(16바이트)
    private func inet(_ ip: IPv4) -> [UInt8] {
        [16, 2, 0, 0] + ip.octets + [UInt8](repeating: 0, count: 8)
    }

    /// 커널이 뒤쪽 0바이트를 잘라 보내는 넷마스크(255.255.255.0이면 길이 7)
    private func mask(_ ip: IPv4) -> [UInt8] {
        var octets = ip.octets
        while let last = octets.last, last == 0 { octets.removeLast() }
        return octets.isEmpty ? [0] : [UInt8(4 + octets.count), 0xFF, 0, 0] + octets
    }

    /// AF_LINK 게이트웨이(sockaddr_dl, 길이 20)
    private func link() -> [UInt8] {
        [20, 18] + [UInt8](repeating: 0, count: 18)
    }

    private func padded(_ sockaddr: [UInt8]) -> [UInt8] {
        let length = Int(sockaddr[0])
        let size = length > 0 ? 1 + ((length - 1) | 3) : 4
        return sockaddr + [UInt8](repeating: 0, count: size - sockaddr.count)
    }

    private func message(index: UInt16, flags: Int32 = 0x803, version: UInt8 = 5, _ slots: [Int: [UInt8]]) -> [UInt8] {
        var addrs: UInt32 = 0
        var tail: [UInt8] = []
        for slot in slots.keys.sorted() {
            addrs |= 1 << UInt32(slot)
            tail += padded(slots[slot]!)
        }
        var header: [UInt8] = le16(0)
        header += [version, 4]                  // rtm_version, rtm_type(RTM_GET)
        header += le16(index) + [0, 0]          // rtm_index + 맞춤용 빈칸
        header += le32(UInt32(bitPattern: flags))
        header += le32(addrs)
        header += [UInt8](repeating: 0, count: RouteTable.headerSize - header.count)
        var bytes = header + tail
        bytes.replaceSubrange(0..<2, with: le16(UInt16(bytes.count)))
        return bytes
    }

    private let any = IPv4(0)

    // MARK: 시험

    @Test func headerMatchesXNULayout() {
        #expect(RouteTable.headerSize == 92)
        #expect(message(index: 1, [:]).count == 92)
    }

    @Test func parsesDefaultRoute() throws {
        let bytes = message(index: 6, [0: inet(any), 1: inet(IPv4(192, 168, 0, 1)), 2: [0]])
        let routes = RouteTable.parse(bytes)
        #expect(routes.count == 1)
        let route = try #require(routes.first)
        #expect(route.interfaceIndex == 6)
        #expect(route.destination == any)
        #expect(route.gateway == IPv4(192, 168, 0, 1))
        #expect(route.netmask == any)
        #expect(route.isDefault)
    }

    @Test func parsesTruncatedNetmaskAndMultipleMessages() {
        let subnetRoute = message(index: 6, [
            0: inet(IPv4(10, 8, 0, 0)), 1: inet(IPv4(192, 168, 0, 1)), 2: mask(IPv4(255, 255, 255, 0)),
        ])
        let defaultRoute = message(index: 6, [0: inet(any), 1: inet(IPv4(192, 168, 0, 1)), 2: mask(any)])
        let routes = RouteTable.parse(subnetRoute + defaultRoute)
        #expect(routes.count == 2)
        #expect(routes[0].netmask == IPv4(255, 255, 255, 0))
        #expect(!routes[0].isDefault)
        #expect(routes[1].isDefault)
    }

    @Test func linkLayerGatewayIsNotAnAddress() {
        let bytes = message(index: 6, [0: inet(IPv4(192, 168, 0, 7)), 1: link()])
        #expect(RouteTable.parse(bytes).first?.gateway == nil)
    }

    @Test func skipsUnknownVersionAndStopsOnGarbage() {
        let unknown = message(index: 6, version: 9, [0: inet(any), 1: inet(IPv4(192, 168, 0, 1))])
        let good = message(index: 7, [0: inet(any), 1: inet(IPv4(192, 168, 0, 1))])
        #expect(RouteTable.parse(unknown + good).map(\.interfaceIndex) == [7])

        // 길이 0이나 남은 바이트보다 긴 메시지에서 멈춘다(무한 반복 없이)
        #expect(RouteTable.parse([0, 0, 5, 4] + [UInt8](repeating: 0, count: 100)).isEmpty)
        #expect(RouteTable.parse(good + [0xFF, 0xFF, 5, 4]).count == 1)
        #expect(RouteTable.parse(Array(good.prefix(50))).isEmpty)
        #expect(RouteTable.parse([]).isEmpty)
    }

    @Test func truncatedSockaddrsDoNotCrash() {
        var bytes = message(index: 6, [0: inet(any), 1: inet(IPv4(192, 168, 0, 1))])
        bytes.removeLast(10)
        bytes.replaceSubrange(0..<2, with: le16(UInt16(bytes.count)))
        let route = RouteTable.parse(bytes).first
        #expect(route?.destination == any)
        #expect(route?.gateway == nil)
    }

    // MARK: 게이트웨이 고르기

    private let wifi = Subnet(address: IPv4(192, 168, 0, 23), prefixLength: 24)!

    @Test func picksWiFiDefaultRouteEvenWithVPN() {
        let routes = [
            // VPN(utun, 번호 9)의 기본 경로가 먼저 와도
            Route(interfaceIndex: 9, flags: 0x803, destination: any, gateway: IPv4(10, 8, 0, 1), netmask: any),
            Route(interfaceIndex: 6, flags: 0x803, destination: any, gateway: IPv4(192, 168, 0, 254), netmask: any),
        ]
        let gateway = Gateway.resolve(subnet: wifi, routes: routes, interfaceIndex: 6)
        #expect(gateway == Gateway(address: IPv4(192, 168, 0, 254), isEstimated: false))
    }

    @Test func prefersMatchingInterface() {
        let routes = [
            Route(interfaceIndex: 3, flags: 0x803, destination: any, gateway: IPv4(192, 168, 0, 2), netmask: nil),
            Route(interfaceIndex: 6, flags: 0x803, destination: any, gateway: IPv4(192, 168, 0, 1), netmask: nil),
        ]
        #expect(Gateway.resolve(subnet: wifi, routes: routes, interfaceIndex: 6).address == IPv4(192, 168, 0, 1))
        #expect(Gateway.resolve(subnet: wifi, routes: routes, interfaceIndex: nil).address == IPv4(192, 168, 0, 2))
    }

    @Test func estimatesWhenRoutesMissingOrUnusable() {
        let estimated = Gateway(address: IPv4(192, 168, 0, 1), isEstimated: true)
        #expect(Gateway.resolve(subnet: wifi, routes: nil, interfaceIndex: 6) == estimated)
        #expect(Gateway.resolve(subnet: wifi, routes: [], interfaceIndex: 6) == estimated)

        let unusable = [
            // 대역 밖 게이트웨이
            Route(interfaceIndex: 6, flags: 0x803, destination: any, gateway: IPv4(10, 0, 0, 1), netmask: any),
            // 기본 경로가 아님
            Route(interfaceIndex: 6, flags: 0x803, destination: IPv4(172, 16, 0, 0), gateway: IPv4(192, 168, 0, 9),
                  netmask: IPv4(255, 255, 0, 0)),
            // 게이트웨이가 나 자신
            Route(interfaceIndex: 6, flags: 0x803, destination: any, gateway: IPv4(192, 168, 0, 23), netmask: any),
        ]
        #expect(Gateway.resolve(subnet: wifi, routes: unusable, interfaceIndex: 6) == estimated)
    }

    @Test func endToEndFromBytes() {
        let bytes = message(index: 9, [0: inet(any), 1: inet(IPv4(10, 8, 0, 1)), 2: [0]])
            + message(index: 6, [0: inet(any), 1: inet(IPv4(192, 168, 0, 1)), 2: [0]])
        let gateway = Gateway.resolve(subnet: wifi, routes: RouteTable.parse(bytes), interfaceIndex: 6)
        #expect(gateway == Gateway(address: IPv4(192, 168, 0, 1), isEstimated: false))
    }
}

#if canImport(Darwin)
/// 맥(iOS와 같은 XNU)에서 진짜 라우팅 테이블을 읽어 구조체 배치(92바이트 머리)가 맞는지 확인한다.
struct LiveRouteTableTests {
    @Test func defaultGatewayLiesInItsInterfaceSubnet() throws {
        let routes = try #require(RouteTable.read())
        let defaults = routes.filter(\.isDefault)
        print("기본 경로:", defaults)
        try #require(!defaults.isEmpty, "네트워크가 없는 기계에서는 확인할 수 없다")

        let interfaces = Interfaces.ipv4Addresses()
        let consistent = defaults.contains { route in
            guard let gateway = route.gateway else { return false }
            return interfaces.contains { interface in
                Interfaces.index(of: interface.name) == route.interfaceIndex
                    && Subnet(address: interface.address, mask: interface.netmask)?.contains(gateway) == true
            }
        }
        #expect(consistent)
    }
}
#endif
