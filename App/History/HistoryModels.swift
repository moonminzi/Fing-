import Foundation
import NagoNetCore
import SwiftData

/// 네트워크 하나. SSID가 있으면 SSID로, 없으면 대역 + 게이트웨이로 알아본다(`NetworkIdentity`).
@Model
final class NetworkRecord {
    var ssid: String?
    var cidr: String
    var gateway: String
    var firstSeen: Date
    var lastScanned: Date
    @Relationship(deleteRule: .cascade, inverse: \DeviceRecord.network)
    var devices: [DeviceRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \ScanRecord.network)
    var scans: [ScanRecord] = []

    init(identity: NetworkIdentity, date: Date) {
        ssid = identity.ssid
        cidr = identity.cidr
        gateway = identity.gateway.description
        firstSeen = date
        lastScanned = date
    }

    var identity: NetworkIdentity {
        NetworkIdentity(ssid: ssid, cidr: cidr, gateway: IPv4(gateway) ?? IPv4(0))
    }

    var title: String { identity.title }
}

/// 이 네트워크에서 본 적 있는 기기. IP·호스트 이름·Bonjour 이름으로 다음 스캔의 기기와 짝짓는다(`DeviceMatcher`).
@Model
final class DeviceRecord {
    var network: NetworkRecord?
    /// 마지막으로 본 IP
    var address: String
    var hostName: String?
    var bonjourName: String?
    var alias: String?
    /// 마지막 스캔 때 찾은 이름(별명 빼고)
    var name: String?
    var kindRaw: String
    var firstSeen: Date
    var lastSeen: Date
    var timesSeen: Int

    init(address: IPv4, date: Date) {
        self.address = address.description
        kindRaw = DeviceKind.unknown.rawValue
        firstSeen = date
        lastSeen = date
        timesSeen = 0
    }

    var identity: DeviceIdentity {
        DeviceIdentity(address: IPv4(address) ?? IPv4(0), hostName: hostName, bonjourName: bonjourName)
    }

    var kind: DeviceKind { DeviceKind(rawValue: kindRaw) ?? .unknown }

    /// 이번 스캔에서 본 모습으로 고친다. 이번에 못 찾은 이름은 이전 값을 지킨다.
    func update(from device: Device, seenAt date: Date) {
        address = device.address.description
        hostName = device.identity.hostName ?? hostName
        bonjourName = device.identity.bonjourName ?? bonjourName
        name = device.discoveredName ?? name
        if device.kind != .unknown || kind == .unknown {
            kindRaw = device.kind.rawValue
        }
        lastSeen = date
        timesSeen += 1
    }
}

/// 끝까지 마친 스캔 한 번.
@Model
final class ScanRecord {
    var network: NetworkRecord?
    var date: Date
    /// 걸린 시간(초)
    var duration: Double
    var deviceCount: Int
    var newDeviceCount: Int
    @Relationship(deleteRule: .cascade, inverse: \ScanEntry.scan)
    var entries: [ScanEntry] = []

    init(date: Date, duration: Double) {
        self.date = date
        self.duration = duration
        deviceCount = 0
        newDeviceCount = 0
    }
}

/// 그 스캔에서 본 기기 하나(그때 모습 그대로).
@Model
final class ScanEntry {
    var scan: ScanRecord?
    var address: String
    var name: String?
    var kindRaw: String
    /// 응답 시간(ms)
    var responseTime: Double?
    var openPorts: [Int]
    var isNew: Bool
    var isSelf: Bool

    init(device: Device, isNew: Bool) {
        address = device.address.description
        name = device.name
        kindRaw = device.kind.rawValue
        responseTime = device.responseTime?.milliseconds
        openPorts = device.allOpenPorts.map(Int.init)
        self.isNew = isNew
        isSelf = device.isSelf
    }

    var kind: DeviceKind { DeviceKind(rawValue: kindRaw) ?? .unknown }
}
