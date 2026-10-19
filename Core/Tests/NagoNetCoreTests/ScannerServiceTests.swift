import Testing
@testable import NagoNetCore

/// 동시에 몇 개가 돌았는지, 누구를 몇 번 두드렸는지 센다.
private actor ProbeLog {
    private(set) var inFlight = 0
    private(set) var peak = 0
    private(set) var calls: [IPv4: [UInt16]] = [:]

    func enter(_ host: IPv4, _ port: UInt16) {
        inFlight += 1
        peak = max(peak, inFlight)
        calls[host, default: []].append(port)
    }

    func leave() {
        inFlight -= 1
    }

    var totalCalls: Int { calls.values.map(\.count).reduce(0, +) }
}

/// 주소·포트별 답을 미리 정해 둔 가짜 prober.
private struct FakeProber: HostProbing {
    var answers: [IPv4: [UInt16: PortProbeResult]] = [:]
    var fallback: PortProbeResult = .unreachable
    var delay: Duration = .milliseconds(1)
    let log = ProbeLog()

    func probe(_ host: IPv4, port: UInt16, timeout: Duration) async -> PortProbeResult {
        await log.enter(host, port)
        let cancelled = (try? await Task.sleep(for: delay)) == nil
        await log.leave()
        if cancelled { return .timeout }
        return answers[host]?[port] ?? fallback
    }
}

private func ip(_ last: UInt8) -> IPv4 { IPv4(10, 0, 0, last) }
private let ms = Duration.milliseconds

private func collect(_ stream: AsyncStream<ScanEvent>) async -> [ScanEvent] {
    var events: [ScanEvent] = []
    for await event in stream { events.append(event) }
    return events
}

private func hosts(in events: [ScanEvent]) -> [IPv4: DiscoveredHost] {
    var result: [IPv4: DiscoveredHost] = [:]
    for case .host(let host) in events { result[host.address] = host }
    return result
}

struct ScannerServiceTests {
    @Test func findsHostsByConnectOrRefuseAndCollectsOpenPorts() async {
        var prober = FakeProber()
        let ports = ScanConfiguration.discoveryPorts
        // 공유기: 80·443 열림, 나머지 거부
        prober.answers[ip(1)] = Dictionary(uniqueKeysWithValues: ports.map { ($0, .refused(ms(3))) })
        prober.answers[ip(1)]?[80] = .open(ms(2))
        prober.answers[ip(1)]?[443] = .open(ms(4))
        // 방화벽 있는 iPhone: 62078만 답한다
        prober.answers[ip(5)] = Dictionary(uniqueKeysWithValues: ports.map { ($0, .timeout) })
        prober.answers[ip(5)]?[62078] = .open(ms(9))
        // 포트는 다 닫혔지만 RST로 답하는 기기
        prober.answers[ip(7)] = Dictionary(uniqueKeysWithValues: ports.map { ($0, .refused(ms(6))) })
        // 아무 답 없는 주소
        prober.answers[ip(9)] = Dictionary(uniqueKeysWithValues: ports.map { ($0, .timeout) })

        let scanner = ScannerService(prober: prober)
        let targets = Array(ip(1)...ip(20))
        let events = await collect(scanner.scan(targets))

        let found = hosts(in: events)
        #expect(Set(found.keys) == [ip(1), ip(5), ip(7)])
        #expect(found[ip(1)]?.openPorts == [80, 443])
        #expect(found[ip(1)]?.responseTime == ms(2))
        #expect(found[ip(5)]?.openPorts == [62078])
        #expect(found[ip(7)]?.openPorts == [])
        #expect(events.last == .progress(completed: targets.count * ports.count, total: targets.count * ports.count))
        #expect(!events.contains(.localNetworkDenied))
    }

    @Test func unreachableHostsAreNotProbedAgain() async {
        var prober = FakeProber()
        prober.answers[ip(2)] = [80: .refused(ms(1))]
        let scanner = ScannerService(prober: prober)
        _ = await collect(scanner.scan(Array(ip(1)...ip(10))))

        let calls = await prober.log.calls
        #expect(calls[ip(1)] == [80])
        #expect(calls[ip(2)]?.count == ScanConfiguration.discoveryPorts.count)
    }

    @Test func secondPassStopsHostOnUnreachable() async {
        var prober = FakeProber(delay: .milliseconds(2))
        // 첫 포트는 시간 초과, 둘째 포트에서 "호스트 없음"
        prober.answers[ip(3)] = [80: .timeout, 62078: .unreachable]
        let config = ScanConfiguration(ports: [80, 62078, 443, 22], timeout: .seconds(1))
        let scanner = ScannerService(prober: prober, configuration: config)
        let events = await collect(scanner.scan([ip(3)]))
        #expect(hosts(in: events).isEmpty)
        #expect(events.last == .progress(completed: 4, total: 4))
    }

    @Test func neverExceedsConnectionLimit() async {
        let prober = FakeProber(fallback: .timeout, delay: .milliseconds(3))
        let config = ScanConfiguration(maxConcurrentConnections: 20)
        let scanner = ScannerService(prober: prober, configuration: config)
        let targets = Array(IPv4(10, 0, 0, 1)...IPv4(10, 0, 0, 120))
        _ = await collect(scanner.scan(targets))

        let peak = await prober.log.peak
        #expect(peak <= 20)
        #expect(peak >= 14)   // 실제로 여러 개가 동시에 돌았는지
        #expect(await prober.log.totalCalls == targets.count * ScanConfiguration.discoveryPorts.count)
    }

    @Test func stopsAndReportsWhenLocalNetworkDenied() async {
        let prober = FakeProber(fallback: .localNetworkDenied)
        let scanner = ScannerService(prober: prober)
        let events = await collect(scanner.scan(Array(IPv4(10, 0, 0, 1)...IPv4(10, 0, 1, 254))))
        #expect(events.last == .localNetworkDenied)
        #expect(hosts(in: events).isEmpty)
        // 첫 묶음(동시 50개) 언저리에서 멈춘다
        #expect(await prober.log.totalCalls <= 100)
    }

    @Test func consumerCancellationStopsProbing() async throws {
        let prober = FakeProber(fallback: .timeout, delay: .milliseconds(5))
        let scanner = ScannerService(prober: prober)
        let targets = Array(IPv4(10, 0, 0, 1)...IPv4(10, 0, 3, 254))

        var seen = 0
        for await _ in scanner.scan(targets) {
            seen += 1
            if seen == 3 { break }
        }
        try await Task.sleep(for: .milliseconds(100))
        let callsAfterCancel = await prober.log.totalCalls
        try await Task.sleep(for: .milliseconds(100))
        #expect(await prober.log.totalCalls == callsAfterCancel)
        #expect(callsAfterCancel < targets.count)
        #expect(await prober.log.inFlight == 0)
    }

    @Test func emptyTargetsFinishImmediately() async {
        let scanner = ScannerService(prober: FakeProber())
        #expect(await collect(scanner.scan([])).isEmpty)
    }
}

struct DeviceTests {
    @Test func sortsByAddressNumerically() {
        let devices = [ip(20), ip(3), ip(100)].map { Device(address: $0) }
        #expect(devices.sorted(by: .address).map(\.address) == [ip(3), ip(20), ip(100)])
    }

    @Test func sortsNamedFirstThenByAddress() {
        let devices = [
            Device(address: ip(9)),
            Device(address: ip(1), isGateway: true),
            Device(address: ip(4)),
            Device(address: ip(30), isSelf: true),
        ]
        // "공유기" < "이 기기" (가나다), 이름 없는 기기는 IP순
        #expect(devices.sorted(by: .name).map(\.address) == [ip(1), ip(30), ip(4), ip(9)])
    }

    @Test func mergeKeepsFastestTimeAndUnionOfPorts() {
        var device = Device(address: ip(1), responseTime: ms(8), openPorts: [80])
        device.merge(DiscoveredHost(address: ip(1), responseTime: ms(3), openPorts: [443, 80]))
        #expect(device.responseTime == ms(3))
        #expect(device.openPorts == [80, 443])
        device.merge(DiscoveredHost(address: ip(1), responseTime: ms(5), openPorts: []))
        #expect(device.responseTime == ms(3))
    }

    @Test func scanTargetsSkipMeAndAddOutOfRangeGateway() throws {
        let home = NetworkSnapshot(
            interfaceName: "en0",
            subnet: try #require(Subnet(address: IPv4(192, 168, 0, 23), prefixLength: 24)),
            gateway: Gateway(address: IPv4(192, 168, 0, 1), isEstimated: false)
        )
        #expect(home.scanTargets.count == 253)
        #expect(!home.scanTargets.contains(IPv4(192, 168, 0, 23)))

        // /16에서 내 /22 칸 밖에 있는 공유기도 두드린다
        let campus = NetworkSnapshot(
            interfaceName: "en0",
            subnet: try #require(Subnet(address: IPv4(10, 0, 5, 23), prefixLength: 16)),
            gateway: Gateway(address: IPv4(10, 0, 0, 1), isEstimated: false)
        )
        #expect(campus.scanTargets.first == IPv4(10, 0, 0, 1))
        #expect(campus.scanTargets.count == 1024)
    }

    @Test func formatsResponseTime() {
        #expect(Duration.microseconds(400).shortDescription == "<1 ms")
        #expect(Duration.microseconds(12_400).shortDescription == "12 ms")
        #expect(Duration.milliseconds(1_250).shortDescription == "1.2 s")
    }
}
