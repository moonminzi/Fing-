import NagoNetCore
import SwiftUI
import UIKit

/// 큰 스캔 버튼과 진행률. 스캔 중에는 중지 버튼이 된다.
struct ScanControl: View {
    let scan: ScanViewModel
    let network: NetworkSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if scan.isRunning {
                Button(role: .destructive) {
                    scan.cancel()
                } label: {
                    Label("중지", systemImage: "stop.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.large)

                ProgressView(value: scan.progress)
                HStack {
                    Text(runningText)
                    Spacer()
                    Text(scan.progress.formatted(.percent.precision(.fractionLength(0))))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            } else {
                Button {
                    scan.start(on: network)
                } label: {
                    Label(scan.devices.isEmpty ? "스캔 시작" : "다시 스캔", systemImage: "dot.radiowaves.left.and.right")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if let summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var runningText: String {
        switch scan.status {
        case .checkingAccess: "로컬 네트워크 권한 확인 중…"
        case .accessDenied: "로컬 네트워크 권한을 기다리는 중…"
        case _ where scan.isNaming: "기기 이름 찾는 중… · 기기 \(scan.devices.count)대"
        default: "\(network.scanRange.count.formatted())개 주소 스캔 중 · 기기 \(scan.devices.count)대"
        }
    }

    private var summary: String? {
        switch scan.status {
        case .finished(let date, let duration):
            let took = duration.formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
            return "기기 \(scan.devices.count)대 · \(took) 걸림 · \(date.formatted(date: .omitted, time: .shortened))"
        case .cancelled:
            return "중지됨 · 그때까지 찾은 기기 \(scan.devices.count)대"
        default:
            return nil
        }
    }
}

/// 로컬 네트워크 권한이 없을 때: 설정 앱으로 안내한다. 허용되면 스캔이 저절로 이어진다.
struct LocalNetworkDeniedView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("로컬 네트워크 권한이 필요해요", systemImage: "lock.shield")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("같은 Wi-Fi의 기기를 찾으려면 로컬 네트워크 접근을 허용해야 해요. 설정에서 NAGO NET의 **로컬 네트워크**를 켜면 스캔이 자동으로 이어져요.")
                .font(.subheadline)
            Text("설정 → 개인정보 보호 및 보안 → 로컬 네트워크에서도 바꿀 수 있어요.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                Label("설정 열기", systemImage: "gear")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 6)
    }
}

/// 목록 한 줄: 종류 아이콘, 이름(없으면 IP), IP·서비스나 열린 포트, 응답 시간.
struct DeviceRow: View {
    let device: Device

    var body: some View {
        HStack(spacing: 12) {
            DeviceIcon(device: device)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name ?? device.address.description)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if device.isGateway, device.name != "공유기" {
                        TagBadge(text: "공유기", tint: .green)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let time = device.responseTime {
                Text(time.shortDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if device.isBonjourOnly {
                Text("Bonjour")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
    }

    private var subtitle: String {
        var parts: [String] = []
        if device.name != nil { parts.append(device.address.description) }
        let serviceTitles = device.services.map(\.typeTitle).uniqued()
        if !serviceTitles.isEmpty {
            parts += serviceTitles.prefix(2)
        } else if !device.openPorts.isEmpty {
            parts += device.openPorts.prefix(3).map { KnownPorts.name(for: $0) ?? "\($0)" }
        } else if !device.isSelf, device.name == nil {
            parts.append("응답함 · 열린 포트 없음")
        }
        return parts.joined(separator: " · ")
    }
}

private extension Array where Element: Hashable {
    /// 순서를 지키며 겹치는 것 빼기
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

struct DeviceIcon: View {
    let device: Device

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(tint.opacity(0.15), in: Circle())
            .accessibilityHidden(true)
    }

    private var symbol: String {
        if device.isSelf { return UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }
        if device.isGateway { return "wifi.router" }
        return "questionmark"
    }

    private var tint: Color {
        if device.isSelf { return .blue }
        if device.isGateway { return .green }
        return .gray
    }
}

/// 기기 상세: 주소·이름·Bonjour 서비스·열린 포트(종류 추정과 포트 스캔은 다음 단계).
struct DeviceDetailView: View {
    let device: Device

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    DeviceIcon(device: device)
                    Text(device.name ?? device.address.description)
                        .font(.title3.weight(.semibold))
                }
                LabeledContent("IP 주소", value: device.address.description)
                if device.isBonjourOnly {
                    LabeledContent("응답 시간", value: "TCP 응답 없음(Bonjour로 찾음)")
                } else {
                    LabeledContent("응답 시간", value: device.responseTime?.shortDescription ?? "—")
                }
                if device.isGateway {
                    LabeledContent("역할", value: "공유기(게이트웨이)")
                }
            }

            Section {
                LabeledContent("Bonjour 이름", value: device.bonjourName ?? "없음")
                LabeledContent("mDNS 호스트 이름", value: device.mdnsName ?? "없음")
                LabeledContent("NetBIOS 이름", value: device.netbiosName ?? "없음")
                LabeledContent("DNS 이름(공유기)", value: device.hostName ?? "없음")
            } header: {
                Text("이름")
            } footer: {
                if device.needsNames {
                    Text("Bonjour 광고도, 직접 물어본 mDNS·NetBIOS 답도, 공유기 DNS 이름도 없는 기기예요. 안드로이드 폰이나 IoT 기기가 흔히 그래요.")
                }
            }

            if !device.services.isEmpty {
                Section("Bonjour 서비스") {
                    ForEach(device.services, id: \.self) { service in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(service.typeTitle).font(.subheadline.weight(.semibold))
                                Spacer()
                                if let port = service.port {
                                    Text("포트 \(String(port))").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(service.name).font(.subheadline)
                            Text(service.type).font(.caption).foregroundStyle(.secondary)
                            if let model = service.txt["model"] ?? service.txt["md"] ?? service.txt["am"] ?? service.txt["ty"] {
                                Text("모델: \(model)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if !device.isSelf {
                Section {
                    if device.openPorts.isEmpty {
                        Text(device.isBonjourOnly
                             ? "TCP 탐색 포트에는 답하지 않았어요."
                             : "열린 포트가 없지만 연결 거부(RST)로 응답해서 기기가 있는 걸 알았어요.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(device.openPorts, id: \.self) { port in
                            LabeledContent(String(port), value: KnownPorts.name(for: port) ?? "")
                        }
                    }
                } header: {
                    Text("열린 포트")
                } footer: {
                    Text("기기를 찾을 때 확인한 포트 \(ScanConfiguration.discoveryPorts.count)개 기준이에요.")
                }
            }
        }
        .monospacedDigit()
        .textSelection(.enabled)
        .navigationTitle(device.name ?? device.address.description)
        .navigationBarTitleDisplayMode(.inline)
    }
}
