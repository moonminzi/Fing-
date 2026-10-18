/// 내 주소와 서브넷 마스크로 정해지는 IPv4 대역.
public struct Subnet: Hashable, Sendable {
    /// 이 기기의 주소
    public let address: IPv4
    public let mask: IPv4

    /// 마스크가 1…10…0 꼴(255.255.255.0 같은)이 아니면 nil.
    public init?(address: IPv4, mask: IPv4) {
        let hostBits = ~mask.value
        guard hostBits & (hostBits &+ 1) == 0 else { return nil }
        self.address = address
        self.mask = mask
    }

    public init?(address: IPv4, prefixLength: Int) {
        guard (0...32).contains(prefixLength) else { return nil }
        let mask: UInt32 = prefixLength == 0 ? 0 : ~UInt32(0) << UInt32(32 - prefixLength)
        self.init(address: address, mask: IPv4(mask))
    }

    public var prefixLength: Int { mask.value.nonzeroBitCount }
    public var network: IPv4 { IPv4(address.value & mask.value) }
    public var broadcast: IPv4 { IPv4(network.value | ~mask.value) }
    /// "192.168.0.0/24"
    public var cidr: String { "\(network)/\(prefixLength)" }

    /// 기기에 줄 수 있는 주소들. /31은 두 주소 모두(RFC 3021), /32는 나 혼자.
    public var hosts: ClosedRange<IPv4> {
        switch prefixLength {
        case 32: address...address
        case 31: network...broadcast
        default: network.advanced(by: 1)...broadcast.advanced(by: -1)
        }
    }

    public var hostCount: Int { hosts.count }

    public func contains(_ ip: IPv4) -> Bool {
        ip.value & mask.value == network.value
    }

    /// 공유기 주소를 모를 때 쓰는 흔한 값: 대역의 첫 주소(보통 .1)
    public var conventionalGateway: IPv4 { hosts.lowerBound }

    /// 스캔할 주소 범위.
    ///
    /// 호스트가 `limit`개보다 많으면(/22보다 큰 대역) 내 주소가 들어 있는 칸 하나만 고른다.
    /// 칸 크기는 `limit` 이하의 2의 거듭제곱이고 칸 경계에 줄을 맞춘다(1024면 /22 한 칸).
    public func scanRange(limit: Int) -> ScanRange {
        let hosts = self.hosts
        guard limit > 0, hosts.count > limit else {
            return ScanRange(addresses: hosts, isPartial: false)
        }
        let blockSize = UInt32(1) << UInt32(Int.bitWidth - 1 - limit.leadingZeroBitCount)
        let start = address.value & ~(blockSize - 1)
        let end = start + (blockSize - 1)
        let lower = max(start, hosts.lowerBound.value)
        let upper = min(end, hosts.upperBound.value)
        return ScanRange(addresses: IPv4(lower)...IPv4(upper), isPartial: true)
    }
}

/// 실제로 두드려 볼 주소들.
public struct ScanRange: Hashable, Sendable {
    public let addresses: ClosedRange<IPv4>
    /// 대역이 너무 커서 일부만 스캔하는지
    public let isPartial: Bool

    public init(addresses: ClosedRange<IPv4>, isPartial: Bool) {
        self.addresses = addresses
        self.isPartial = isPartial
    }

    public var count: Int { addresses.count }
}
