import Foundation
import NagoNetCore
import Network

/// NWConnection(UDP)으로 데이터그램 하나를 보내고 첫 답을 받는다. mDNS 유니캐스트·NetBIOS 이름 질의에 쓴다.
///
/// 멀티캐스트가 아니라 기기 주소로 직접 보내므로 멀티캐스트 entitlement 없이 로컬 네트워크 권한만 있으면 된다.
struct UDPExchange: DatagramExchanging {
    func exchange(_ payload: [UInt8], with host: IPv4, port: UInt16, timeout: Duration) async -> [UInt8]? {
        let attempt = UDPAttempt(host: host, port: port)
        return await withTaskCancellationHandler {
            await attempt.run(payload, timeout: timeout)
        } onCancel: {
            attempt.finish(nil)
        }
    }
}

private final class UDPAttempt: @unchecked Sendable {
    private let connection: NWConnection
    private let result = OneShot<[UInt8]?>()

    init(host: IPv4, port: UInt16) {
        let parameters = NWParameters.udp
        parameters.requiredInterfaceType = .wifi
        connection = NWConnection(
            host: .ipv4(IPv4Address(host.description)!),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters
        )
    }

    func run(_ payload: [UInt8], timeout: Duration) async -> [UInt8]? {
        await withCheckedContinuation { continuation in
            result.wait(with: continuation)
            connection.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    send(payload)
                case .waiting, .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: TCPProber.queue)
            TCPProber.queue.asyncAfter(deadline: .now() + timeout.milliseconds / 1_000) { [self] in
                finish(nil)
            }
        }
    }

    private func send(_ payload: [UInt8]) {
        connection.send(content: Data(payload), completion: .contentProcessed { [self] error in
            if error != nil { finish(nil) }
        })
        // 포트가 닫혀 있으면 ICMP "포트 닿지 않음"이 와서 에러로 끝난다
        connection.receiveMessage { [self] data, _, _, _ in
            finish(data.map { [UInt8]($0) })
        }
    }

    func finish(_ reply: [UInt8]?) {
        result.resume(reply)
        connection.cancel()
    }
}
