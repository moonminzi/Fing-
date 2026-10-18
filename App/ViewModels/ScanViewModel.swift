import Foundation
import NagoNetCore
import Observation

/// 스캔 버튼·진행률·기기 목록, 기기별 포트 스캔과 별명.
///
/// 스캔 한 번 = TCP 탐색(ScannerService) + Bonjour 검색 + 기기별 이름 조회(역방향 DNS·mDNS 유니캐스트·NetBIOS)를
/// 함께 돌려 주소별로 합치고, 끝으로 웹·SSH 포트가 열린 기기의 배너를 읽는다.
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
    /// 이름 조회·배너 읽기를 동시에 돌리는 기기 수
    static let maxConcurrentLookups = 8

    /// 상세 화면의 포트 스캔 상태
    struct PortScanState: Equatable {
        var progress: Double = 0
        var isRunning = true
        /// 지금까지 찾은 열린 포트
        var found: [UInt16] = []
        var isDenied = false
    }

    private(set) var status: Status = .idle
    private(set) var devices: [IPv4: Device] = [:]
    /// TCP 탐색 진행률 0…1
    private(set) var progress: Double = 0
    /// TCP 탐색은 끝났고 이름(Bonjour·DNS)을 마저 찾는 중
    private(set) var isNaming = false
    var sortOrder: DeviceSort = .address
    private(set) var portScans: [IPv4: PortScanState] = [:]

    @ObservationIgnored private let scanner: any NetworkScanning
    @ObservationIgnored private let bonjour: any BonjourBrowsing
    @ObservationIgnored private let naming: any DeviceNaming
    @ObservationIgnored private let bannerGrabber: any BannerGrabbing
    @ObservationIgnored private let portScanner: any PortScanning
    @ObservationIgnored private let aliases: any AliasStoring
    @ObservationIgnored private let access: any LocalNetworkAccessChecking
    @ObservationIgnored private var portScanTasks: [IPv4: Task<Void, Never>] = [:]
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scannedSubnet: Subnet?
    /// 새 주소가 목록에 들어올 때마다 이름 조회로 넘긴다
    @ObservationIgnored private var lookupQueue: AsyncStream<IPv4>.Continuation?

    init(
        scanner: any NetworkScanning = ScannerService(prober: TCPProber()),
        bonjour: any BonjourBrowsing = BonjourBrowser(),
        naming: any DeviceNaming = NameResolver(dns: ReverseDNSResolver(timeout: .seconds(2)), transport: UDPExchange()),
        bannerGrabber: any BannerGrabbing = BannerGrabber(),
        portScanner: any PortScanning = PortScanner(prober: TCPProber()),
        aliases: any AliasStoring = AliasStore(),
        access: any LocalNetworkAccessChecking = LocalNetworkAccess()
    ) {
        self.scanner = scanner
        self.bonjour = bonjour
        self.naming = naming
        self.bannerGrabber = bannerGrabber
        self.portScanner = portScanner
        self.aliases = aliases
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
            if devices[network.myAddress] == nil {
                upsert(network.myAddress, network: network) { $0.isSelf = true }
            }
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
        stopEverything()
        devices = [:]
        portScans = [:]
        progress = 0
        status = .idle
        scannedSubnet = nil
    }

    /// 스캔과 포트 스캔을 모두 멈춘다(앱이 백그라운드로 갈 때).
    func stopEverything() {
        cancel()
        for address in Array(portScanTasks.keys) {
            cancelPortScan(of: address)
        }
    }

    // MARK: 별명

    /// 별명을 붙인다. 빈 글이나 nil이면 지운다. 다음 스캔에서도 같은 기기에 붙는다.
    func setAlias(_ text: String?, for address: IPv4) {
        guard let device = devices[address] else { return }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let alias = trimmed?.isEmpty == false ? trimmed : nil
        aliases.setAlias(alias, forKeys: device.identity.keys(network: networkKey))
        devices[address]?.alias = alias
    }

    private var networkKey: String { scannedSubnet?.cidr ?? "" }

    private func refreshAlias(of address: IPv4) {
        guard let device = devices[address] else { return }
        let alias = aliases.alias(forKeys: device.identity.keys(network: networkKey))
        if device.alias != alias {
            devices[address]?.alias = alias
        }
    }

    // MARK: 포트 스캔

    /// 주요 포트 100개를 두드린다. 끝나면 새로 찾은 웹·SSH 포트의 배너도 읽는다.
    func scanPorts(of address: IPv4) {
        portScanTasks[address]?.cancel()
        portScans[address] = PortScanState()
        portScanTasks[address] = Task {
            var found: [UInt16] = []
            for await event in portScanner.scan(address, ports: KnownPorts.commonPorts) {
                switch event {
                case .progress(let completed, let total):
                    portScans[address]?.progress = Double(completed) / Double(max(total, 1))
                case .open(let port):
                    found.append(port)
                    portScans[address]?.found = found.sorted()
                case .localNetworkDenied:
                    portScans[address]?.isDenied = true
                }
            }
            guard !Task.isCancelled else { return }
            portScans[address]?.isRunning = false
            if portScans[address]?.isDenied != true {
                devices[address]?.scannedPorts = found.sorted()
                if let device = devices[address] {
                    await readBanners(of: [device])
                }
            }
            portScanTasks[address] = nil
        }
    }

    func cancelPortScan(of address: IPv4) {
        portScanTasks[address]?.cancel()
        portScanTasks[address] = nil
        portScans[address]?.isRunning = false
    }

    /// TCP 탐색·Bonjour·이름 조회를 함께 돌린다. 로컬 네트워크 권한이 막혀 멈췄으면 true.
    private func discover(on network: NetworkSnapshot) async -> Bool {
        progress = 0
        isNaming = false
        defer { isNaming = false }

        let (lookups, lookupQueue) = AsyncStream.makeStream(of: IPv4.self)
        self.lookupQueue = lookupQueue
        // 이미 목록에 있는데 이름이 없는 기기(다시 스캔)도 조회
        for device in devices.values where device.needsNames {
            lookupQueue.yield(device.address)
        }

        var denied = false
        await withTaskGroup(of: Void.self) { names in
            names.addTask { await self.resolveNames(lookups) }

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
            // 웹·SSH 포트가 열린 기기의 배너(이름 없는 공유기·AP·프린터·NAS의 단서)
            if !denied, !Task.isCancelled {
                await readBanners(of: devices.values.filter { !$0.isSelf && $0.banners.isEmpty })
            }
            // 새 주소가 더 안 들어오니 남은 이름 조회만 끝내면 된다
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

    private func resolveNames(_ addresses: AsyncStream<IPv4>) async {
        let naming = self.naming
        await withTaskGroup(of: (IPv4, DeviceNames).self) { group in
            var running = 0
            for await address in addresses {
                if running >= Self.maxConcurrentLookups, case let (done, names)? = await group.next() {
                    devices[done]?.merge(names)
                    refreshAlias(of: done)
                    running -= 1
                }
                group.addTask { (address, await naming.names(for: address)) }
                running += 1
            }
            for await (done, names) in group {
                devices[done]?.merge(names)
                refreshAlias(of: done)
            }
        }
    }

    /// 기기들의 웹·SSH 포트에서 배너를 읽어 합친다(기기 8대씩, 기기 안의 포트는 한꺼번에).
    private func readBanners(of targets: [Device]) async {
        let grabber = bannerGrabber
        let jobs = targets.map { ($0.address, BannerPorts.worthReading(among: $0.allOpenPorts)) }.filter { !$0.1.isEmpty }
        await withTaskGroup(of: (IPv4, [ServiceBanner]).self) { group in
            var next = 0
            func addNext() {
                let (address, ports) = jobs[next]
                next += 1
                group.addTask {
                    await withTaskGroup(of: ServiceBanner?.self) { reads in
                        for port in ports {
                            reads.addTask { await grabber.banner(of: address, port: port) }
                        }
                        var banners: [ServiceBanner] = []
                        for await banner in reads {
                            if let banner { banners.append(banner) }
                        }
                        return (address, banners)
                    }
                }
            }
            while next < min(Self.maxConcurrentLookups, jobs.count) { addNext() }
            while let (address, banners) = await group.next() {
                for banner in banners {
                    devices[address]?.merge(banner)
                }
                refreshAlias(of: address)
                if next < jobs.count, !Task.isCancelled { addNext() }
            }
        }
    }

    /// 주소의 기기를 고치고, 처음 보는 주소면 새로 넣으며 DNS 조회를 건다.
    private func upsert(_ address: IPv4, network: NetworkSnapshot, _ change: (inout Device) -> Void) {
        if var device = devices[address] {
            change(&device)
            devices[address] = device
            refreshAlias(of: address)
            return
        }
        var device = Device(address: address, isGateway: address == network.gateway.address)
        change(&device)
        devices[address] = device
        refreshAlias(of: address)
        if !device.isSelf {
            lookupQueue?.yield(address)
        }
    }
}
