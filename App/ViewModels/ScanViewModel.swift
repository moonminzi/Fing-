import Foundation
import NagoNetCore
import Observation

/// 스캔 버튼·진행률·기기 목록.
///
/// 스캔 한 번 = TCP 탐색(ScannerService) + Bonjour 검색 + 역방향 DNS를 함께 돌려 주소별로 합친다.
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

    /// TCP 탐색이 끝난 뒤 늦게 오는 Bonjour 답을 더 기다리는 시간
    static let bonjourGrace: Duration = .seconds(2)
    /// 역방향 DNS 동시 조회 수
    static let maxConcurrentLookups = 8

    private(set) var status: Status = .idle
    private(set) var devices: [IPv4: Device] = [:]
    /// TCP 탐색 진행률 0…1
    private(set) var progress: Double = 0
    /// TCP 탐색은 끝났고 이름(Bonjour·DNS)을 마저 찾는 중
    private(set) var isNaming = false
    var sortOrder: DeviceSort = .address

    @ObservationIgnored private let scanner: any NetworkScanning
    @ObservationIgnored private let bonjour: any BonjourBrowsing
    @ObservationIgnored private let hostNames: any HostNameResolving
    @ObservationIgnored private let access: any LocalNetworkAccessChecking
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scannedSubnet: Subnet?
    /// 새 주소가 목록에 들어올 때마다 역방향 DNS 조회로 넘긴다
    @ObservationIgnored private var lookupQueue: AsyncStream<IPv4>.Continuation?

    init(
        scanner: any NetworkScanning = ScannerService(prober: TCPProber()),
        bonjour: any BonjourBrowsing = BonjourBrowser(),
        hostNames: any HostNameResolving = ReverseDNSResolver(),
        access: any LocalNetworkAccessChecking = LocalNetworkAccess()
    ) {
        self.scanner = scanner
        self.bonjour = bonjour
        self.hostNames = hostNames
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

                // 2. 탐색. 도중에 권한이 꺼지면 1로 돌아가 다시 허용되기를 기다린다
                status = .scanning
                let denied = await discover(on: network)
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
        isNaming = false
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

    /// TCP 탐색·Bonjour·역방향 DNS를 함께 돌린다. 로컬 네트워크 권한이 막혀 멈췄으면 true.
    private func discover(on network: NetworkSnapshot) async -> Bool {
        progress = 0
        isNaming = false
        defer { isNaming = false }

        let (lookups, lookupQueue) = AsyncStream.makeStream(of: IPv4.self)
        self.lookupQueue = lookupQueue
        // 이미 목록에 있는데 이름이 없는 기기(다시 스캔)도 조회
        for device in devices.values where device.hostName == nil && !device.isSelf {
            lookupQueue.yield(device.address)
        }

        var denied = false
        await withTaskGroup(of: Void.self) { names in
            names.addTask { await self.resolveHostNames(lookups) }

            await withTaskGroup(of: Void.self) { browsing in
                browsing.addTask { await self.browseBonjour(on: network) }

                for await event in scanner.scan(network.scanTargets) {
                    switch event {
                    case .progress(let completed, let total):
                        progress = total > 0 ? Double(completed) / Double(total) : 1
                    case .host(let host):
                        upsert(host.address, network: network) { $0.merge(host) }
                    case .localNetworkDenied:
                        denied = true
                        status = .accessDenied
                    }
                }
                if !denied {
                    isNaming = true
                    try? await Task.sleep(for: Self.bonjourGrace)
                }
                browsing.cancelAll()
            }
            // 새 주소가 더 안 들어오니 남은 DNS 조회만 끝내면 된다
            lookupQueue.finish()
            self.lookupQueue = nil
        }
        return denied
    }

    private func browseBonjour(on network: NetworkSnapshot) async {
        for await service in bonjour.discover(types: BonjourCatalog.serviceTypes) {
            // VPN 등 다른 대역으로 풀린 주소는 버린다
            guard network.subnet.contains(service.address) else { continue }
            upsert(service.address, network: network) { $0.merge(service) }
        }
    }

    private func resolveHostNames(_ addresses: AsyncStream<IPv4>) async {
        let hostNames = self.hostNames
        await withTaskGroup(of: (IPv4, String?).self) { group in
            var running = 0
            for await address in addresses {
                if running >= Self.maxConcurrentLookups, case let (done, name)? = await group.next() {
                    apply(hostName: name, to: done)
                    running -= 1
                }
                group.addTask { (address, await hostNames.hostName(for: address)) }
                running += 1
            }
            for await (done, name) in group {
                apply(hostName: name, to: done)
            }
        }
    }

    private func apply(hostName: String?, to address: IPv4) {
        guard let hostName else { return }
        devices[address]?.hostName = hostName
    }

    /// 주소의 기기를 고치고, 처음 보는 주소면 새로 넣으며 DNS 조회를 건다.
    private func upsert(_ address: IPv4, network: NetworkSnapshot, _ change: (inout Device) -> Void) {
        if var device = devices[address] {
            change(&device)
            devices[address] = device
            return
        }
        var device = Device(address: address, isGateway: address == network.gateway.address)
        change(&device)
        devices[address] = device
        lookupQueue?.yield(address)
    }
}
