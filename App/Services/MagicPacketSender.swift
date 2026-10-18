import Foundation
import NagoNetCore
import Network

/// Wake-on-LAN 매직 패킷을 보낸다(UDP 포트 9·7).
///
/// 꺼진 기기는 IP가 없으므로 유니캐스트로는 안 닿고, 깨우려면 L2 브로드캐스트가 필요한데 iOS는 브로드캐스트에
/// 멀티캐스트 entitlement를 요구한다(TN3179). 그래서 entitlement 없이 되는 범위에서 두 곳으로 보낸다:
/// ① 마지막으로 본 IP(잠자기 중이거나 공유기가 IP↔MAC을 기억하는 기기에 닿는다)
/// ② 서브넷 브로드캐스트(x.x.x.255) — 시도는 하되 iOS가 막으면 조용히 실패한다.
/// 보냈는지(패킷을 내보냈는지)만 알 수 있고, 기기가 실제로 깨어났는지는 알 수 없다.
struct MagicPacketSender: Sendable {
    func wake(mac: MACAddress, lastKnownIP: IPv4, broadcast: IPv4?) async -> Bool {
        let packet = WakeOnLAN.magicPacket(for: mac)
        var sent = false
        for target in [lastKnownIP, broadcast].compactMap({ $0 }) {
            for port in WakeOnLAN.ports {
                if await WakeShot(host: target, port: port).send(packet) { sent = true }
            }
        }
        return sent
    }
}

private final class WakeShot: @unchecked Sendable {
    private let connection: NWConnection
    private let result = OneShot<Bool>()

    init(host: IPv4, port: UInt16) {
        let parameters = NWParameters.udp
        parameters.requiredInterfaceType = .wifi
        connection = NWConnection(
            host: .ipv4(IPv4Address(host.description)!),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters
        )
    }

    func send(_ packet: [UInt8]) async -> Bool {
        await withCheckedContinuation { continuation in
            result.wait(with: continuation)
            connection.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    connection.send(content: Data(packet), completion: .contentProcessed { [self] error in
                        finish(error == nil)
                    })
                case .waiting, .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            connection.start(queue: TCPProber.queue)
            TCPProber.queue.asyncAfter(deadline: .now() + 0.8) { [self] in finish(false) }
        }
    }

    private func finish(_ ok: Bool) {
        result.resume(ok)
        connection.cancel()
    }
}
