import Foundation

/// 목록에 보이는 기기 하나.
public struct Device: Hashable, Sendable, Identifiable {
    public let address: IPv4
    /// 가장 빠른 TCP 답까지 걸린 시간. 이 기기 자신이나 Bonjour로만 찾은 기기는 nil
    public var responseTime: Duration?
    /// 탐색 포트 중 열려 있던 것
    public var openPorts: [UInt16]
    public var isSelf: Bool
    public var isGateway: Bool
    /// 사용자가 붙인 별명
    public var alias: String?
    /// 이 주소로 풀린 Bonjour 서비스(종류·이름 순)
    public var services: [BonjourService] = []
    /// 역방향 DNS 이름(공유기가 알려 준 그대로)
    public var hostName: String?
    /// 기기가 mDNS로 직접 알려 준 호스트 이름("Minjis-iPhone.local")
    public var mdnsName: String?
    /// NetBIOS 컴퓨터 이름(윈도우·삼바)
    public var netbiosName: String?
    /// 애플 기기가 `_device-info`로 알려 준 모델 식별자("iPad13,1")
    public var deviceInfoModel: String?
    /// 열린 포트에서 읽은 배너(포트 순)
    public var banners: [ServiceBanner] = []
    /// 상세 화면의 포트 스캔(주요 포트 100개)에서 찾은 열린 포트. 아직 안 했으면 nil
    public var scannedPorts: [UInt16]?

    public init(
        address: IPv4,
        responseTime: Duration? = nil,
        openPorts: [UInt16] = [],
        isSelf: Bool = false,
        isGateway: Bool = false
    ) {
        self.address = address
        self.responseTime = responseTime
        self.openPorts = openPorts
        self.isSelf = isSelf
        self.isGateway = isGateway
    }

    public var id: IPv4 { address }

    /// 사람이 읽을 이름. 별명 → Bonjour 이름 → 호스트 이름(mDNS → NetBIOS → DNS) → 배너의 제품명 →
    /// 배너의 제조사("Aruba AP") → "공유기" 순. 모르면 nil(화면에는 IP)
    public var name: String? {
        if let alias { return alias }
        if isSelf { return "이 기기" }
        return bonjourName ?? displayHostName ?? productName ?? vendorName ?? (isGateway ? "공유기" : nil)
    }

    /// 배너에서 찾은 제조사 + 종류("Aruba AP", "Synology NAS", "HP 프린터")
    public var vendorName: String? {
        guard let vendor = banners.lazy.compactMap(\.vendor).first else { return nil }
        if isGateway { return "\(vendor) 공유기" }
        switch kind {
        case .router: return "\(vendor) AP"
        case .unknown: return vendor
        default: return "\(vendor) \(kind.title)"
        }
    }

    /// 별명을 빼고 기기에서 찾은 이름(별명을 고칠 때 원래 이름으로 보여 준다)
    public var discoveredName: String? {
        var copy = self
        copy.alias = nil
        return copy.name
    }

    /// Bonjour 서비스에서 고른 이름
    public var bonjourName: String? {
        BonjourCatalog.preferredName(among: services)
    }

    /// 호스트 이름에서 꼬리(.local, .lan 등)를 뗀 것. 기기가 직접 알려 준 이름을 공유기 DNS보다 먼저
    public var displayHostName: String? {
        [mdnsName, netbiosName, hostName].lazy
            .compactMap { $0.flatMap { HostName.display($0, for: self.address) } }
            .first
    }

    /// 웹 페이지 제목·인증 영역·인증서에서 읽은 제품명("UniFi", "ipTIME A3004NS")
    public var productName: String? {
        banners.lazy.compactMap(\.productName).first
    }

    /// 모델 식별자: `_device-info` → 서비스 TXT(model·rpMd·am·md·ty)
    public var model: String? {
        if let deviceInfoModel { return deviceInfoModel }
        for key in ["model", "rpmd", "am", "md", "ty"] {
            if let value = services.lazy.compactMap({ $0.txt[key] }).first(where: { !$0.isEmpty }) {
                return value
            }
        }
        return nil
    }

    /// 탐색 포트 + 포트 스캔에서 찾은 열린 포트
    public var allOpenPorts: [UInt16] {
        Array(Set(openPorts + (scannedPorts ?? []))).sorted()
    }

    public var classification: DeviceClassification {
        DeviceClassifier().classify(self)
    }

    public var kind: DeviceKind { classification.kind }

    /// 아직 이름을 하나도 못 찾았는지(다시 스캔할 때 다시 묻는다)
    public var needsNames: Bool {
        !isSelf && services.isEmpty && mdnsName == nil && netbiosName == nil && hostName == nil
    }

    /// TCP에는 답하지 않고 Bonjour로만 찾은 기기
    public var isBonjourOnly: Bool {
        !isSelf && responseTime == nil && !services.isEmpty
    }

    /// 탐색 결과를 합친다(같은 주소가 여러 번 온다).
    public mutating func merge(_ host: DiscoveredHost) {
        responseTime = responseTime.map { min($0, host.responseTime) } ?? host.responseTime
        openPorts = Array(Set(openPorts + host.openPorts)).sorted()
    }

    /// 이름 조회 결과를 합친다. 새로 못 찾은 것은 이전 값을 지킨다.
    public mutating func merge(_ names: DeviceNames) {
        hostName = names.dnsName ?? hostName
        mdnsName = names.mdnsName ?? mdnsName
        netbiosName = names.netbiosName ?? netbiosName
        deviceInfoModel = names.model ?? deviceInfoModel
        names.services.forEach { merge($0) }
    }

    /// Bonjour 서비스를 더한다. 같은 종류·이름이면 새 정보로 바꾼다.
    public mutating func merge(_ service: BonjourService) {
        services.removeAll { $0.type == service.type && $0.name == service.name }
        services.append(service)
        services.sort { ($0.typeTitle, $0.name) < ($1.typeTitle, $1.name) }
    }

    /// 배너를 더한다. 같은 포트면 바꾼다.
    public mutating func merge(_ banner: ServiceBanner) {
        banners.removeAll { $0.port == banner.port }
        banners.append(banner)
        banners.sort { $0.port < $1.port }
    }
}

public enum DeviceSort: String, CaseIterable, Sendable, Identifiable {
    case address
    case name
    case kind

    public var id: Self { self }

    public var title: String {
        switch self {
        case .address: "IP순"
        case .name: "이름순"
        case .kind: "종류별"
        }
    }
}

extension Sequence where Element == Device {
    /// IP순: 숫자 크기대로. 이름순: 이름 있는 기기를 먼저 가나다순으로, 이름 없는 기기는 뒤에 IP순으로.
    /// 종류별: 공유기 → iPhone → … → 알 수 없음, 같은 종류 안에서는 이름순.
    public func sorted(by order: DeviceSort) -> [Device] {
        switch order {
        case .address:
            return sorted { $0.address < $1.address }
        case .name:
            return sorted(by: Self.byName)
        case .kind:
            let kinds = DeviceKind.allCases
            return map { ($0, kinds.firstIndex(of: $0.kind) ?? kinds.count) }
                .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : Self.byName($0.0, $1.0) }
                .map(\.0)
        }
    }

    private static func byName(_ lhs: Device, _ rhs: Device) -> Bool {
        switch (lhs.name, rhs.name) {
        case let (left?, right?) where left != right:
            return left.localizedStandardCompare(right) == .orderedAscending
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            return lhs.address < rhs.address
        }
    }
}

/// 기기를 다시 알아보는 데 쓰는 것: IP, 호스트 이름, Bonjour 이름.
///
/// IP는 DHCP가 바꿀 수 있어서, 이름이 있으면 이름을 먼저 믿는다.
public struct DeviceIdentity: Hashable, Sendable, Codable {
    public let address: IPv4
    public let hostName: String?
    public let bonjourName: String?

    public init(address: IPv4, hostName: String?, bonjourName: String?) {
        self.address = address
        self.hostName = hostName
        self.bonjourName = bonjourName
    }

    /// 믿을 만한 순서의 열쇠들. IP 열쇠는 네트워크마다 다른 기기일 수 있어 `network`로 구분한다.
    public func keys(network: String) -> [String] {
        [
            bonjourName.map { "bonjour:\($0.lowercased())" },
            hostName.map { "host:\($0.lowercased())" },
            "ip:\(network)/\(address)",
        ].compactMap { $0 }
    }
}

extension Device {
    public var identity: DeviceIdentity {
        DeviceIdentity(address: address, hostName: displayHostName, bonjourName: bonjourName)
    }
}

/// 기기 별명 보관. 앱은 UserDefaults(5단계에서 SwiftData), 시험은 메모리.
public protocol AliasStoring: Sendable {
    /// 열쇠들 중 처음 걸리는 별명
    func alias(forKeys keys: [String]) -> String?
    /// 별명을 저장한다(nil이면 지운다). 같은 기기의 다른 열쇠에 남은 옛 별명도 지운다
    func setAlias(_ alias: String?, forKeys keys: [String])
}

extension NetworkSnapshot {
    /// 실제로 두드려 볼 주소: 스캔 범위에서 나를 빼고, 게이트웨이가 범위 밖이면(큰 대역) 맨 앞에 더한다.
    public var scanTargets: [IPv4] {
        let range = scanRange.addresses
        var targets = range.filter { $0 != myAddress }
        if !range.contains(gateway.address), gateway.address != myAddress {
            targets.insert(gateway.address, at: 0)
        }
        return targets
    }
}

extension Duration {
    /// 밀리초(소수점 포함)
    public var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }

    /// 화면용: "<1 ms", "12 ms", "1.2 s"
    public var shortDescription: String {
        let ms = milliseconds
        if ms < 1 { return "<1 ms" }
        if ms < 1_000 { return "\(Int(ms.rounded())) ms" }
        return String(format: "%.1f s", ms / 1_000)
    }
}
