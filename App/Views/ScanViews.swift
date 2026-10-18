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

/// 목록 한 줄: 종류 아이콘, 이름(없으면 IP), IP·종류·서비스나 열린 포트, 응답 시간.
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
        if device.isSelf, let bonjourName = device.bonjourName {
            parts.append(bonjourName)
            return parts.joined(separator: " · ")
        }
        let kind = device.kind
        if kind != .unknown { parts.append(kind.title) }
        let serviceTitles = device.services.map(\.typeTitle).uniqued()
        if !serviceTitles.isEmpty {
            parts += serviceTitles.prefix(2)
        } else if !device.openPorts.isEmpty {
            parts += device.allOpenPorts.prefix(3).map { KnownPorts.name(for: $0) ?? "\($0)" }
        } else if device.name == nil, kind == .unknown {
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

extension DeviceKind {
    var symbol: String {
        switch self {
        case .router: "wifi.router"
        case .iPhone: "iphone"
        case .phone: "iphone.gen2"
        case .tablet: "ipad"
        case .mac: "laptopcomputer"
        case .computer: "desktopcomputer"
        case .tv: "tv"
        case .speaker: "hifispeaker"
        case .printer: "printer"
        case .nas: "externaldrive"
        case .unknown: "questionmark"
        }
    }

    var tint: Color {
        switch self {
        case .router: .green
        case .iPhone: .blue
        case .phone: .teal
        case .tablet: .indigo
        case .mac: .cyan
        case .computer: .mint
        case .tv: .purple
        case .speaker: .pink
        case .printer: .orange
        case .nas: .brown
        case .unknown: .gray
        }
    }
}

struct DeviceIcon: View {
    let device: Device
    var size: CGFloat = 36

    var body: some View {
        let kind = device.kind
        Image(systemName: kind.symbol)
            .font(.system(size: size * 0.47, weight: .semibold))
            .foregroundStyle(kind.tint)
            .frame(width: size, height: size)
            .background(kind.tint.opacity(0.15), in: Circle())
            .overlay(alignment: .bottomTrailing) {
                if device.isSelf {
                    Circle()
                        .fill(.blue)
                        .frame(width: size * 0.3, height: size * 0.3)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                }
            }
            .accessibilityLabel(kind.title)
    }
}

/// 기기 상세: 종류와 근거, 별명, 이름 출처, 기기 정보(모델·배너), Bonjour 서비스, 포트 스캔.
struct DeviceDetailView: View {
    let device: Device
    let scan: ScanViewModel

    @State private var isEditingAlias = false
    @State private var aliasDraft = ""

    var body: some View {
        let classification = device.classification
        List {
            Section {
                HStack(spacing: 14) {
                    DeviceIcon(device: device, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.name ?? device.address.description)
                            .font(.title3.weight(.semibold))
                        Text(verbatim: classification.kind == .unknown ? "종류를 알 수 없음" : "\(classification.kind.title)(추정)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                Button {
                    aliasDraft = device.alias ?? ""
                    isEditingAlias = true
                } label: {
                    Label(device.alias == nil ? "별명 붙이기" : "별명 바꾸기", systemImage: "pencil")
                }
            }

            Section("기본 정보") {
                LabeledContent("IP 주소", value: device.address.description)
                if device.isBonjourOnly {
                    LabeledContent("응답 시간", value: "TCP 응답 없음(Bonjour로 찾음)")
                } else {
                    LabeledContent("응답 시간", value: device.responseTime?.shortDescription ?? "—")
                }
                if device.isGateway {
                    LabeledContent("역할", value: "공유기(게이트웨이)")
                }
                if let alias = device.alias {
                    LabeledContent("별명", value: alias)
                    LabeledContent("찾은 이름", value: device.discoveredName ?? "없음")
                }
            }

            Section {
                if classification.reasons.isEmpty {
                    Text("단서가 없어요. 아래 포트 스캔을 하면 더 알 수 있을지도 몰라요.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(classification.reasons, id: \.self) { reason in
                        Label(reason, systemImage: "checkmark.circle")
                    }
                }
            } header: {
                Text("종류 추정 근거")
            } footer: {
                Text("iOS에서는 다른 기기의 MAC 주소(제조사)를 읽을 수 없어서 이름·서비스·열린 포트·배너로 짐작해요.")
            }

            Section {
                LabeledContent("Bonjour 이름", value: device.bonjourName ?? "없음")
                LabeledContent("mDNS 호스트 이름", value: device.mdnsName ?? "없음")
                LabeledContent("NetBIOS 이름", value: device.netbiosName ?? "없음")
                LabeledContent("DNS 이름(공유기)", value: device.hostName ?? "없음")
            } header: {
                Text("이름")
            } footer: {
                if device.needsNames && device.productName == nil {
                    Text("Bonjour 광고도, 직접 물어본 mDNS·NetBIOS 답도, 공유기 DNS 이름도 없는 기기예요. 안드로이드 폰이나 IoT 기기가 흔히 그래요. 별명을 붙여 두면 다음 스캔에도 그 이름으로 보여요.")
                }
            }

            if device.model != nil || !device.banners.isEmpty {
                Section("기기 정보") {
                    if let model = device.model {
                        LabeledContent("모델", value: model)
                    }
                    ForEach(device.banners, id: \.port) { banner in
                        BannerRows(banner: banner)
                    }
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
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if !device.isSelf {
                PortsSection(device: device, scan: scan)
            }
        }
        .monospacedDigit()
        .textSelection(.enabled)
        .navigationTitle(device.name ?? device.address.description)
        .navigationBarTitleDisplayMode(.inline)
        .alert("별명", isPresented: $isEditingAlias) {
            TextField(device.discoveredName ?? device.address.description, text: $aliasDraft)
            Button("저장") { scan.setAlias(aliasDraft, for: device.address) }
            if device.alias != nil {
                Button("별명 지우기", role: .destructive) { scan.setAlias(nil, for: device.address) }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("목록과 상세에 이 이름으로 보이고, 다음 스캔에서도 같은 기기에 붙어요.")
        }
    }
}

private struct BannerRows: View {
    let banner: ServiceBanner

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("포트 \(String(banner.port)) · \(KnownPorts.name(for: banner.port) ?? "")")
                .font(.subheadline.weight(.semibold))
            ForEach(lines, id: \.label) { line in
                HStack(alignment: .firstTextBaseline) {
                    Text(line.label).foregroundStyle(.secondary)
                    Spacer()
                    Text(line.value).multilineTextAlignment(.trailing)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private struct Line {
        let label: String
        let value: String
    }

    private var lines: [Line] {
        let candidates: [(String, String?)] = [
            ("웹 페이지 제목", banner.title), ("인증 영역", banner.realm), ("인증서", banner.certificate),
            ("서버", banner.server), ("SSH", banner.ssh),
        ]
        return candidates.compactMap { candidate in candidate.1.map { Line(label: candidate.0, value: $0) } }
    }
}

/// 열린 포트 목록과 "주요 포트 100개 스캔" 버튼.
private struct PortsSection: View {
    let device: Device
    let scan: ScanViewModel

    var body: some View {
        let state = scan.portScans[device.address]
        Section {
            if let state, state.isRunning {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("주요 포트 \(KnownPorts.common.count)개 확인 중…")
                        Spacer()
                        Button("중지", role: .destructive) { scan.cancelPortScan(of: device.address) }
                            .buttonStyle(.borderless)
                    }
                    ProgressView(value: state.progress)
                    Text("\(state.progress.formatted(.percent.precision(.fractionLength(0)))) · 열린 포트 \(state.found.count)개")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    scan.scanPorts(of: device.address)
                } label: {
                    Label(device.scannedPorts == nil ? "포트 스캔(주요 \(KnownPorts.common.count)개)" : "포트 다시 스캔",
                          systemImage: "magnifyingglass")
                }
            }
            if state?.isDenied == true {
                Text("로컬 네트워크 권한이 없어 포트를 확인하지 못했어요.")
                    .foregroundStyle(.orange)
            }

            let ports = state?.isRunning == true ? Array(Set(device.allOpenPorts + (state?.found ?? []))).sorted() : device.allOpenPorts
            if ports.isEmpty {
                Text(device.isBonjourOnly ? "TCP로 확인한 열린 포트가 없어요." : "열린 포트가 없어요(연결 거부로 응답해 기기가 있는 걸 알았어요).")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ports, id: \.self) { port in
                    LabeledContent(String(port), value: KnownPorts.name(for: port) ?? "")
                }
            }
        } header: {
            Text("열린 포트")
        } footer: {
            if let scanned = device.scannedPorts {
                Text("주요 포트 \(KnownPorts.common.count)개를 확인했어요. 열린 포트 \(scanned.count)개.")
            } else {
                Text("지금은 기기를 찾을 때 확인한 포트 \(ScanConfiguration.discoveryPorts.count)개 기준이에요.")
            }
        }
    }
}
