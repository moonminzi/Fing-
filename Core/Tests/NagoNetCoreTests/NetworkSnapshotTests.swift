import Testing
@testable import NagoNetCore

struct NetworkSnapshotTests {
    private let routes = [
        Route(interfaceIndex: 6, flags: 0x803, destination: IPv4(0), gateway: IPv4(192, 168, 0, 1), netmask: IPv4(0)),
    ]

    @Test func buildsFromWiFiInterface() throws {
        let interfaces = [
            InterfaceAddress(name: "lo0", address: IPv4(127, 0, 0, 1), netmask: IPv4(255, 0, 0, 0)),
            InterfaceAddress(name: "pdp_ip0", address: IPv4(10, 77, 1, 2), netmask: IPv4(255, 255, 255, 255)),
            InterfaceAddress(name: "en0", address: IPv4(192, 168, 0, 23), netmask: IPv4(255, 255, 255, 0)),
        ]
        let snapshot = try NetworkSnapshot.make(interfaceName: "en0", interfaces: interfaces, routes: routes, interfaceIndex: 6)
        #expect(snapshot.myAddress == IPv4(192, 168, 0, 23))
        #expect(snapshot.subnet.prefixLength == 24)
        #expect(snapshot.gateway == Gateway(address: IPv4(192, 168, 0, 1), isEstimated: false))
        #expect(snapshot.scanRange.count == 254)
        #expect(!snapshot.isSelfAssigned)
    }

    @Test func prefersRealAddressOverSelfAssigned() throws {
        let interfaces = [
            InterfaceAddress(name: "en0", address: IPv4(169, 254, 10, 2), netmask: IPv4(255, 255, 0, 0)),
            InterfaceAddress(name: "en0", address: IPv4(192, 168, 0, 23), netmask: IPv4(255, 255, 255, 0)),
        ]
        let snapshot = try NetworkSnapshot.make(interfaceName: "en0", interfaces: interfaces, routes: nil, interfaceIndex: nil)
        #expect(snapshot.myAddress == IPv4(192, 168, 0, 23))
        #expect(snapshot.gateway.isEstimated)
    }

    @Test func selfAssignedOnlyIsReported() throws {
        let interfaces = [InterfaceAddress(name: "en0", address: IPv4(169, 254, 10, 2), netmask: IPv4(255, 255, 0, 0))]
        let snapshot = try NetworkSnapshot.make(interfaceName: "en0", interfaces: interfaces, routes: nil, interfaceIndex: nil)
        #expect(snapshot.isSelfAssigned)
        #expect(snapshot.scanRange.isPartial)
        #expect(snapshot.scanRange.count == 1024)
    }

    @Test func notConnectedWhenInterfaceMissingOrDown() {
        let down = [InterfaceAddress(name: "en0", address: IPv4(192, 168, 0, 23), netmask: IPv4(255, 255, 255, 0), isUp: false)]
        #expect(throws: NetworkInfoError.notConnected(interface: "en0")) {
            try NetworkSnapshot.make(interfaceName: "en0", interfaces: down, routes: nil, interfaceIndex: nil)
        }
        #expect(throws: NetworkInfoError.notConnected(interface: "en0")) {
            try NetworkSnapshot.make(interfaceName: "en0", interfaces: [], routes: nil, interfaceIndex: nil)
        }
    }

    @Test func rejectsBrokenNetmask() {
        let odd = [InterfaceAddress(name: "en0", address: IPv4(192, 168, 0, 23), netmask: IPv4(255, 0, 255, 0))]
        #expect(throws: NetworkInfoError.invalidNetmask(IPv4(255, 0, 255, 0))) {
            try NetworkSnapshot.make(interfaceName: "en0", interfaces: odd, routes: nil, interfaceIndex: nil)
        }
    }

    /// 이 기계의 진짜 인터페이스를 읽어 본다(어느 OS에나 루프백은 있다).
    @Test func readsRealLoopback() throws {
        let all = Interfaces.ipv4Addresses()
        let loopback = try #require(all.first { $0.address == IPv4(127, 0, 0, 1) })
        #expect(loopback.netmask == IPv4(255, 0, 0, 0))
        #expect(loopback.isUp)
        #expect(Interfaces.index(of: loopback.name) != nil)
        #expect(Interfaces.index(of: "no-such-if0") == nil)
    }
}
