import BackgroundTasks
import Foundation
import NagoNetCore
import SwiftData
import UserNotifications

/// 앱이 꺼져 있을 때 가끔(iOS가 정한 때, 몇 시간 간격일 수도) 새 기기를 확인해 알린다.
///
/// iOS는 백그라운드에서 계속 스캔하게 두지 않는다. `BGAppRefreshTask`는 30초 안팎만 주므로 전체 스캔 대신
/// 포트 하나로 빠르게 훑고, 기록에 없는 주소만 이름을 물어 다시 확인한 뒤, 처음 보는 기기를 알림으로 알린다.
/// 한 번 알린 기기는 다음 앱 스캔이 기록될 때까지 다시 알리지 않는다.
enum BackgroundCheck {
    /// Info.plist의 BGTaskSchedulerPermittedIdentifiers와 같아야 한다
    static let taskIdentifier = "com.nagonet.refresh"
    private static let notifiedKey = "nagonet.background.notified"

    /// 다음 확인을 예약한다(설정에서 켰을 때만). 앱이 백그라운드로 갈 때와 확인할 때마다 부른다.
    static func schedule() {
        guard AppSettings.backgroundCheckEnabled else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("백그라운드 확인 예약 실패: \(error)")
        }
    }

    /// 알림 권한을 묻는다(설정에서 켤 때). 허용하면 true
    static func requestNotificationPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// 앱에서 스캔을 기록했으면 그 기기들은 이제 아는 기기라 알림 목록을 비운다.
    static func clearNotified() {
        UserDefaults.standard.removeObject(forKey: notifiedKey)
    }

    /// iOS가 깨웠을 때 할 일.
    static func run(container: ModelContainer) async {
        guard AppSettings.backgroundCheckEnabled else { return }
        schedule()
        guard let network = try? await SystemNetworkInfo().currentNetwork(interfaceName: "en0") else { return }
        let baseline = await MainActor.run { HistoryStore(context: container.mainContext).baseline(for: network) }
        guard baseline.previousScans > 0 else { return }

        // 1. 포트 하나(80)로 빠르게 훑기: /24는 몇 초
        let scanner = ScannerService(
            prober: TCPProber(),
            configuration: ScanConfiguration(ports: [80], maxConcurrentConnections: 64, timeout: .milliseconds(700))
        )
        var candidates: [IPv4] = []
        for await event in scanner.scan(network.scanTargets) {
            guard case .host(let host) = event else { continue }
            // IP만으로도 아는 기기면 넘어간다
            let device = Device(address: host.address, responseTime: host.responseTime, isGateway: host.address == network.gateway.address)
            if baseline.isNew(device) { candidates.append(host.address) }
        }
        guard !Task.isCancelled, !candidates.isEmpty else { return }

        // 2. 처음 보는 주소만 이름을 물어(IP가 바뀐 아는 기기를 걸러 낸다) 다시 확인
        let naming = NameResolver(dns: ReverseDNSResolver(timeout: .seconds(1)), transport: UDPExchange(),
                                  timeout: .milliseconds(800))
        let newDevices = await withTaskGroup(of: Device?.self) { group in
            for address in candidates.prefix(16) {
                group.addTask {
                    var device = Device(address: address, responseTime: .zero)
                    device.merge(await naming.names(for: address))
                    return baseline.isNew(device) ? device : nil
                }
            }
            var found: [Device] = []
            for await device in group {
                if let device { found.append(device) }
            }
            return found.sorted { $0.address < $1.address }
        }
        guard !Task.isCancelled else { return }

        // 3. 아직 알리지 않은 기기만 알림
        let networkKey = network.subnet.cidr
        var notified = Set(UserDefaults.standard.stringArray(forKey: notifiedKey) ?? [])
        let fresh = newDevices.filter { !notified.contains($0.identity.keys(network: networkKey)[0]) }
        guard !fresh.isEmpty else { return }
        fresh.forEach { notified.insert($0.identity.keys(network: networkKey)[0]) }
        UserDefaults.standard.set(Array(notified), forKey: notifiedKey)
        await post(fresh, networkName: network.ssid ?? network.subnet.cidr)
    }

    private static func post(_ devices: [Device], networkName: String) async {
        let content = UNMutableNotificationContent()
        content.title = "새 기기 \(devices.count)대가 \(networkName)에 들어왔어요"
        let names = devices.prefix(3).map { $0.name ?? $0.address.description }
        content.body = names.joined(separator: ", ") + (devices.count > 3 ? " 외 \(devices.count - 3)대" : "")
            + " · 앱을 열어 스캔하면 자세히 볼 수 있어요."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "nagonet.new.\(Date.now.timeIntervalSince1970)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
