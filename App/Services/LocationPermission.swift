import CoreLocation
import Observation

/// iOS는 연결된 Wi-Fi 이름(SSID)을 알려 줄 때 "정확한 위치" 권한을 요구한다. 그 권한 상태를 들고 요청한다.
/// 위치 자체는 읽지 않는다.
@MainActor @Observable
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    enum State: Equatable, Sendable {
        case notDetermined
        case denied
        /// 대략적인 위치만 허용(SSID를 못 읽음)
        case approximate
        case precise
    }

    private(set) var state: State = .notDetermined

    @ObservationIgnored private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        state = Self.state(of: manager)
    }

    /// 지금 상태에서 필요한 권한을 요청한다. 거부된 상태면 설정 앱에서 바꿔야 해서 아무것도 안 한다.
    func request() {
        switch state {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .approximate:
            // Info.plist의 NSLocationTemporaryUsageDescriptionDictionary 키
            manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "WiFiName")
        case .denied, .precise:
            break
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let state = Self.state(of: manager)
        Task { @MainActor in self.state = state }
    }

    private nonisolated static func state(of manager: CLLocationManager) -> State {
        switch manager.authorizationStatus {
        case .notDetermined:
            .notDetermined
        case .authorizedAlways, .authorizedWhenInUse:
            manager.accuracyAuthorization == .fullAccuracy ? .precise : .approximate
        default:
            .denied
        }
    }
}
