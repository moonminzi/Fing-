import NagoNetCore
import Observation

/// 메인 화면 위쪽 카드: 지금 붙어 있는 Wi-Fi의 이름·내 IP·게이트웨이·스캔 대역.
@MainActor @Observable
final class NetworkViewModel {
    enum Phase: Equatable {
        case loading
        case connected(NetworkSnapshot)
        case notConnected
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var isRefreshing = false

    @ObservationIgnored private let info: any NetworkInfoProviding
    @ObservationIgnored private let pathMonitor = WiFiPathMonitor()
    @ObservationIgnored private var wifiInterface = "en0"
    @ObservationIgnored private var isMonitoring = false

    init(info: any NetworkInfoProviding = SystemNetworkInfo()) {
        self.info = info
    }

    /// Wi-Fi 경로를 지켜보며 켜기·끄기·공유기 바뀜마다 다시 읽는다. 여러 번 불러도 한 번만 시작한다.
    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        pathMonitor.start { [weak self] status in
            guard let self else { return }
            wifiInterface = status.interfaceName ?? "en0"
            Task { await self.refresh() }
        }
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let snapshot = try await info.currentNetwork(interfaceName: wifiInterface)
            phase = .connected(snapshot)
        } catch NetworkInfoError.notConnected {
            phase = .notConnected
        } catch NetworkInfoError.invalidNetmask(let mask) {
            phase = .failed("서브넷 마스크(\(mask))가 올바르지 않아요.")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
