import Foundation

/// 네트워크를 다시 알아보는 데 쓰는 것. SSID가 있으면 SSID로, 없으면(위치 권한 없음) 대역 + 게이트웨이로.
public struct NetworkIdentity: Hashable, Sendable {
    public let ssid: String?
    /// "192.168.10.0/23"
    public let cidr: String
    public let gateway: IPv4

    public init(ssid: String?, cidr: String, gateway: IPv4) {
        self.ssid = ssid
        self.cidr = cidr
        self.gateway = gateway
    }

    public init(_ snapshot: NetworkSnapshot) {
        self.init(ssid: snapshot.ssid, cidr: snapshot.subnet.cidr, gateway: snapshot.gateway.address)
    }

    /// 같은 네트워크인지. 둘 다 SSID를 알면 SSID로, 한쪽이라도 모르면 대역과 게이트웨이로 본다.
    public func matches(_ other: NetworkIdentity) -> Bool {
        if let ssid, let otherSSID = other.ssid {
            return ssid == otherSSID
        }
        return cidr == other.cidr && gateway == other.gateway
    }

    /// 목록에 보일 이름
    public var title: String { ssid ?? cidr }

    /// 여러 후보 중 같은 네트워크(SSID가 같은 것을 먼저)
    public func firstMatch(in candidates: [NetworkIdentity]) -> Int? {
        if ssid != nil, let exact = candidates.firstIndex(where: { $0.ssid == ssid }) {
            return exact
        }
        return candidates.firstIndex(where: matches)
    }
}

/// 전에 본 기기 하나(기록에서 꺼낸 것).
public struct KnownDevice: Hashable, Sendable {
    public let identity: DeviceIdentity
    public let alias: String?

    public init(identity: DeviceIdentity, alias: String?) {
        self.identity = identity
        self.alias = alias
    }
}

/// 같은 기기 찾기: IP, 호스트 이름, Bonjour 이름 조합으로(MAC을 알면 MAC 먼저).
///
/// 0. MAC이 같으면 같은 기기(공유기 ARP 표·NetBIOS·AirPlay로 안 진짜 주소일 때)
/// 1. Bonjour 이름이 같으면 같은 기기(DHCP로 IP가 바뀌어도)
/// 2. 호스트 이름이 같으면 같은 기기
/// 3. IP가 같고 이름·MAC이 서로 다르지 않으면 같은 기기(이번에 이름을 못 찾았을 수도 있으니 한쪽만 있어도 된다).
///    IP가 같아도 MAC·Bonjour 이름·호스트 이름이 서로 다르면 IP를 물려받은 다른 기기다
///
/// 기록의 기기 하나는 지금 기기 하나에만 짝지어진다(강한 단서부터 차례로).
public enum DeviceMatcher {
    /// `current[i]`와 짝인 `known`의 번호(없으면 nil)
    public static func match(_ current: [DeviceIdentity], against known: [DeviceIdentity]) -> [Int?] {
        var result = [Int?](repeating: nil, count: current.count)
        var taken = Set<Int>()

        func pair(where isSame: (DeviceIdentity, DeviceIdentity) -> Bool) {
            for (i, identity) in current.enumerated() where result[i] == nil {
                if let j = known.indices.first(where: { !taken.contains($0) && isSame(identity, known[$0]) }) {
                    result[i] = j
                    taken.insert(j)
                }
            }
        }
        pair { lhs, rhs in lhs.mac != nil && lhs.mac == rhs.mac }
        pair { lhs, rhs in lhs.bonjourName != nil && same(lhs.bonjourName, rhs.bonjourName) && !macsDiffer(lhs, rhs) }
        pair { lhs, rhs in lhs.hostName != nil && same(lhs.hostName, rhs.hostName) && !macsDiffer(lhs, rhs) }
        pair { lhs, rhs in lhs.address == rhs.address && !conflicts(lhs, rhs) }
        return result
    }

    /// 하나만 찾을 때
    public static func match(_ identity: DeviceIdentity, against known: [DeviceIdentity]) -> Int? {
        match([identity], against: known)[0]
    }

    private static func same(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private static func macsDiffer(_ lhs: DeviceIdentity, _ rhs: DeviceIdentity) -> Bool {
        lhs.mac != nil && rhs.mac != nil && lhs.mac != rhs.mac
    }

    /// 둘 다 이름(이나 MAC)이 있는데 다르면 다른 기기
    private static func conflicts(_ lhs: DeviceIdentity, _ rhs: DeviceIdentity) -> Bool {
        if macsDiffer(lhs, rhs) { return true }
        if lhs.bonjourName != nil, rhs.bonjourName != nil, !same(lhs.bonjourName, rhs.bonjourName) { return true }
        if lhs.hostName != nil, rhs.hostName != nil, !same(lhs.hostName, rhs.hostName) { return true }
        return false
    }
}

/// 스캔을 시작할 때 꺼내 둔 이 네트워크의 기록. "새 기기"는 여기에 없는 기기다.
public struct NetworkBaseline: Sendable {
    public let knownDevices: [KnownDevice]
    /// 이 네트워크에서 전에 끝낸 스캔 수. 0이면 처음이라 "새 기기"를 표시하지 않는다
    public let previousScans: Int

    public init(knownDevices: [KnownDevice], previousScans: Int) {
        self.knownDevices = knownDevices
        self.previousScans = previousScans
    }

    public static let empty = NetworkBaseline(knownDevices: [], previousScans: 0)

    public func known(_ identity: DeviceIdentity) -> KnownDevice? {
        DeviceMatcher.match(identity, against: knownDevices.map(\.identity)).map { knownDevices[$0] }
    }

    /// 이전 스캔들에 없던 기기인지(이 기기 자신과 첫 스캔은 제외)
    public func isNew(_ device: Device) -> Bool {
        previousScans > 0 && !device.isSelf && known(device.identity) == nil
    }
}

/// 스캔 기록 저장소. 앱은 SwiftData로, 시험은 메모리로.
@MainActor
public protocol ScanHistoryStoring: AnyObject {
    /// 이 네트워크에서 전에 본 기기들(별명 포함)과 스캔 수
    func baseline(for network: NetworkSnapshot) -> NetworkBaseline
    /// 끝난 스캔을 저장하고, 본 기기들을 기억해 둔다. `new`는 스캔을 시작할 때의 기록으로 판단한 새 기기
    func record(_ devices: [Device], new: Set<IPv4>, network: NetworkSnapshot, startedAt: Date, duration: Duration)
    /// 별명을 저장한다(nil이면 지운다). 아직 기억하지 않은 기기면 새로 기억한다
    func setAlias(_ alias: String?, for device: Device, network: NetworkSnapshot)
}
