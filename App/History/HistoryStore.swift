import Foundation
import NagoNetCore
import SwiftData

/// SwiftData로 네트워크별 스캔 기록과 기억하는 기기(별명 포함)를 둔다.
@MainActor
final class HistoryStore: ScanHistoryStoring {
    /// 네트워크마다 남기는 최근 스캔 수(오래된 것부터 지운다)
    static let scansKept = 30

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func baseline(for network: NetworkSnapshot) -> NetworkBaseline {
        guard let record = find(network) else { return .empty }
        return NetworkBaseline(
            knownDevices: record.devices.map { KnownDevice(identity: $0.identity, alias: $0.alias) },
            previousScans: record.scans.count
        )
    }

    func record(_ devices: [Device], new: Set<IPv4>, network: NetworkSnapshot, startedAt: Date, duration: Duration) {
        let now = Date.now
        let networkRecord = findOrCreate(network, date: now)
        let known = networkRecord.devices
        let matches = DeviceMatcher.match(devices.map(\.identity), against: known.map(\.identity))

        let scan = ScanRecord(date: startedAt, duration: duration.milliseconds / 1_000)
        context.insert(scan)
        scan.network = networkRecord
        for (device, match) in zip(devices, matches) {
            let record = match.map { known[$0] } ?? insertDevice(at: device.address, in: networkRecord, date: now)
            record.update(from: device, seenAt: now)
            // 4단계에서 UserDefaults에 붙인 별명은 여기로 옮겨 온다
            if record.alias == nil, let alias = device.alias {
                record.alias = alias
            }
            let entry = ScanEntry(device: device, isNew: new.contains(device.address))
            context.insert(entry)
            entry.scan = scan
        }
        scan.deviceCount = devices.count
        scan.newDeviceCount = new.count
        networkRecord.lastScanned = now
        pruneScans(of: networkRecord)
        save()
    }

    func setAlias(_ alias: String?, for device: Device, network: NetworkSnapshot) {
        let now = Date.now
        let networkRecord = findOrCreate(network, date: now)
        let known = networkRecord.devices
        if let index = DeviceMatcher.match(device.identity, against: known.map(\.identity)) {
            known[index].alias = alias
        } else if alias != nil {
            let record = insertDevice(at: device.address, in: networkRecord, date: now)
            record.hostName = device.identity.hostName
            record.bonjourName = device.identity.bonjourName
            record.name = device.discoveredName
            record.kindRaw = device.kind.rawValue
            record.alias = alias
        }
        save()
    }

    private func find(_ network: NetworkSnapshot) -> NetworkRecord? {
        let all = (try? context.fetch(FetchDescriptor<NetworkRecord>())) ?? []
        guard let index = NetworkIdentity(network).firstMatch(in: all.map(\.identity)) else { return nil }
        let record = all[index]
        // 처음엔 위치 권한이 없어 SSID 없이 기억했다면 이제 채워 둔다
        if record.ssid == nil, let ssid = network.ssid {
            record.ssid = ssid
        }
        return record
    }

    private func findOrCreate(_ network: NetworkSnapshot, date: Date) -> NetworkRecord {
        if let existing = find(network) { return existing }
        let record = NetworkRecord(identity: NetworkIdentity(network), date: date)
        context.insert(record)
        return record
    }

    private func insertDevice(at address: IPv4, in network: NetworkRecord, date: Date) -> DeviceRecord {
        let record = DeviceRecord(address: address, date: date)
        context.insert(record)
        record.network = network
        return record
    }

    private func pruneScans(of network: NetworkRecord) {
        let old = network.scans.sorted { $0.date > $1.date }.dropFirst(Self.scansKept)
        for scan in old {
            context.delete(scan)
        }
    }

    private func save() {
        do {
            try context.save()
        } catch {
            print("스캔 기록 저장 실패: \(error)")
        }
    }
}
