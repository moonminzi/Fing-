import NagoNetCore
import SwiftData
import SwiftUI

/// 스캔 기록: 네트워크 목록 → 네트워크(스캔·기억하는 기기) → 스캔 한 번의 기기 목록.
struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \NetworkRecord.lastScanned, order: .reverse) private var networks: [NetworkRecord]

    var body: some View {
        NavigationStack {
            List {
                ForEach(networks) { network in
                    NavigationLink {
                        NetworkHistoryView(network: network)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Label(network.title, systemImage: "wifi")
                                .font(.body.weight(.medium))
                            Text("스캔 \(network.scans.count)번 · 기억하는 기기 \(network.devices.count)대 · \(network.lastScanned.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    offsets.map { networks[$0] }.forEach { context.delete($0) }
                    try? context.save()
                }
            }
            .overlay {
                if networks.isEmpty {
                    ContentUnavailableView(
                        "기록이 없어요",
                        systemImage: "clock",
                        description: Text("스캔을 끝까지 마치면 네트워크별로 기록이 남아요.")
                    )
                }
            }
            .navigationTitle("스캔 기록")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }
}

/// 네트워크 하나의 스캔들과 기억하는 기기들.
struct NetworkHistoryView: View {
    let network: NetworkRecord
    @Environment(\.modelContext) private var context

    var body: some View {
        List {
            Section {
                if let ssid = network.ssid {
                    LabeledContent("네트워크 이름", value: ssid)
                }
                LabeledContent("대역", value: network.cidr)
                LabeledContent("게이트웨이", value: network.gateway)
                LabeledContent("처음 스캔", value: network.firstSeen.formatted(date: .abbreviated, time: .shortened))
            }

            Section("스캔 \(network.scans.count)번") {
                ForEach(scans) { scan in
                    NavigationLink {
                        ScanRecordView(scan: scan)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(scan.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.body.weight(.medium))
                                if scan.newDeviceCount > 0 {
                                    TagBadge(text: "새 기기 \(scan.newDeviceCount)", tint: .red)
                                }
                            }
                            Text("기기 \(scan.deviceCount)대 · \(Duration.seconds(scan.duration).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))) 걸림")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    offsets.map { scans[$0] }.forEach { context.delete($0) }
                    try? context.save()
                }
            }

            Section {
                ForEach(devices) { device in
                    HStack(spacing: 12) {
                        KindIcon(kind: device.kind)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.alias ?? device.name ?? device.address)
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                            Text("\(device.address) · \(device.kind.title) · \(device.timesSeen)번 봄")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("처음 \(device.firstSeen.formatted(date: .numeric, time: .omitted))")
                            Text("마지막 \(device.lastSeen.formatted(date: .numeric, time: .omitted))")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("기억하는 기기 \(network.devices.count)대")
            } footer: {
                Text("IP·호스트 이름·Bonjour 이름으로 같은 기기를 알아봐요. 여기 없는 기기가 다음 스캔에 보이면 '새 기기'가 붙어요.")
            }
        }
        .monospacedDigit()
        .navigationTitle(network.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var scans: [ScanRecord] {
        network.scans.sorted { $0.date > $1.date }
    }

    private var devices: [DeviceRecord] {
        network.devices.sorted { $0.lastSeen != $1.lastSeen ? $0.lastSeen > $1.lastSeen : $0.address < $1.address }
    }
}

/// 스캔 한 번에 본 기기들(그때 모습).
struct ScanRecordView: View {
    let scan: ScanRecord

    var body: some View {
        List {
            Section {
                ForEach(entries) { entry in
                    HStack(spacing: 12) {
                        KindIcon(kind: entry.kind)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(entry.isSelf ? "이 기기" : entry.name ?? entry.address)
                                    .font(.body.weight(.medium))
                                    .lineLimit(1)
                                if entry.isNew {
                                    TagBadge(text: "새 기기", tint: .red)
                                }
                            }
                            Text(subtitle(of: entry))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if let time = entry.responseTime {
                            Text(Duration.milliseconds(time).shortDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("기기 \(scan.deviceCount)대 · 새 기기 \(scan.newDeviceCount)대")
            }
        }
        .monospacedDigit()
        .navigationTitle(scan.date.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var entries: [ScanEntry] {
        scan.entries.sorted { (IPv4($0.address)?.value ?? 0) < (IPv4($1.address)?.value ?? 0) }
    }

    private func subtitle(of entry: ScanEntry) -> String {
        var parts = [entry.address]
        if entry.kind != .unknown { parts.append(entry.kind.title) }
        if !entry.openPorts.isEmpty {
            parts.append(entry.openPorts.prefix(4).map(String.init).joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
}

/// 종류 아이콘(기록 화면용, Device 없이 종류만으로)
struct KindIcon: View {
    let kind: DeviceKind

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(kind.tint)
            .frame(width: 32, height: 32)
            .background(kind.tint.opacity(0.15), in: Circle())
            .accessibilityLabel(kind.title)
    }
}
