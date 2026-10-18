import Foundation
import NagoNetCore
import Network

/// NWConnection으로 TCP 연결을 한 번 시도해 기기가 있는지 본다.
///
/// - 연결되면 `.open`, 거부(ECONNREFUSED)면 `.refused`: 둘 다 기기가 있다는 뜻
/// - NWConnection은 거부될 때 `.failed`가 아니라 `.waiting(ECONNREFUSED)`로 가서 다시 시도하려 하므로 둘 다 처리한다
/// - 로컬 네트워크 권한이 없으면 `.waiting` + `unsatisfiedReason == .localNetworkDenied`(TN3179)
struct TCPProber: HostProbing {
    static let queue = DispatchQueue(label: "nagonet.tcp-probe", qos: .userInitiated)

    func probe(_ host: IPv4, port: UInt16, timeout: Duration) async -> PortProbeResult {
        let attempt = TCPAttempt(host: host, port: port, connectTimeout: timeout)
        return await withTaskCancellationHandler {
            await attempt.run(timeout: timeout)
        } onCancel: {
            attempt.finish(.timeout)
        }
    }

    /// VPN이 켜져 있어도 Wi-Fi로 나가게 한다.
    static func parameters(connectTimeout: Duration) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = max(1, Int(connectTimeout.milliseconds / 1_000) + 1)
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.requiredInterfaceType = .wifi
        parameters.preferNoProxies = true
        return parameters
    }

    static func connection(to host: IPv4, port: UInt16, connectTimeout: Duration) -> NWConnection {
        NWConnection(
            host: .ipv4(IPv4Address(host.description)!),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters(connectTimeout: connectTimeout)
        )
    }

    static func isLocalNetworkDenied(_ connection: NWConnection) -> Bool {
        if case .localNetworkDenied? = connection.currentPath?.unsatisfiedReason { return true }
        return false
    }

    /// NWError를 결과로 바꾼다. 거부면 기기가 있는 것, "호스트 없음"류는 없는 것, 나머지는 시간 초과로 본다.
    static func classify(_ error: NWError, elapsed: Duration) -> PortProbeResult {
        guard case .posix(let code) = error else { return .timeout }
        switch code {
        case .ECONNREFUSED, .ECONNRESET:
            return .refused(elapsed)
        case .EHOSTDOWN, .EHOSTUNREACH, .ENETUNREACH, .ENETDOWN:
            return .unreachable
        default:
            return .timeout
        }
    }
}

/// 연결 시도 한 번. 상태 변화·타이머·취소 중 무엇이 먼저 오든 결과는 딱 한 번만 돌려준다.
private final class TCPAttempt: @unchecked Sendable {
    private enum Phase {
        case idle
        case running(CheckedContinuation<PortProbeResult, Never>)
        case done
    }

    private let connection: NWConnection
    private let lock = NSLock()
    private var phase = Phase.idle

    init(host: IPv4, port: UInt16, connectTimeout: Duration) {
        connection = TCPProber.connection(to: host, port: port, connectTimeout: connectTimeout)
    }

    func run(timeout: Duration) async -> PortProbeResult {
        await withCheckedContinuation { continuation in
            let cancelledEarly = lock.withLock {
                if case .done = phase { return true }
                phase = .running(continuation)
                return false
            }
            if cancelledEarly {
                continuation.resume(returning: .timeout)
                return
            }
            let start = ContinuousClock.now
            connection.stateUpdateHandler = { [self] state in
                handle(state, elapsed: start.duration(to: .now))
            }
            connection.start(queue: TCPProber.queue)
            TCPProber.queue.asyncAfter(deadline: .now() + timeout.milliseconds / 1_000) { [self] in
                finish(.timeout)
            }
        }
    }

    private func handle(_ state: NWConnection.State, elapsed: Duration) {
        switch state {
        case .ready:
            finish(.open(elapsed))
        case .waiting(let error), .failed(let error):
            if TCPProber.isLocalNetworkDenied(connection) {
                finish(.localNetworkDenied)
            } else {
                finish(TCPProber.classify(error, elapsed: elapsed))
            }
        case .cancelled:
            finish(.timeout)
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    func finish(_ result: PortProbeResult) {
        let continuation: CheckedContinuation<PortProbeResult, Never>? = lock.withLock {
            defer { phase = .done }
            if case .running(let continuation) = phase { return continuation }
            return nil
        }
        guard let continuation else { return }
        connection.cancel()
        continuation.resume(returning: result)
    }
}
