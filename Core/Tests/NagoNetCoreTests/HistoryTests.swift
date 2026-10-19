import Testing
@testable import NagoNetCore

private func id(_ last: UInt8, bonjour: String? = nil, host: String? = nil) -> DeviceIdentity {
    DeviceIdentity(address: IPv4(192, 168, 10, last), hostName: host, bonjourName: bonjour)
}

struct DeviceMatcherTests {
    @Test func bonjourNameFollowsDeviceAcrossIPChange() {
        let known = [id(20, bonjour: "민지의 iPad"), id(21)]
        #expect(DeviceMatcher.match(id(57, bonjour: "민지의 iPad"), against: known) == 0)
        #expect(DeviceMatcher.match(id(57, bonjour: "민지의 IPAD"), against: known) == 0)
    }

    @Test func hostNameMatchesWhenNoBonjour() {
        let known = [id(30, host: "galaxy-s23"), id(31)]
        #expect(DeviceMatcher.match(id(44, host: "Galaxy-S23"), against: known) == 0)
    }

    @Test func sameIPMatchesUnlessNamesDisagree() {
        let known = [id(40, bonjour: "거실 Apple TV")]
        // 이번엔 이름을 못 찾았어도 같은 IP면 같은 기기로
        #expect(DeviceMatcher.match(id(40), against: known) == 0)
        // 같은 IP에 다른 Bonjour 이름이면 IP를 물려받은 다른 기기
        #expect(DeviceMatcher.match(id(40, bonjour: "민지의 iPhone"), against: known) == nil)
        #expect(DeviceMatcher.match(id(41), against: known) == nil)
    }

    @Test func eachKnownDeviceIsUsedOnce() {
        // 두 기기가 IP를 맞바꿨다: 이름으로 먼저 짝짓고 남은 것을 IP로
        let known = [id(10, bonjour: "A"), id(11, bonjour: "B"), id(12)]
        let current = [id(11, bonjour: "A"), id(10, bonjour: "B"), id(12), id(12)]
        #expect(DeviceMatcher.match(current, against: known) == [0, 1, 2, nil])
    }
}

struct BaselineTests {
    private func device(_ last: UInt8, bonjour: String? = nil, isSelf: Bool = false) -> Device {
        var device = Device(address: IPv4(192, 168, 10, last), responseTime: .milliseconds(3), isSelf: isSelf)
        if let bonjour {
            device.merge(BonjourService(name: bonjour, type: "_companion-link._tcp", address: device.address))
        }
        return device
    }

    @Test func newDevicesAreThoseNotSeenBefore() {
        let baseline = NetworkBaseline(knownDevices: [
            KnownDevice(identity: id(5, bonjour: "민지의 iPad"), alias: "교탁"),
            KnownDevice(identity: id(6), alias: nil),
        ], previousScans: 2)
        #expect(!baseline.isNew(device(9, bonjour: "민지의 iPad")))   // IP만 바뀜
        #expect(baseline.known(device(9, bonjour: "민지의 iPad").identity)?.alias == "교탁")
        #expect(!baseline.isNew(device(6)))
        #expect(baseline.isNew(device(7)))
        #expect(!baseline.isNew(device(8, isSelf: true)))
    }

    @Test func firstScanMarksNothingNew() {
        #expect(!NetworkBaseline.empty.isNew(device(7)))
    }
}

struct NetworkIdentityTests {
    private let gateway = IPv4(192, 168, 10, 1)

    @Test func matchesBySSIDOrSubnetAndGateway() {
        let school = NetworkIdentity(ssid: "GreenLamp49", cidr: "192.168.10.0/23", gateway: gateway)
        #expect(school.matches(NetworkIdentity(ssid: "GreenLamp49", cidr: "10.0.0.0/24", gateway: IPv4(10, 0, 0, 1))))
        #expect(!school.matches(NetworkIdentity(ssid: "Home", cidr: "192.168.10.0/23", gateway: gateway)))
        // 위치 권한이 없어 SSID를 모르면 대역 + 게이트웨이
        #expect(school.matches(NetworkIdentity(ssid: nil, cidr: "192.168.10.0/23", gateway: gateway)))
        #expect(!school.matches(NetworkIdentity(ssid: nil, cidr: "192.168.10.0/23", gateway: IPv4(192, 168, 10, 254))))
        #expect(school.title == "GreenLamp49")
        #expect(NetworkIdentity(ssid: nil, cidr: "192.168.10.0/23", gateway: gateway).title == "192.168.10.0/23")
    }

    @Test func prefersExactSSID() {
        let candidates = [
            NetworkIdentity(ssid: nil, cidr: "192.168.10.0/23", gateway: gateway),
            NetworkIdentity(ssid: "GreenLamp49", cidr: "192.168.10.0/23", gateway: gateway),
        ]
        let me = NetworkIdentity(ssid: "GreenLamp49", cidr: "192.168.10.0/23", gateway: gateway)
        #expect(me.firstMatch(in: candidates) == 1)
        #expect(NetworkIdentity(ssid: nil, cidr: "192.168.10.0/23", gateway: gateway).firstMatch(in: candidates) == 0)
    }
}
