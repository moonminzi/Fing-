import Foundation
import NagoNetCore
import Observation
import UIKit

/// 스캔 버튼·진행률·기기 목록, 기기별 포트 스캔과 별명, 스캔 기록과 "새 기기".
///
/// 스캔 한 번 = TCP 탐색(ScannerService) + Bonjour 검색 + 기기별 이름 조회(역방향 DNS·mDNS 유니캐스트·NetBIOS)를
/// 함께 돌려 주소별로 합치고, 끝으로 웹·SSH 포트가 열린 기기의 배너를 읽는다. 끝까지 마치면 기록에 남긴다.
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
    /// MAC을 직접 묻는 기기 수(답 없는 기기는 시간 초과까지 기다려서 더 많이 돌린다)
    static let maxConcurrentProbes = 16

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
    /// 스캔을 시작할 때 꺼내 둔 이 네트워크의 기록. "새 기기"는 여기에 없는 기기
    private(set) var baseline: NetworkBaseline = .empty
    /// 공유기 ARP 표(SNMP)를 읽은 결과 한 줄
    private(set) var routerTableStatus: String?
    /// 이 기기 ARP 캐시 진단 한 줄(iOS가 다른 기기 MAC을 흘리는지/가리는지). 공유기·비번 없이 측정
    private(set) var localARPStatus: String?
    /// DHCP 스니핑(실험) 결과 한 줄(공유기 없이 기기 MAC을 직접 잡았는지)
    private(set) var dhcpStatus: String?
    /// IPv6 이웃 탐색(NDP, 실험) 결과 한 줄
    private(set) var neighborStatus: String?

    /// 네트워크마다 스캐너를 만든다(핑을 그 Wi-Fi 인터페이스로 묶으려고)
    @ObservationIgnored private let makeScanner: (NetworkSnapshot) -> any NetworkScanning
    @ObservationIgnored private let bonjour: any BonjourBrowsing
    @ObservationIgnored private let naming: any DeviceNaming
    @ObservationIgnored private let arpReader: ARPTableReader
    @ObservationIgnored private let arpCache: any ARPCacheReading
    @ObservationIgnored private let macProber: any MACProbing
    @ObservationIgnored private let dhcpSniffer: any DHCPSniffing
    @ObservationIgnored private let vendorLookup: (MACAddress) -> String?
    @ObservationIgnored private let wakeSender = MagicPacketSender()
    /// 앱이 백그라운드로 간 뒤 진행 중인 스캔을 마무리하는 시간(약 30초)
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private let bannerGrabber: any BannerGrabbing
    @ObservationIgnored private let portScanner: any PortScanning
    @ObservationIgnored private let history: any ScanHistoryStoring
    /// 4단계에서 UserDefaults에 붙인 별명(읽기만, 다음 기록 때 SwiftData로 옮겨진다)
    @ObservationIgnored private let legacyAliases: any AliasStoring
    /// 이름으로 MAC을 기억해 둔다(DHCP가 기회성이라 Apple 기기 등은 한 번 잡으면 다음 스캔에도 되살린다)
    @ObservationIgnored private let macMemory: any MACMemoryStoring
    /// IPv6 이웃 탐색(NDP)으로 찔러 MAC을 거둔다(실험)
    @ObservationIgnored private let neighborProber: any NeighborProbing
    @ObservationIgnored private let access: any LocalNetworkAccessChecking
    /// 이번 스캔 중에 고친 별명(기록에는 바로 저장되지만 baseline은 스캔 시작 때 것이라 따로 든다)
    @ObservationIgnored private var aliasEdits: [IPv4: String?] = [:]
    @ObservationIgnored private var scannedNetwork: NetworkSnapshot?
    @ObservationIgnored private var portScanTasks: [IPv4: Task<Void, Never>] = [:]
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// DHCP 스니핑 리스너. 앱이 떠 있는 동안 계속 돌고(백그라운드 가면 멈춤), 잡을 때마다 상태를 갱신한다
    @ObservationIgnored private var dhcpTask: Task<Void, Never>?
    /// "MAC 집중 수집": 전체 재스캔 없이 no-login 수집기를 한 번에 다시 돌리는 작업
    @ObservationIgnored private var collectTask: Task<Void, Never>?
    /// 집중 수집이 도는 중인지(버튼 진행 표시)
    private(set) var isCollectingMACs = false
    @ObservationIgnored private var scannedSubnet: Subnet?
    /// 새 주소가 목록에 들어올 때마다 이름 조회로 넘긴다
    @ObservationIgnored private var lookupQueue: AsyncStream<IPv4>.Continuation?

    init(
        makeScanner: @escaping (NetworkSnapshot) -> any NetworkScanning = {
            ScannerService(prober: TCPProber(), pinger: ICMPPinger(interfaceName: $0.interfaceName))
        },
        bonjour: any BonjourBrowsing = BonjourBrowser(),
        naming: any DeviceNaming = NameResolver(dns: ReverseDNSResolver(timeout: .seconds(2)), transport: UDPExchange(),
                                                http: HTTPFetcher()),
        arpReader: ARPTableReader = ARPTableReader(transport: UDPExchange()),
        arpCache: any ARPCacheReading = SystemARPCache(),
        macProber: any MACProbing = MACProber(transport: UDPExchange(), http: HTTPFetcher(timeout: .milliseconds(1500))),
        dhcpSniffer: any DHCPSniffing = DHCPSniffer(),
        vendorLookup: @escaping (MACAddress) -> String? = VendorLookup.vendor(for:),
        bannerGrabber: any BannerGrabbing = BannerGrabber(),
        portScanner: any PortScanning = PortScanner(prober: TCPProber()),
        history: any ScanHistoryStoring,
        legacyAliases: any AliasStoring = AliasStore(),
        macMemory: any MACMemoryStoring = MACMemoryStore(),
        neighborProber: any NeighborProbing = NeighborProber(),
        access: any LocalNetworkAccessChecking = LocalNetworkAccess()
    ) {
        self.makeScanner = makeScanner
        self.bonjour = bonjour
        self.naming = naming
        self.arpReader = arpReader
        self.arpCache = arpCache
        self.macProber = macProber
        self.dhcpSniffer = dhcpSniffer
        self.vendorLookup = vendorLookup
        self.bannerGrabber = bannerGrabber
        self.portScanner = portScanner
        self.history = history
        self.legacyAliases = legacyAliases
        self.macMemory = macMemory
        self.neighborProber = neighborProber
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

    /// 이전 스캔들에서 본 적 없는 기기인지(이 네트워크의 첫 스캔이면 모두 false)
    func isNew(_ device: Device) -> Bool {
        baseline.isNew(device)
    }

    var newDeviceCount: Int {
        devices.values.filter(baseline.isNew).count
    }

    var newAddresses: Set<IPv4> {
        Set(devices.values.filter(baseline.isNew).map(\.address))
    }

    /// 상세 화면의 핑 도구용(Wi-Fi 인터페이스로 묶는다)
    var pinger: any Pinging {
        ICMPPinger(interfaceName: scannedNetwork?.interfaceName)
    }

    /// 기기를 깨운다(Wake-on-LAN 매직 패킷). MAC을 모르면 보내지 않고 false.
    /// 보냈으면 true(기기가 실제로 켜졌는지는 알 수 없다).
    func wake(_ device: Device) async -> Bool {
        guard let mac = device.mac?.address else { return false }
        return await wakeSender.wake(mac: mac, lastKnownIP: device.address, broadcast: scannedNetwork?.subnet.broadcast)
    }

    /// 지금 목록을 CSV로 내보내기. 기기가 없으면 nil
    var export: ScanExport? {
        guard !devices.isEmpty else { return nil }
        let csv = DeviceCSV.make(Array(devices.values), isNew: baseline.isNew)
        return ScanExport(csv: csv, networkName: scannedNetwork?.ssid ?? scannedSubnet?.cidr ?? "network", date: .now)
    }

    /// MAC을 아는 기기 수 / 나를 뺀 기기 수
    var macCoverage: (known: Int, total: Int) {
        let others = devices.values.filter { !$0.isSelf }
        return (others.filter { $0.mac != nil }.count, others.count)
    }

    /// 아직 MAC을 못 잡은 기기(이 기기 제외). 재연결로 DHCP에 잡을 대상을 안내하는 데 쓴다
    var devicesMissingMAC: [Device] {
        devices.values.filter { !$0.isSelf && $0.mac == nil }.sorted(by: sortOrder)
    }

    /// 이 네트워크를 처음 스캔하는 중(그래서 "새 기기"를 표시하지 않는다)
    var isFirstScanOfNetwork: Bool {
        scannedNetwork != nil && baseline.previousScans == 0
    }

    func start(on network: NetworkSnapshot) {
        scanTask?.cancel()
        dhcpTask?.cancel()
        collectTask?.cancel()
        isCollectingMACs = false
        if scannedSubnet != network.subnet {
            devices = [:]
        }
        scannedSubnet = network.subnet
        scannedNetwork = network
        baseline = history.baseline(for: network)
        aliasEdits = [:]
        for address in devices.keys {
            refresh(address)
        }
        progress = 0
        status = .checkingAccess

        scanTask = Task {
            let started = ContinuousClock.now
            let startedAt = Date.now
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
            let duration = started.duration(to: .now)
            status = .finished(at: .now, duration: duration)
            let all = Array(devices.values)
            history.record(all, new: Set(all.filter(baseline.isNew).map(\.address)),
                           network: network, startedAt: startedAt, duration: duration)
            // 이제 기록에 있으니 백그라운드 알림에서 다시 알리지 않아도 된다
            BackgroundCheck.clearNotified()
            endBackgroundTask()
        }
    }

    func cancel() {
        guard isRunning else { return }
        scanTask?.cancel()
        scanTask = nil
        dhcpTask?.cancel()
        status = .cancelled
        isNaming = false
        endBackgroundTask()
    }

    // MARK: 백그라운드

    /// 앱이 백그라운드로 갈 때: 포트 스캔은 멈추고, 진행 중인 스캔은 iOS가 주는 시간(약 30초) 동안 마무리한다.
    /// 시간이 다 되면 멈춘다(끝까지 못 마친 스캔은 기록하지 않는다).
    func enterBackground() {
        dhcpTask?.cancel()   // 백그라운드에선 소켓을 놓는다(계속 못 듣는다)
        for address in Array(portScanTasks.keys) {
            cancelPortScan(of: address)
        }
        guard isRunning, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "NAGO NET 스캔 마무리") { [weak self] in
            MainActor.assumeIsolated {
                self?.cancel()
                self?.endBackgroundTask()
            }
        }
    }

    func enterForeground() {
        endBackgroundTask()
        // 스캔이 끝난 상태로 돌아오면 DHCP 듣기를 이어 간다(스캔 중이면 스캔이 알아서 띄운다)
        if let network = scannedNetwork, !isRunning, AppSettings.dhcpSniffEnabled {
            startDHCPSniff(on: network)
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
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
        scannedNetwork = nil
        baseline = .empty
    }

    /// 스캔과 포트 스캔을 모두 멈춘다(앱이 백그라운드로 갈 때).
    func stopEverything() {
        cancel()
        for address in Array(portScanTasks.keys) {
            cancelPortScan(of: address)
        }
    }

    // MARK: 별명

    /// 별명을 붙인다. 빈 글이나 nil이면 지운다. SwiftData에 저장돼 다음 스캔에서도 같은 기기에 붙는다.
    func setAlias(_ text: String?, for address: IPv4) {
        guard let device = devices[address], let network = scannedNetwork else { return }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let alias = trimmed?.isEmpty == false ? trimmed : nil
        history.setAlias(alias, for: device, network: network)
        legacyAliases.setAlias(nil, forKeys: device.identity.keys(network: legacyNetworkKey))
        aliasEdits[address] = .some(alias)
        devices[address]?.alias = alias
    }

    private var legacyNetworkKey: String { scannedSubnet?.cidr ?? "" }

    /// 기기 정보가 늘었을 때 따라 바뀌는 것: 기기가 공개한 MAC 단서, MAC 제조사, 별명
    private func refresh(_ address: IPv4) {
        let vendorLookup = self.vendorLookup
        if var device = devices[address], device.refreshReportedMACs(isRegistered: { vendorLookup($0) != nil }) {
            devices[address] = device
        }
        rememberOrRecallMAC(of: address)
        if let mac = devices[address]?.mac?.address {
            let vendor = vendorLookup(mac)
            if devices[address]?.macVendor != vendor {
                devices[address]?.macVendor = vendor
            }
        }
        refreshAlias(of: address)
    }

    /// 이번에 실제로 잡은 MAC은 이름으로 기억해 두고, 못 잡았으면 이전에 기억한 MAC을 되살린다.
    /// DHCP는 기기가 붙거나 갱신하는 순간만 잡혀서, Apple 기기는 한 스캔에서만 잡히기 쉽다 — 그래서 기억해 둔다.
    private func rememberOrRecallMAC(of address: IPv4) {
        guard let device = devices[address], !device.isSelf else { return }
        let keys = device.identity.stableKeys(network: legacyNetworkKey)
        if let observed = device.observedMAC?.address {
            macMemory.remember(observed, forKeys: keys)
            if devices[address]?.rememberedMAC != nil { devices[address]?.rememberedMAC = nil }
        } else if let recalled = macMemory.recall(forKeys: keys), devices[address]?.rememberedMAC != recalled {
            devices[address]?.rememberedMAC = recalled
        }
    }

    /// 기기의 별명: 이번에 고친 것 → 기록(SwiftData) → 4단계의 UserDefaults
    private func refreshAlias(of address: IPv4) {
        guard let device = devices[address] else { return }
        let alias: String?
        if let edited = aliasEdits[address] {
            alias = edited
        } else {
            alias = baseline.known(device.identity)?.alias
                ?? legacyAliases.alias(forKeys: device.identity.keys(network: legacyNetworkKey))
        }
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

        startDHCPSniff(on: network)   // 스캔 도는 동안 DHCP 요청을 엿들어 MAC을 잡는다(실험, 공유기·비번 없이)

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

                for await event in makeScanner(network).scan(network.scanTargets) {
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
            // 웹·SSH 포트가 열린 기기의 배너(이름 없는 공유기·AP·프린터·NAS의 단서)와 공유기 ARP 표(MAC)
            if !denied, !Task.isCancelled {
                // 스캔하며 OS가 채운 이 기기 ARP 캐시에서 MAC을 먼저 거둔다(공짜, 권한 불필요)
                applyLocalARP(on: network)
                async let routerTable: Void = readRouterTable(on: network)
                async let probes: Void = probeMACs()
                await readBanners(of: devices.values.filter { !$0.isSelf && $0.banners.isEmpty })
                await routerTable
                await probes
                await harvestNeighbors(on: network)   // IPv6 이웃 탐색(NDP)으로 Apple 기기 MAC까지 — 매 스캔 자동
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
                    refresh(done)
                    running -= 1
                }
                group.addTask { (address, await naming.names(for: address)) }
                running += 1
            }
            for await (done, names) in group {
                devices[done]?.merge(names)
                refresh(done)
            }
        }
    }

    /// 이 기기 자신의 ARP 캐시를 읽어 MAC을 채운다. 스캔하며 연결한 기기의 MAC이 여기 담겨 있다.
    /// 더불어 iOS가 그 MAC을 흘려주는지(진짜 MAC)·가리는지(02:00:…)를 그대로 세어 진단 한 줄로 남긴다.
    private func applyLocalARP(on network: NetworkSnapshot) {
        let arp = arpCache.readReport()
        for (address, mac) in arp.usable where devices[address] != nil {
            if devices[address]?.localARPMAC != mac {
                devices[address]?.localARPMAC = mac
                refresh(address)
            }
        }
        // IPv6 이웃(NDP) 캐시도 새는지 본다. 새면, 그 IPv6를 광고한 기기에 MAC을 붙인다(공유기 없이 얻은 진짜 MAC).
        let ndp = arpCache.readNDPReport()
        for (ip6, mac) in ndp.usable {
            guard let address = devices.first(where: { $0.value.ipv6Addresses.contains(ip6) })?.key else { continue }
            if devices[address]?.localARPMAC != mac {
                devices[address]?.localARPMAC = mac
                refresh(address)
            }
        }
        localARPStatus = Self.localARPMessage(arp: arp, ndp: ndp)
    }

    /// ARP·NDP 캐시 진단을 사람이 읽을 줄로. iOS가 MAC을 주는지/가리는지 추측 없이 측정값 그대로 알린다.
    static func localARPMessage(arp: ARPCacheReport, ndp: NDPReport) -> String? {
        var lines: [String] = []
        if arp.usableCount > 0 {
            lines.append("ARP(IPv4)에서 MAC \(arp.usableCount)개를 직접 읽었어요(항목 \(arp.entries)개). iOS가 흘리는 기기예요!")
        } else if arp.hiddenCount > 0 {
            lines.append("iOS가 ARP 항목 \(arp.hiddenCount)개를 주지만 MAC은 전부 02:00:…으로 가렸어요.")
        }
        if ndp.usableCount > 0 {
            lines.append("IPv6 이웃(NDP) 캐시에선 MAC \(ndp.usableCount)개가 새어나왔어요! 공유기 없이 얻은 진짜 MAC이에요.")
        } else if ndp.hiddenCount > 0 {
            lines.append("IPv6 이웃(NDP) 항목 \(ndp.hiddenCount)개도 MAC은 가려져 있어요.")
        }
        if arp.usableCount == 0, ndp.usableCount == 0, !lines.isEmpty {
            lines.append("→ 이 기기에선 다른 기기 MAC을 공유기 SNMP로만 얻을 수 있어요.")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// 앱이 떠 있는 동안 계속 듣는다(백그라운드 가면 멈춤). 안전 상한만 길게 둔다
    static let dhcpListenWindow: Duration = .seconds(1800)

    /// DHCP 요청을 엿듣는다. 기기가 Wi-Fi에 붙거나 갱신하면 그 chaddr MAC을 잡는다 — 공유기·비번 없이.
    /// 잡을 때마다 상태를 바로 갱신한다. 새 스캔이 시작되면 이전 리스너는 취소된다.
    private func startDHCPSniff(on network: NetworkSnapshot) {
        dhcpTask?.cancel()
        guard AppSettings.dhcpSniffEnabled else { dhcpStatus = nil; return }
        dhcpStatus = nil
        let sniffer = dhcpSniffer
        let window = Self.dhcpListenWindow
        dhcpTask = Task {
            var caught = 0
            for await event in sniffer.events(on: network.interfaceName, for: window) {
                if Task.isCancelled { break }
                switch event {
                case .listening:
                    dhcpStatus = Self.dhcpMessage(blocked: false, caught: 0)
                case .blocked:
                    dhcpStatus = Self.dhcpMessage(blocked: true, caught: 0)
                case .sighting(let sighting):
                    if applyDHCP(sighting, network: network) { caught += 1 }
                    dhcpStatus = Self.dhcpMessage(blocked: false, caught: caught)
                }
            }
        }
    }

    /// 잡은 DHCP MAC을 그 IP의 기기에 붙인다(요청 IP를 알 때만). 값이 새로 생기거나 바뀌었으면 true.
    @discardableResult
    private func applyDHCP(_ sighting: DHCPSighting, network: NetworkSnapshot) -> Bool {
        guard let ip = sighting.requestedIP, network.subnet.contains(ip) else { return false }
        let had = devices[ip]?.dhcpMAC
        upsert(ip, network: network) { $0.dhcpMAC = sighting.mac }
        return had != sighting.mac
    }

    /// DHCP 스니핑 결과를 사람이 읽을 한 줄로. 막혔는지/잡았는지 측정값 그대로 알린다.
    static func dhcpMessage(blocked: Bool, caught: Int) -> String {
        if blocked {
            return "DHCP 스니핑: iOS가 소켓(:67·:68)을 막아 못 들었어요 — 이 기기에선 이 길은 불가."
        }
        if caught > 0 {
            return "DHCP 스니핑: 기기가 붙거나 갱신할 때 MAC \(caught)개를 직접 잡았어요! 공유기 없이 얻은 거예요."
        }
        return "DHCP 스니핑: 듣는 중(iOS 허용) — 폰 하나의 Wi-Fi(또는 비행기모드)를 껐다 켜면 그 순간 잡혀요."
    }

    /// MAC 집중 수집: 로그인 없이 가능한 수집기를 전체 재스캔 없이 한 번에 다시 돌린다 —
    /// 이 기기 ARP·NDP 캐시, 공유기·기기 SNMP, 기기 정보 API. DHCP는 상시 듣기를 다시 켜 둔다.
    /// 아직 MAC을 못 잡은 기기를 마저 채우려는 것(대부분은 그 기기를 Wi-Fi 재연결해야 DHCP로 잡힌다).
    func collectMACs() {
        guard let network = scannedNetwork, !isRunning, !isCollectingMACs else { return }
        collectTask?.cancel()
        startDHCPSniff(on: network)
        isCollectingMACs = true
        collectTask = Task {
            applyLocalARP(on: network)
            async let router: Void = readRouterTable(on: network)
            async let probes: Void = probeMACs()
            await router
            await probes
            await harvestNeighbors(on: network)
            isCollectingMACs = false
        }
    }

    /// IPv6 이웃 탐색(NDP) 실험: 알려진 링크로컬을 찔러 상대가 쏘는 NS/NA에서 MAC을 거둔다(공유기·비번 없이).
    /// iOS가 ND를 앱 소켓에 넘겨주는지 실제로 측정한다. 되면 Apple 기기 MAC을 온디맨드로 얻을 수 있다.
    private func harvestNeighbors(on network: NetworkSnapshot) async {
        let targets = devices.values.flatMap(\.ipv6Addresses).filter(\.isLinkLocal)
        let finding = await neighborProber.harvest(on: network.interfaceName, provoking: targets, for: .seconds(4))
        for (ip6, mac) in finding.found {
            guard let address = devices.first(where: { $0.value.ipv6Addresses.contains(ip6) })?.key else { continue }
            if devices[address]?.neighborMAC != mac {
                devices[address]?.neighborMAC = mac
                refresh(address)
            }
        }
        // 이번 판은 캐시가 데워져 0개여도, 그동안 ND로 잡은 전체 개수를 보여 준다(마지막 판만 보여 혼란스럽던 것 고침)
        let total = devices.values.filter { $0.neighborMAC != nil }.count
        neighborStatus = Self.neighborMessage(blocked: finding.blocked, total: total)
    }

    static func neighborMessage(blocked: Bool, total: Int) -> String {
        if total > 0 {
            return "IPv6 이웃 탐색: ND로 MAC \(total)개를 직접 받았어요! 공유기 없이 얻은 진짜 MAC이에요."
        }
        if blocked {
            return "IPv6 이웃 탐색: iOS가 ICMPv6 소켓을 막았어요 — 이 길은 불가."
        }
        return "IPv6 이웃 탐색: 소켓은 열렸는데 아직 0개 — 핑에 응답하며 ND를 쏠 때 잡혀요."
    }

    /// 공유기(다음으로 관리형 AP 몇 대)에 SNMP로 ARP 표를 물어 MAC을 채운다. 탐색엔 안 잡혔지만
    /// 공유기가 최근에 본 기기도 목록에 더한다("공유기 기록에만 있음").
    private func readRouterTable(on network: NetworkSnapshot) async {
        guard AppSettings.snmpEnabled else {
            routerTableStatus = nil
            return
        }
        let community = AppSettings.snmpCommunity
        let accessPoints = devices.values.filter { $0.kind == .router && !$0.isGateway }.map(\.address).sorted().prefix(3)
        for router in [network.gateway.address] + accessPoints {
            guard !Task.isCancelled else { return }
            guard let table = await arpReader.read(from: router, community: community), !table.isEmpty else { continue }
            for (address, mac) in table where network.scanRange.addresses.contains(address) || address == network.gateway.address {
                upsert(address, network: network) { device in
                    if device.responseTime == nil, !device.isSelf, device.services.isEmpty {
                        device.seenOnlyInRouterTable = true
                    }
                    device.routerMAC = mac
                }
            }
            routerTableStatus = "공유기 ARP 표(SNMP, \(router))에서 MAC \(table.count)개를 읽었어요."
            return
        }
        routerTableStatus = "SNMP 응답이 없어 MAC은 기기가 알려 준 것만 있어요(공유기에서 SNMP가 꺼져 있거나 커뮤니티 문자열이 달라요)."
    }

    /// 아직 MAC을 모르는 기기에 직접 묻는다: 기기 SNMP(설정에서 켰을 때)와 Roku·삼성 TV·Hue·Shelly 정보 API. 16대씩.
    private func probeMACs() async {
        let prober = macProber
        let community = AppSettings.snmpEnabled ? AppSettings.snmpCommunity : nil
        let targets = devices.values.filter { !$0.isSelf && $0.mac == nil && !$0.seenOnlyInRouterTable }
            .map { ($0.address, $0.allOpenPorts) }
        await withTaskGroup(of: (IPv4, (MACAddress, MACSource)?).self) { group in
            var next = 0
            func addNext() {
                let (address, ports) = targets[next]
                next += 1
                group.addTask { (address, await prober.probe(address, openPorts: ports, community: community)) }
            }
            while next < min(Self.maxConcurrentProbes, targets.count) { addNext() }
            while let (address, found) = await group.next() {
                if case let (mac, source)? = found, devices[address]?.reportedMACs[source] != mac {
                    devices[address]?.reportedMACs[source] = mac
                    refresh(address)
                }
                if next < targets.count, !Task.isCancelled { addNext() }
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
                refresh(address)
                if next < jobs.count, !Task.isCancelled { addNext() }
            }
        }
    }

    /// 주소의 기기를 고치고, 처음 보는 주소면 새로 넣으며 DNS 조회를 건다.
    private func upsert(_ address: IPv4, network: NetworkSnapshot, _ change: (inout Device) -> Void) {
        if var device = devices[address] {
            change(&device)
            devices[address] = device
            refresh(address)
            return
        }
        var device = Device(address: address, isGateway: address == network.gateway.address)
        change(&device)
        devices[address] = device
        refresh(address)
        if !device.isSelf {
            lookupQueue?.yield(address)
        }
    }
}
