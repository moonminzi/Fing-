/// TCP 포트 하나를 두드려 본 결과.
public enum PortProbeResult: Hashable, Sendable {
    /// 연결됨: 기기가 있고 포트가 열려 있다
    case open(Duration)
    /// 연결 거부(RST): 기기는 있고 포트는 닫혀 있다
    case refused(Duration)
    /// 커널이 "그런 호스트 없음"이라고 알려 줌(ARP 실패 등)
    case unreachable
    /// 시간 안에 답이 없음: 기기가 없거나 방화벽이 조용히 버린다
    case timeout
    /// 로컬 네트워크 권한이 없어 iOS가 막았다
    case localNetworkDenied

    /// 기기가 있다는 답이면 걸린 시간
    public var responseTime: Duration? {
        switch self {
        case .open(let time), .refused(let time): time
        case .unreachable, .timeout, .localNetworkDenied: nil
        }
    }
}

/// 주소 하나의 포트 하나에 TCP 연결을 시도한다. 앱은 NWConnection으로, 시험은 가짜로.
public protocol HostProbing: Sendable {
    func probe(_ host: IPv4, port: UInt16, timeout: Duration) async -> PortProbeResult
}

/// 탐색으로 찾은 기기.
public struct DiscoveredHost: Hashable, Sendable, Identifiable {
    public let address: IPv4
    /// 가장 빨리 온 답(연결 또는 거부)까지 걸린 시간
    public var responseTime: Duration
    /// 탐색 포트 중 열려 있던 것
    public var openPorts: [UInt16]

    public init(address: IPv4, responseTime: Duration, openPorts: [UInt16]) {
        self.address = address
        self.responseTime = responseTime
        self.openPorts = openPorts
    }

    public var id: IPv4 { address }
}

public enum ScanEvent: Hashable, Sendable {
    /// 전체 연결 시도 중 끝난 몫
    case progress(completed: Int, total: Int)
    /// 새로 찾았거나 정보가 늘어난 기기(같은 주소가 여러 번 올 수 있다)
    case host(DiscoveredHost)
    /// 로컬 네트워크 권한이 없어 스캔을 멈췄다
    case localNetworkDenied
}

public protocol NetworkScanning: Sendable {
    /// 주소들을 스캔하며 사건을 흘려보낸다. 다 끝나거나 받는 쪽이 그만두면(취소) 스트림이 끝난다.
    func scan(_ targets: [IPv4]) -> AsyncStream<ScanEvent>
}

public struct ScanConfiguration: Sendable {
    /// 흔히 열려 있는 포트: SSH, HTTP, HTTPS, SMB, AFP, AirPlay, HTTP 대체, iPhone 동기화(lockdown)
    public static let discoveryPorts: [UInt16] = [80, 62078, 443, 22, 445, 548, 7000, 8080]

    /// 두드려 볼 포트. 첫 번째 포트로 대역 전체를 먼저 훑는다
    public var ports: [UInt16]
    public var maxConcurrentConnections: Int
    public var timeout: Duration

    public init(
        ports: [UInt16] = ScanConfiguration.discoveryPorts,
        maxConcurrentConnections: Int = 50,
        timeout: Duration = .seconds(1)
    ) {
        self.ports = ports
        self.maxConcurrentConnections = max(1, maxConcurrentConnections)
        self.timeout = timeout
    }
}

/// 대역의 기기를 TCP 연결로 찾는다.
///
/// 연결되거나 거부(RST)되면 기기가 있는 것, 시간 초과면 없는 것으로 본다. 두 번에 나눠 훑는다:
/// 1. 모든 주소에 첫 포트 하나씩(동시 연결 `maxConcurrentConnections`개). 대부분의 기기는 여기서 바로 답한다.
/// 2. 1에서 답한 기기(열린 포트를 마저 알아보려고)와 답이 없던 주소에 나머지 포트를 한꺼번에.
///    없는 주소는 1에서 ARP가 실패해 커널이 곧바로 "호스트 없음"을 돌려주는 경우가 많아 빨리 끝나고,
///    방화벽 때문에 첫 포트에 답하지 않은 기기(iPhone의 62078, Windows의 445 등)는 여기서 찾는다.
public actor ScannerService: NetworkScanning {
    private let prober: any HostProbing
    public let configuration: ScanConfiguration

    public init(prober: any HostProbing, configuration: ScanConfiguration = ScanConfiguration()) {
        self.prober = prober
        self.configuration = configuration
    }

    public nonisolated func scan(_ targets: [IPv4]) -> AsyncStream<ScanEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                await self.run(targets, emit: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ targets: [IPv4], emit: AsyncStream<ScanEvent>.Continuation) async {
        let ports = configuration.ports
        guard let sweepPort = ports.first, !targets.isEmpty else { return }
        let otherPorts = Array(ports.dropFirst())
        let prober = self.prober
        let timeout = configuration.timeout
        let limit = configuration.maxConcurrentConnections

        let total = targets.count * ports.count
        var completed = 0
        var found: [IPv4: DiscoveredHost] = [:]
        var silent: [IPv4] = []
        var denied = false

        // 1. 첫 포트로 전체 훑기
        await forEachConcurrently(targets, limit: limit) { address in
            (address, await prober.probe(address, port: sweepPort, timeout: timeout))
        } onResult: { address, result in
            switch result {
            case .open(let time), .refused(let time):
                let isOpen = if case .open = result { true } else { false }
                let host = DiscoveredHost(address: address, responseTime: time, openPorts: isOpen ? [sweepPort] : [])
                found[address] = host
                emit.yield(.host(host))
                completed += 1
            case .timeout:
                silent.append(address)
                completed += 1
            case .unreachable:
                completed += ports.count
            case .localNetworkDenied:
                denied = true
                return false
            }
            emit.yield(.progress(completed: completed, total: total))
            return true
        }
        if denied {
            emit.yield(.localNetworkDenied)
            return
        }
        guard !otherPorts.isEmpty, !Task.isCancelled else { return }

        // 2. 나머지 포트: 찾은 기기 먼저(열린 포트를 빨리 채우려고), 그다음 답이 없던 주소
        let followUp = targets.filter { found[$0] != nil } + silent
        let hostLimit = max(1, limit / otherPorts.count)
        await forEachConcurrently(followUp, limit: hostLimit) { address in
            await Self.probe(address, ports: otherPorts, prober: prober, timeout: timeout)
        } onResult: { report in
            if report.denied {
                denied = true
                return false
            }
            completed += otherPorts.count
            if let merged = report.merged(into: found[report.address]) {
                found[report.address] = merged
                emit.yield(.host(merged))
            }
            emit.yield(.progress(completed: completed, total: total))
            return true
        }
        if denied {
            emit.yield(.localNetworkDenied)
        }
    }

    /// 한 주소의 여러 포트를 한꺼번에 두드린다. "호스트 없음"이나 권한 거부가 오면 나머지는 그만둔다.
    private static func probe(
        _ address: IPv4, ports: [UInt16], prober: any HostProbing, timeout: Duration
    ) async -> HostReport {
        await withTaskGroup(of: (UInt16, PortProbeResult).self) { group in
            for port in ports {
                group.addTask { (port, await prober.probe(address, port: port, timeout: timeout)) }
            }
            var report = HostReport(address: address)
            while let (port, result) = await group.next() {
                report.record(port, result)
                if result == .unreachable || result == .localNetworkDenied {
                    group.cancelAll()
                }
            }
            return report
        }
    }

    /// `items`를 최대 `limit`개씩 동시에 돌리고, 끝나는 순서대로 `onResult`에 넘긴다.
    /// `onResult`가 false를 돌려주거나 작업이 취소되면 남은 것은 시작하지 않고 돌던 것은 취소한다.
    private func forEachConcurrently<Item: Sendable, Output: Sendable>(
        _ items: [Item],
        limit: Int,
        operation: @escaping @Sendable (Item) async -> Output,
        onResult: (Output) -> Bool
    ) async {
        await withTaskGroup(of: Output.self) { group in
            var next = 0
            while next < min(limit, items.count) {
                let item = items[next]
                group.addTask { await operation(item) }
                next += 1
            }
            while let output = await group.next() {
                guard onResult(output), !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                if next < items.count {
                    let item = items[next]
                    group.addTask { await operation(item) }
                    next += 1
                }
            }
        }
    }
}

/// 한 주소에 여러 포트를 두드려 모은 답.
struct HostReport: Sendable {
    let address: IPv4
    var openPorts: [UInt16] = []
    var fastest: Duration?
    var denied = false

    mutating func record(_ port: UInt16, _ result: PortProbeResult) {
        if case .open = result {
            openPorts.append(port)
        }
        if let time = result.responseTime {
            fastest = min(fastest ?? time, time)
        }
        if result == .localNetworkDenied {
            denied = true
        }
    }

    /// 이미 찾은 기기 정보에 합친다. 기기가 있다는 증거가 하나도 없으면 nil.
    func merged(into existing: DiscoveredHost?) -> DiscoveredHost? {
        guard let existing else {
            guard let fastest else { return nil }
            return DiscoveredHost(address: address, responseTime: fastest, openPorts: openPorts.sorted())
        }
        var host = existing
        host.openPorts = Array(Set(existing.openPorts + openPorts)).sorted()
        if let fastest {
            host.responseTime = min(existing.responseTime, fastest)
        }
        return host
    }
}
