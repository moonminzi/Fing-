import Foundation
import NagoNetCore
import Network
import Security

/// 열린 포트에 연결해 배너를 읽는다.
///
/// - HTTP: `GET /`을 보내 머리(Server, WWW-Authenticate)와 `<title>`까지
/// - HTTPS: 자체 서명 인증서도 받아들이고(기기 관리 페이지는 거의 자체 서명) 인증서 이름도 읽는다
/// - SSH: 연결하자마자 서버가 보내는 첫 줄
struct BannerGrabber: BannerGrabbing {
    var timeout: Duration = .milliseconds(2500)

    func banner(of address: IPv4, port: UInt16) async -> ServiceBanner? {
        let isSSH = BannerPorts.ssh.contains(port)
        let request = isSSH ? nil : Array(
            "GET / HTTP/1.0\r\nHost: \(address)\r\nUser-Agent: NAGO-NET\r\nAccept: text/html\r\nConnection: close\r\n\r\n".utf8
        )
        let read = StreamRead(host: address, port: port, tls: BannerPorts.https.contains(port), request: request, stopAtLineEnd: isSSH)
        let output = await withTaskCancellationHandler {
            await read.run(timeout: timeout)
        } onCancel: {
            read.stop()
        }
        if isSSH {
            return ServiceBanner.ssh(port: port, greeting: output.bytes)
        }
        return ServiceBanner.http(port: port, response: output.bytes, certificate: output.certificate)
    }
}

/// 연결해서 (요청을 보내고) 받은 바이트를 모은다. 끝나거나, 충분히 받았거나, 시간이 다 되면 그때까지 받은 것을 돌려준다.
private final class StreamRead: @unchecked Sendable {
    struct Output: Sendable {
        var bytes: [UInt8] = []
        var certificate: String?
    }

    private static let maxBytes = 32 * 1024

    private let request: [UInt8]?
    private let stopAtLineEnd: Bool
    private let result = OneShot<Output>()
    private let lock = NSLock()
    private var output = Output()
    private var connection: NWConnection!

    init(host: IPv4, port: UInt16, tls: Bool, request: [UInt8]?, stopAtLineEnd: Bool) {
        self.request = request
        self.stopAtLineEnd = stopAtLineEnd
        connection = NWConnection(
            host: .ipv4(IPv4Address(host.description)!),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters(tls: tls)
        )
    }

    private func parameters(tls: Bool) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 3
        var tlsOptions: NWProtocolTLS.Options?
        if tls {
            let options = NWProtocolTLS.Options()
            // 관리 페이지는 자체 서명 인증서라 검증하지 않고 받는다(읽기만 하고 아무것도 보내지 않는다)
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { [weak self] _, trust, complete in
                self?.record(trust: trust)
                complete(true)
            }, TCPProber.queue)
            tlsOptions = options
        }
        let parameters = NWParameters(tls: tlsOptions, tcp: tcp)
        parameters.requiredInterfaceType = .wifi
        return parameters
    }

    private func record(trust: sec_trust_t) {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
              let leaf = chain.first,
              let summary = SecCertificateCopySubjectSummary(leaf) as String? else { return }
        lock.withLock { output.certificate = summary }
    }

    func run(timeout: Duration) async -> Output {
        await withCheckedContinuation { continuation in
            result.wait(with: continuation)
            connection.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    if let request {
                        connection.send(content: Data(request), completion: .contentProcessed { _ in })
                    }
                    receive()
                case .waiting, .failed, .cancelled:
                    finish()
                default:
                    break
                }
            }
            connection.start(queue: TCPProber.queue)
            TCPProber.queue.asyncAfter(deadline: .now() + timeout.milliseconds / 1_000) { [self] in
                finish()
            }
        }
    }

    func stop() {
        finish()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [self] data, _, isComplete, error in
            let isDone = lock.withLock {
                if let data { output.bytes += data }
                if isComplete || error != nil || output.bytes.count >= Self.maxBytes { return true }
                if stopAtLineEnd { return output.bytes.contains(0x0A) }
                return String(decoding: output.bytes, as: UTF8.self).range(of: "</title>", options: .caseInsensitive) != nil
            }
            if isDone { finish() } else { receive() }
        }
    }

    private func finish() {
        result.resume(lock.withLock { output })
        connection.cancel()
    }
}
