import Foundation
import Network
import Observation

/// (인가된 자기 네트워크·CTF 전용) 가짜 Bonjour 서비스를 광고해 다른 기기를 유인하고, 접속해 온 클라이언트 IP를 기록한다.
///
/// `NWListener`로 Bonjour 서비스를 publish 하는 건 **로컬 네트워크 권한만으로 iOS에서 실제로 동작**하고,
/// 멀티캐스트 entitlement가 필요 없다(ARP·NDP 스푸핑 송신이나 멀티캐스트 발견이 막히는 것과 대조). 가짜
/// AirPlay·프린터·캐스트·관리페이지 같은 서비스를 띄워 다른 기기 목록에 뜨게 하고(유인), 접속한 기기의
/// 주소를 기록한다(허니팟). **접속 사실만** 본다 — 가짜 로그인 폼 등 자격증명 수집은 하지 않는다.
@MainActor @Observable
final class BonjourAdvertiser {
    enum State: Equatable {
        case idle
        case advertising(name: String, type: String)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// 접속해 온 클라이언트(최근 것부터)
    private(set) var hits: [String] = []

    @ObservationIgnored private var listener: NWListener?

    /// 광고할 수 있는 서비스 종류(Info.plist의 NSBonjourServices에 선언된 표준 타입만 노출).
    static let advertisableTypes: [(label: String, type: String)] = [
        ("AirPlay 화면 (_airplay._tcp)", "_airplay._tcp"),
        ("AirPlay 오디오 (_raop._tcp)", "_raop._tcp"),
        ("Chromecast (_googlecast._tcp)", "_googlecast._tcp"),
        ("웹·관리페이지 (_http._tcp)", "_http._tcp"),
        ("프린터 (_ipp._tcp)", "_ipp._tcp"),
        ("파일 공유 (_smb._tcp)", "_smb._tcp"),
        ("SSH (_ssh._tcp)", "_ssh._tcp"),
    ]

    /// 가짜 서비스 광고를 시작한다(임의 TCP 포트에 리스너를 열고 Bonjour로 이름·종류를 알린다).
    func start(name: String, type: String) {
        stop()
        hits = []
        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .wifi
            let listener = try NWListener(using: parameters)   // 임의(ephemeral) 포트
            listener.service = NWListener.Service(name: name, type: type)
            listener.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor in
                    switch newState {
                    case .ready: self?.state = .advertising(name: name, type: type)
                    case .failed(let error): self?.state = .failed(error.localizedDescription)
                    case .cancelled: break
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                let who = Self.describe(connection.endpoint)
                connection.cancel()   // 접속 사실만 기록하고 아무것도 주지 않는다(피싱 금지)
                Task { @MainActor in self?.record(who) }
            }
            listener.start(queue: .global(qos: .utility))
            self.listener = listener
            self.state = .advertising(name: name, type: type)   // ready 콜백 전 임시 표시
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        state = .idle
    }

    private func record(_ who: String) {
        hits.insert(who, at: 0)
        if hits.count > 50 { hits.removeLast(hits.count - 50) }
    }

    nonisolated private static func describe(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, let port): return "\(host):\(port)"
        default: return "\(endpoint)"
        }
    }
}
