import Foundation

/// 목록에 보이는 기기 하나. 3단계부터 이름(Bonjour·DNS), 4단계부터 종류가 붙는다.
public struct Device: Hashable, Sendable, Identifiable {
    public let address: IPv4
    /// 가장 빠른 TCP 답까지 걸린 시간. 이 기기 자신은 nil
    public var responseTime: Duration?
    /// 탐색 포트 중 열려 있던 것
    public var openPorts: [UInt16]
    public var isSelf: Bool
    public var isGateway: Bool

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

    /// 사람이 읽을 이름. 모르면 nil(화면에는 IP를 쓴다)
    public var name: String? {
        if isSelf { return "이 기기" }
        if isGateway { return "공유기" }
        return nil
    }

    /// 탐색 결과를 합친다(같은 주소가 여러 번 온다).
    public mutating func merge(_ host: DiscoveredHost) {
        responseTime = responseTime.map { min($0, host.responseTime) } ?? host.responseTime
        openPorts = Array(Set(openPorts + host.openPorts)).sorted()
    }
}

public enum DeviceSort: String, CaseIterable, Sendable, Identifiable {
    case address
    case name

    public var id: Self { self }

    public var title: String {
        switch self {
        case .address: "IP순"
        case .name: "이름순"
        }
    }
}

extension Sequence where Element == Device {
    /// IP순: 숫자 크기대로. 이름순: 이름 있는 기기를 먼저 가나다순으로, 이름 없는 기기는 뒤에 IP순으로.
    public func sorted(by order: DeviceSort) -> [Device] {
        switch order {
        case .address:
            return sorted { $0.address < $1.address }
        case .name:
            return sorted { lhs, rhs in
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
    }
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
