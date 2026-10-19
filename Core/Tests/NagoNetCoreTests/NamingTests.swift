import Testing
@testable import NagoNetCore

struct NamingTests {
    private let ip = IPv4(192, 168, 0, 33)

    private func service(_ type: String, _ name: String, txt: [String: String] = [:]) -> BonjourService {
        BonjourService(name: name, type: type, address: ip, txt: txt)
    }

    @Test func friendlyNames() {
        #expect(service("_raop._tcp", "A1B2C3D4E5F6@거실 HomePod").friendlyName == "거실 HomePod")
        #expect(service("_googlecast._tcp", "Chromecast-7f3a9c", txt: ["fn": "안방 TV"]).friendlyName == "안방 TV")
        #expect(service("_googlecast._tcp", "Chromecast-7f3a9c").friendlyName == "Chromecast-7f3a9c")
        #expect(service("_airplay._tcp", "  민지의 MacBook  ").friendlyName == "민지의 MacBook")
        #expect(service("_ssh._tcp", " ").friendlyName == nil)
    }

    @Test func prefersUserFacingServicesForName() {
        let services = [
            service("_ssh._tcp", "minji-mbp"),
            service("_smb._tcp", "MINJI-MBP"),
            service("_companion-link._tcp", "민지의 MacBook Pro"),
            service("_raop._tcp", "A1B2@민지의 MacBook Pro"),
        ]
        #expect(BonjourCatalog.preferredName(among: services) == "민지의 MacBook Pro")
        #expect(BonjourCatalog.preferredName(among: [service("_http._tcp", "NAS"), service("_ipp._tcp", "HP LaserJet")])
            == "HP LaserJet")
        #expect(BonjourCatalog.preferredName(among: []) == nil)
    }

    @Test func catalogMatchesInfoPlistList() {
        #expect(BonjourCatalog.serviceTypes.count == 16)
        #expect(Set(BonjourCatalog.serviceTypes) == Set(BonjourCatalog.titles.keys))
        #expect(Set(BonjourCatalog.serviceTypes) == Set(BonjourCatalog.namingOrder))
    }

    @Test func cleansHostNames() {
        #expect(HostName.display("Galaxy-S23.lan.", for: ip) == "Galaxy-S23")
        #expect(HostName.display("minji-iPad.local", for: ip) == "minji-iPad")
        #expect(HostName.display("printer", for: ip) == "printer")
        #expect(HostName.display("192-168-0-33.home", for: ip) == nil)
        #expect(HostName.display("host_192_168_0_33.isp.example", for: ip) == nil)
        #expect(HostName.display("192.168.0.33", for: ip) == nil)
        #expect(HostName.display(".", for: ip) == nil)
    }

    @Test func deviceNamePriority() {
        var device = Device(address: ip, responseTime: .milliseconds(5), isGateway: true)
        #expect(device.name == "공유기")
        device.hostName = "iptime.lan"
        #expect(device.name == "iptime")
        device.merge(service("_http._tcp", "ipTIME A3004NS"))
        #expect(device.name == "ipTIME A3004NS")

        var me = Device(address: ip, isSelf: true)
        me.merge(service("_companion-link._tcp", "민지의 iPad"))
        #expect(me.name == "이 기기")
    }

    @Test func mergingServicesReplacesSameTypeAndName() {
        var device = Device(address: ip)
        device.merge(service("_airplay._tcp", "TV", txt: ["model": "old"]))
        device.merge(service("_airplay._tcp", "TV", txt: ["model": "AppleTV14,1"]))
        device.merge(service("_raop._tcp", "AA@TV"))
        #expect(device.services.count == 2)
        #expect(device.services.first { $0.type == "_airplay._tcp" }?.txt["model"] == "AppleTV14,1")
        #expect(device.isBonjourOnly)
        device.merge(DiscoveredHost(address: ip, responseTime: .milliseconds(3), openPorts: [7000]))
        #expect(!device.isBonjourOnly)
    }
}

struct ReverseDNSTests {
    @Test func resolvesLoopbackFromHostsFile() async {
        let name = await ReverseDNSResolver().hostName(for: IPv4(127, 0, 0, 1))
        #expect(name?.hasPrefix("localhost") == true)
    }

    @Test func givesUpWithinTimeout() async {
        let resolver = ReverseDNSResolver(timeout: .milliseconds(300))
        let clock = ContinuousClock()
        // TEST-NET-1: 이름이 없거나 DNS가 답하지 않는다
        let elapsed = await clock.measure {
            _ = await resolver.hostName(for: IPv4(192, 0, 2, 77))
        }
        #expect(elapsed < .seconds(2))
    }

    @Test func cancellationReturnsNil() async {
        let task = Task { await ReverseDNSResolver(timeout: .seconds(30)).hostName(for: IPv4(192, 0, 2, 78)) }
        task.cancel()
        #expect(await task.value == nil)
    }
}
