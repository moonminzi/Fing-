import Testing
@testable import NagoNetCore

struct ICMPTests {
    @Test func buildsEchoRequestWithValidChecksum() {
        let packet = ICMPEcho.request(identifier: 0x1234, sequence: 7, payload: [1, 2, 3])
        #expect(Array(packet.prefix(2)) == [8, 0])
        #expect(Array(packet[4..<8]) == [0x12, 0x34, 0, 7])
        // 체크섬까지 더해 다시 계산하면 0
        #expect(ICMPEcho.checksum(packet) == 0)
        // RFC 1071 예시
        #expect(ICMPEcho.checksum([0x00, 0x01, 0xF2, 0x03, 0xF4, 0xF5, 0xF6, 0xF7]) == ~UInt16(0xDDF2))
    }

    @Test func recognisesRepliesWithOrWithoutIPHeader() {
        let reply: [UInt8] = [0, 0, 0, 0, 0xAB, 0xCD, 0, 7] + [1, 2, 3]
        #expect(ICMPEcho.isReply(reply, sequence: 7))
        #expect(!ICMPEcho.isReply(reply, sequence: 8))
        // 애플 커널: IPv4 머리(20바이트)가 앞에 붙어 온다
        let ipHeader: [UInt8] = [0x45] + [UInt8](repeating: 0, count: 19)
        #expect(ICMPEcho.isReply(ipHeader + reply, sequence: 7))
        // 에코 요청(우리가 보낸 것)이나 잘린 것은 답이 아니다
        #expect(!ICMPEcho.isReply(ICMPEcho.request(identifier: 1, sequence: 7), sequence: 7))
        #expect(!ICMPEcho.isReply([0, 0, 0], sequence: 0))
    }

    @Test func statistics() {
        let stats = PingStatistics([.milliseconds(10), nil, .milliseconds(30), .milliseconds(20)])
        #expect(stats.sent == 4)
        #expect(stats.received == 3)
        #expect(stats.lossRate == 0.25)
        #expect(stats.minimum == .milliseconds(10))
        #expect(stats.maximum == .milliseconds(30))
        #expect(stats.average == .milliseconds(20))
        #expect(stats.jitter == .milliseconds(15))   // |10-30| = 20, |30-20| = 10 → 15
        #expect(PingStatistics([nil, nil]).average == nil)
        #expect(PingStatistics([]).lossRate == 0)
    }

    @Test(.enabled(if: ICMPPinger.isAvailable, "ICMP 데이터그램 소켓을 열 수 없는 기계(리눅스 ping_group_range)"))
    func pingsLoopback() async {
        let time = await ICMPPinger().ping(IPv4(127, 0, 0, 1), sequence: 3, timeout: .seconds(2))
        #expect(time != nil)
    }
}

/// 정해진 주소만 핑에 답한다.
private struct FakePinger: Pinging {
    let answering: Set<IPv4>
    func ping(_ address: IPv4, sequence: UInt16, timeout: Duration) async -> Duration? {
        answering.contains(address) ? .milliseconds(4) : nil
    }
}

private struct SilentProber: HostProbing {
    let refusing: Set<IPv4>
    func probe(_ host: IPv4, port: UInt16, timeout: Duration) async -> PortProbeResult {
        refusing.contains(host) ? .refused(.milliseconds(2)) : .timeout
    }
}

struct ScannerPingTests {
    @Test func findsDevicesThatOnlyAnswerPing() async {
        let tcp = IPv4(10, 0, 0, 2)
        let pingOnly = IPv4(10, 0, 0, 3)
        let scanner = ScannerService(prober: SilentProber(refusing: [tcp]), pinger: FakePinger(answering: [pingOnly, tcp]))
        var found: [IPv4: DiscoveredHost] = [:]
        for await case .host(let host) in scanner.scan(Array(IPv4(10, 0, 0, 1)...IPv4(10, 0, 0, 6))) {
            found[host.address] = host
        }
        #expect(Set(found.keys) == [tcp, pingOnly])
        #expect(found[pingOnly]?.viaPingOnly == true)
        #expect(found[tcp]?.viaPingOnly == false)

        var device = Device(address: pingOnly)
        device.merge(found[pingOnly]!)
        #expect(device.isPingOnly)
        device.merge(DiscoveredHost(address: pingOnly, responseTime: .milliseconds(1), openPorts: [80]))
        #expect(!device.isPingOnly)
    }
}

struct ExportTests {
    @Test func csvEscapesAndMarksNewDevices() {
        var router = Device(address: IPv4(192, 168, 0, 1), responseTime: .microseconds(2_500), openPorts: [443, 80], isGateway: true)
        router.merge(ServiceBanner(port: 80, title: "Office, \"Main\" Router"))
        var pad = Device(address: IPv4(192, 168, 0, 20), responseTime: .milliseconds(12), openPorts: [62078])
        pad.merge(BonjourService(name: "민지의 iPad", type: "_companion-link._tcp", address: pad.address))
        pad.alias = "교탁"
        let csv = DeviceCSV.make([pad, router], isNew: { $0.address == pad.address })
        let lines = csv.dropFirst().split(separator: "\r\n").map(String.init)
        #expect(csv.hasPrefix("\u{FEFF}IP,이름,별명,종류"))
        #expect(lines.count == 3)
        #expect(lines[1] == "192.168.0.1,\"Office, \"\"Main\"\" Router\",,공유기·AP,2.5,80 443,,,,")
        #expect(lines[2] == "192.168.0.20,민지의 iPad,교탁,태블릿,12.0,62078,민지의 iPad,,,예")
    }
}

struct RadarLayoutTests {
    private func device(_ last: UInt8, ms: Int?, ports: [UInt16] = [], gateway: Bool = false, me: Bool = false) -> Device {
        Device(address: IPv4(10, 0, 0, last), responseTime: ms.map { .milliseconds($0) }, openPorts: ports,
               isSelf: me, isGateway: gateway)
    }

    @Test func gatewayInCenterAndRingsByResponseTime() {
        let devices = [
            device(1, ms: 2, gateway: true), device(9, ms: nil, me: true), device(20, ms: 3),
            device(21, ms: 12), device(22, ms: 45), device(23, ms: 300), device(24, ms: nil),
        ]
        let points = Dictionary(uniqueKeysWithValues: RadarLayout.place(devices).map { ($0.address, $0) })
        #expect(points.count == devices.count)
        #expect(points[IPv4(10, 0, 0, 1)]?.radius == 0)
        #expect(points[IPv4(10, 0, 0, 9)]?.angle == 0)
        #expect(RadarLayout.ring(for: devices[2]) == 0)
        #expect(RadarLayout.ring(for: devices[3]) == 1)
        #expect(RadarLayout.ring(for: devices[4]) == 2)
        #expect(RadarLayout.ring(for: devices[5]) == 3)
        #expect(RadarLayout.ring(for: devices[6]) == 3)
        #expect(points.values.allSatisfy { (0...1).contains($0.radius) && (0..<(2 * Double.pi)).contains($0.angle) })
        // 바깥 고리일수록 멀리
        #expect(points[IPv4(10, 0, 0, 20)]!.radius < points[IPv4(10, 0, 0, 23)]!.radius)
    }

    @Test func sameKindsSitTogether() {
        let printers = (30...32).map { device(UInt8($0), ms: 8, ports: [9100, 631]) }
        let phones = (40...42).map { device(UInt8($0), ms: 8, ports: [62078]) }
        let points = RadarLayout.place(phones + printers)
        let order = points.sorted { $0.angle < $1.angle }.map { $0.address.octets[3] }
        #expect(order == [40, 41, 42, 30, 31, 32])   // iPhone이 프린터보다 앞(종류 순서)
        #expect(RadarLayout.place([]).isEmpty)
    }
}
