import Foundation
import NagoNetCore
import Network

/// 공유기에 TCP 연결을 열어 로컬 네트워크 권한을 확인한다.
///
/// 처음이면 이 연결이 iOS의 "로컬 네트워크 접근 허용" 창을 띄운다. 창이 떠 있는 동안과 거부된 동안에는
/// 연결이 `.waiting` + `.localNetworkDenied`에 머물고, 사용자가 허용하면(창이나 설정 앱에서) iOS가 알아서
/// 다시 연결하므로 그때 `.granted`를 보낸다.
struct LocalNetworkAccess: LocalNetworkAccessChecking {
    /// 거부 신호 없이 이만큼 지나면 허용된 것으로 본다(공유기가 포트를 조용히 버려 답이 없을 때)
    var grace: Duration = .seconds(2)

    func signals(probing host: IPv4) -> AsyncStream<LocalNetworkSignal> {
        AsyncStream { continuation in
            let watch = AccessWatch(host: host, grace: grace, continuation: continuation)
            continuation.onTermination = { _ in watch.stop() }
            watch.start()
        }
    }
}

private final class AccessWatch: @unchecked Sendable {
    private let connection: NWConnection
    private let grace: Duration
    private let continuation: AsyncStream<LocalNetworkSignal>.Continuation
    private let lock = NSLock()
    private var isDenied = false
    private var isFinished = false

    init(host: IPv4, grace: Duration, continuation: AsyncStream<LocalNetworkSignal>.Continuation) {
        connection = TCPProber.connection(to: host, port: 80, connectTimeout: .seconds(3))
        self.grace = grace
        self.continuation = continuation
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in handle(state) }
        connection.start(queue: TCPProber.queue)
        scheduleGrace()
    }

    func stop() {
        connection.cancel()
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .waiting, .failed:
            if TCPProber.isLocalNetworkDenied(connection) {
                let isNew = lock.withLock {
                    defer { isDenied = true }
                    return !isDenied
                }
                if isNew { continuation.yield(.denied) }
            } else {
                // 경로는 열렸고 공유기가 거부했거나 시간이 지났다: 권한은 있다
                grant()
            }
        case .preparing:
            // 허용된 뒤 iOS가 다시 연결하는 중
            let wasDenied = lock.withLock {
                defer { isDenied = false }
                return isDenied
            }
            if wasDenied { scheduleGrace() }
        case .ready:
            grant()
        case .setup, .cancelled:
            break
        @unknown default:
            break
        }
    }

    private func scheduleGrace() {
        TCPProber.queue.asyncAfter(deadline: .now() + grace.milliseconds / 1_000) { [self] in
            if !lock.withLock({ isDenied }) { grant() }
        }
    }

    private func grant() {
        let isFirst = lock.withLock {
            defer { isFinished = true }
            return !isFinished
        }
        guard isFirst else { return }
        continuation.yield(.granted)
        continuation.finish()
        connection.cancel()
    }
}
