import Foundation
import NagoNetCore
import Observation

/// 스캔 버튼·진행률·기기 목록.
@MainActor @Observable
final class ScanViewModel {
    enum Status: Equatable {
        case idle
        /// 로컬 네트워크 권한 확인 중(처음이면 iOS 허용 창이 떠 있다)
        case checkingAccess
        /// 로컬 네트워크 권한이 없다. 설정에서 허용하면 자동으로 이어서 스캔한다
        case accessDenied
        case scanning
        case finished(at: Date, duration: Duration)
        case cancelled
    }

    private(set) var status: Status = .idle
    private(set) var devices: [IPv4: Device] = [:]
    /// 0…1
    private(set) var progress: Double = 0
    var sortOrder: DeviceSort = .address

    @ObservationIgnored private let scanner: any NetworkScanning
    @ObservationIgnored private let access: any LocalNetworkAccessChecking
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scannedSubnet: Subnet?

    init(
        scanner: any NetworkScanning = ScannerService(prober: TCPProber()),
        access: any LocalNetworkAccessChecking = LocalNetworkAccess()
    ) {
        self.scanner = scanner
        self.access = access
    }

    var isRunning: Bool {
        switch status {
        case .checkingAccess, .accessDenied, .scanning: true
        case .idle, .finished, .cancelled: false
        }
    }

    var sortedDevices: [Device] {
        devices.values.sorted(by: sortOrder)
    }

    func start(on network: NetworkSnapshot) {
        scanTask?.cancel()
        if scannedSubnet != network.subnet {
            devices = [:]
        }
        scannedSubnet = network.subnet
        progress = 0
        status = .checkingAccess

        scanTask = Task {
            let started = ContinuousClock.now
            devices[network.myAddress] = Device(address: network.myAddress, isSelf: true)
            while !Task.isCancelled {
                // 1. 로컬 네트워크 권한(처음이면 여기서 iOS가 묻는다). 허용될 때까지 기다린다
                for await signal in access.signals(probing: network.gateway.address) {
                    status = signal == .denied ? .accessDenied : .scanning
                }
                guard !Task.isCancelled else { return }

                // 2. TCP 탐색. 도중에 권한이 꺼지면 1로 돌아가 다시 허용되기를 기다린다
                status = .scanning
                progress = 0
                var denied = false
                for await event in scanner.scan(network.scanTargets) {
                    if event == .localNetworkDenied { denied = true }
                    apply(event, gateway: network.gateway.address)
                }
                if !denied { break }
            }
            guard !Task.isCancelled else { return }
            status = .finished(at: .now, duration: started.duration(to: .now))
        }
    }

    func cancel() {
        guard isRunning else { return }
        scanTask?.cancel()
        scanTask = nil
        status = .cancelled
    }

    /// 다른 네트워크로 옮겨 가면 이전 결과는 지운다.
    func networkChanged(to network: NetworkSnapshot?) {
        guard network?.subnet != scannedSubnet else { return }
        cancel()
        devices = [:]
        progress = 0
        status = .idle
        scannedSubnet = nil
    }

    private func apply(_ event: ScanEvent, gateway: IPv4) {
        switch event {
        case .progress(let completed, let total):
            progress = total > 0 ? Double(completed) / Double(total) : 1
        case .host(let host):
            var device = devices[host.address] ?? Device(address: host.address, isGateway: host.address == gateway)
            device.merge(host)
            devices[host.address] = device
        case .localNetworkDenied:
            status = .accessDenied
        }
    }
}
