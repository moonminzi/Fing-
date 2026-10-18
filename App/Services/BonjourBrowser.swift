import Foundation
import NagoNetCore
import Network

/// NWBrowser로 Bonjour 서비스를 찾고, 서비스마다 잠깐 연결해 IPv4 주소로 푼다.
///
/// NWBrowser는 이름·종류·TXT만 주고 주소는 주지 않는다. 서비스 엔드포인트로 NWConnection을 열면
/// 시스템이 주소를 풀어 주므로(`currentPath.remoteEndpoint`) 그 주소만 읽고 바로 끊는다.
struct BonjourBrowser: BonjourBrowsing {
    /// 서비스 하나를 푸는 데 기다리는 최대 시간
    var resolveTimeout: Duration = .seconds(4)

    func discover(types: [String]) -> AsyncStream<BonjourService> {
        AsyncStream { continuation in
            let session = BrowseSession(types: types, resolveTimeout: resolveTimeout, continuation: continuation)
            continuation.onTermination = { _ in session.stop() }
            session.start()
        }
    }
}

/// 검색 한 번. 모든 상태는 `queue`에서만 만진다(핸들러·타이머·멈춤 모두 이 큐로 온다).
private final class BrowseSession: @unchecked Sendable {
    private let types: [String]
    private let resolveTimeout: Duration
    private let continuation: AsyncStream<BonjourService>.Continuation
    private let queue = DispatchQueue(label: "nagonet.bonjour")

    private var browsers: [NWBrowser] = []
    private var resolving: [String: NWConnection] = [:]
    private var resolved: Set<String> = []
    private var isStopped = false

    init(types: [String], resolveTimeout: Duration, continuation: AsyncStream<BonjourService>.Continuation) {
        self.types = types
        self.resolveTimeout = resolveTimeout
        self.continuation = continuation
    }

    func start() {
        queue.async { [self] in
            for type in types {
                let parameters = NWParameters()
                parameters.requiredInterfaceType = .wifi
                parameters.includePeerToPeer = false
                let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: "local."), using: parameters)
                browser.browseResultsChangedHandler = { [self] _, changes in
                    for change in changes {
                        switch change {
                        case .added(let result), .changed(old: _, new: let result, flags: _):
                            resolve(result)
                        default:
                            break
                        }
                    }
                }
                browser.start(queue: queue)
                browsers.append(browser)
            }
        }
    }

    func stop() {
        queue.async { [self] in
            isStopped = true
            browsers.forEach { $0.cancel() }
            browsers.removeAll()
            resolving.values.forEach { $0.cancel() }
            resolving.removeAll()
        }
    }

    private func resolve(_ result: NWBrowser.Result) {
        guard !isStopped, case .service(let name, let type, _, _) = result.endpoint else { return }
        let key = "\(type)|\(name)"
        guard !resolved.contains(key), resolving[key] == nil else { return }

        let txt: [String: String]
        if case .bonjour(let record) = result.metadata {
            // 키는 대소문자를 가리지 않으므로 소문자로 맞춘다(rpMd → rpmd)
            txt = Dictionary(record.dictionary.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        } else {
            txt = [:]
        }
        let connection = NWConnection(to: result.endpoint, using: Self.resolveParameters())
        resolving[key] = connection
        // 주소가 풀리는 즉시 경로에 나타난다. 서비스 포트가 방화벽에 막혀 연결이 끝나지 않아도 주소는 얻는다
        let resolved: @Sendable (NWPath?) -> Void = { [self] path in
            if case .hostPort(let host, let port)? = path?.remoteEndpoint, case .ipv4(let address) = host {
                finish(key, with: BonjourService(name: name, type: type, address: Self.ipv4(address), port: port.rawValue, txt: txt))
            }
        }
        connection.pathUpdateHandler = { path in resolved(path) }
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready, .waiting, .failed:
                resolved(connection.currentPath)
                if case .ready = state { finish(key, with: nil) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + resolveTimeout.milliseconds / 1_000) { [self] in
            resolved(connection.currentPath)
            finish(key, with: nil)
        }
    }

    private func finish(_ key: String, with service: BonjourService?) {
        guard let connection = resolving.removeValue(forKey: key) else { return }
        connection.cancel()
        guard let service, !isStopped else { return }
        resolved.insert(key)
        continuation.yield(service)
    }

    /// IPv4로만 풀고, VPN이 켜져 있어도 Wi-Fi로.
    private static func resolveParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi
        parameters.includePeerToPeer = false
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        return parameters
    }

    private static func ipv4(_ address: IPv4Address) -> IPv4 {
        let bytes = [UInt8](address.rawValue)
        return IPv4(bytes[0], bytes[1], bytes[2], bytes[3])
    }
}
