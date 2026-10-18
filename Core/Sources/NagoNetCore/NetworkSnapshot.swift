/// 지금 붙어 있는 Wi-Fi 네트워크를 한 번 읽은 결과.
public struct NetworkSnapshot: Hashable, Sendable {
    /// 한 번에 스캔하는 최대 호스트 수. 이보다 큰 대역은 내 주소 근처만 스캔한다.
    public static let scanLimit = 1024

    /// BSD 인터페이스 이름(보통 en0)
    public var interfaceName: String
    public var subnet: Subnet
    public var gateway: Gateway
    /// 네트워크 이름. 정확한 위치 권한이나 Wi-Fi 정보 권한(entitlement)이 없으면 nil
    public var ssid: String?

    public init(interfaceName: String, subnet: Subnet, gateway: Gateway, ssid: String? = nil) {
        self.interfaceName = interfaceName
        self.subnet = subnet
        self.gateway = gateway
        self.ssid = ssid
    }

    public var myAddress: IPv4 { subnet.address }
    public var scanRange: ScanRange { subnet.scanRange(limit: Self.scanLimit) }
    /// 169.254.x.x: DHCP에서 주소를 못 받아 기기가 스스로 붙인 주소
    public var isSelfAssigned: Bool { myAddress.isLinkLocal }
}

public enum NetworkInfoError: Error, Equatable, Sendable {
    /// 이 인터페이스에 IPv4 주소가 없다(Wi-Fi에 연결 안 됨)
    case notConnected(interface: String)
    /// 넷마스크가 1…10…0 꼴이 아니다
    case invalidNetmask(IPv4)
}

extension NetworkSnapshot {
    /// 읽어 온 인터페이스 목록과 라우팅 테이블로 스냅숏을 만든다. 시험할 수 있게 입력을 모두 밖에서 받는다.
    public static func make(
        interfaceName: String,
        interfaces: [InterfaceAddress],
        routes: [Route]?,
        interfaceIndex: UInt32?
    ) throws -> NetworkSnapshot {
        guard let interface = Interfaces.preferred(on: interfaceName, in: interfaces) else {
            throw NetworkInfoError.notConnected(interface: interfaceName)
        }
        guard let subnet = Subnet(address: interface.address, mask: interface.netmask) else {
            throw NetworkInfoError.invalidNetmask(interface.netmask)
        }
        let gateway = Gateway.resolve(subnet: subnet, routes: routes, interfaceIndex: interfaceIndex)
        return NetworkSnapshot(interfaceName: interfaceName, subnet: subnet, gateway: gateway)
    }

    /// 이 기기에서 지금 값을 읽는다(getifaddrs + 라우팅 테이블). SSID는 비워 둔다.
    public static func current(interfaceName: String) throws -> NetworkSnapshot {
        try make(
            interfaceName: interfaceName,
            interfaces: Interfaces.ipv4Addresses(),
            routes: RouteTable.read(),
            interfaceIndex: Interfaces.index(of: interfaceName)
        )
    }
}

/// 내 네트워크 정보를 읽는 쪽. 앱은 getifaddrs·라우팅 테이블·NEHotspotNetwork로 읽고, 시험에서는 가짜로 바꾼다.
public protocol NetworkInfoProviding: Sendable {
    /// `interfaceName`(Wi-Fi 인터페이스)의 주소·대역·게이트웨이·SSID
    func currentNetwork(interfaceName: String) async throws -> NetworkSnapshot
}
