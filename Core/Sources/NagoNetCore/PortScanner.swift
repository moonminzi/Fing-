public enum PortScanEvent: Hashable, Sendable {
    case progress(completed: Int, total: Int)
    /// 열린 포트를 찾았다(연결 성공)
    case open(UInt16)
    /// 로컬 네트워크 권한이 없어 멈췄다
    case localNetworkDenied
}

/// 기기 하나의 여러 포트를 두드린다.
public protocol PortScanning: Sendable {
    /// 다 끝나거나 받는 쪽이 그만두면(취소) 스트림이 끝난다.
    func scan(_ address: IPv4, ports: [UInt16]) -> AsyncStream<PortScanEvent>
}

/// 한 기기의 포트를 동시에 `maxConcurrentConnections`개씩 TCP 연결로 확인한다. 연결되면 열림, 거부·시간 초과면 닫힘.
public struct PortScanner: PortScanning {
    private let prober: any HostProbing
    private let maxConcurrentConnections: Int
    private let timeout: Duration

    public init(prober: any HostProbing, maxConcurrentConnections: Int = 20, timeout: Duration = .seconds(1)) {
        self.prober = prober
        self.maxConcurrentConnections = max(1, maxConcurrentConnections)
        self.timeout = timeout
    }

    public func scan(_ address: IPv4, ports: [UInt16]) -> AsyncStream<PortScanEvent> {
        let prober = self.prober
        let limit = maxConcurrentConnections
        let timeout = self.timeout
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                await withTaskGroup(of: (UInt16, PortProbeResult).self) { group in
                    var next = 0
                    var completed = 0
                    func addNext() {
                        let port = ports[next]
                        next += 1
                        group.addTask { (port, await prober.probe(address, port: port, timeout: timeout)) }
                    }
                    while next < min(limit, ports.count) { addNext() }
                    while let (port, result) = await group.next() {
                        completed += 1
                        switch result {
                        case .open:
                            continuation.yield(.open(port))
                        case .localNetworkDenied:
                            continuation.yield(.localNetworkDenied)
                            group.cancelAll()
                            return
                        case .refused, .unreachable, .timeout:
                            break
                        }
                        continuation.yield(.progress(completed: completed, total: ports.count))
                        if Task.isCancelled {
                            group.cancelAll()
                            return
                        }
                        if next < ports.count { addNext() }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
