import Charts
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
            var text = "기기 \(scan.devices.count)대 · \(took) 걸림 · \(date.formatted(date: .omitted, time: .shortened))"
            if let routerTable = scan.routerTableStatus {
                text += "\n" + routerTable
            }
            if scan.isFirstScanOfNetwork {
                text += "\n이 네트워크의 첫 기록이에요. 다음 스캔부터 처음 보는 기기에 '새 기기'가 붙어요."
            } else if scan.newDeviceCount > 0 {
                text += " · 새 기기 \(scan.newDeviceCount)대"
            }
            return text
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
    var isNew = false

    var body: some View {
        HStack(spacing: 12) {
            DeviceIcon(device: device)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name ?? device.address.description)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if isNew {
                        TagBadge(text: "새 기기", tint: .red)
                    }
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
        } else if device.seenOnlyInRouterTable {
            parts.append("공유기 기록에만 있음")
        } else if device.isPingOnly {
            parts.append("핑에만 응답")
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
    /// iPad에서 레이더로 돌아가기(없으면 버튼을 숨긴다)
    var onShowRadar: (@MainActor () -> Void)?

    @Environment(\.horizontalSizeClass) private var sizeClass

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

            if let mac = device.mac {
                Section {
                    LabeledContent("MAC 주소", value: mac.address.description)
                    LabeledContent("제조사", value: device.macVendor ?? (mac.address.isRandomized ? "무작위 주소" : "모름"))
                    LabeledContent("알게 된 곳", value: mac.source.rawValue)
                } header: {
                    Text("MAC")
                } footer: {
                    if mac.address.isRandomized {
                        Text("휴대폰·태블릿이 Wi-Fi마다 바꿔 쓰는 비공개 주소라 제조사를 알 수 없어요.")
                    }
                }
            }

            if let upnp = device.upnp {
                Section("UPnP(SSDP)") {
                    if let friendlyName = upnp.friendlyName {
                        LabeledContent("이름", value: friendlyName)
                    }
                    if let manufacturer = upnp.manufacturer {
                        LabeledContent("제조사", value: manufacturer)
                    }
                    if let model = upnp.modelName ?? upnp.modelNumber {
                        LabeledContent("모델", value: model)
                    }
                    if let type = upnp.shortType {
                        LabeledContent("종류", value: type)
                    }
                    if let server = upnp.server {
                        LabeledContent("서버", value: server)
                    }
                }
            }

            if device.mac != nil {
                WakeSection(device: device, scan: scan)
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
                WebPagesSection(device: device)
                PingSection(device: device, pinger: scan.pinger)
                PortsSection(device: device, scan: scan)
            }
        }
        .monospacedDigit()
        .textSelection(.enabled)
        .navigationTitle(device.name ?? device.address.description)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onShowRadar, sizeClass == .regular {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onShowRadar()
                    } label: {
                        Label("레이더", systemImage: "dot.radiowaves.left.and.right")
                    }
                }
            }
        }
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
            ("리디렉션", banner.redirect), ("서버", banner.server), ("SSH", banner.ssh),
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

/// 웹 포트가 열린 기기의 관리 페이지를 사파리로 연다(자체 서명 인증서면 사파리가 경고한다).
private struct WebPagesSection: View {
    let device: Device

    var body: some View {
        let pages = device.allOpenPorts.compactMap(url(for:))
        if !pages.isEmpty {
            Section {
                ForEach(pages, id: \.self) { url in
                    Link(destination: url) {
                        Label(url.absoluteString, systemImage: "safari")
                    }
                }
            } header: {
                Text("웹 관리 페이지")
            } footer: {
                Text("공유기·프린터·NAS의 설정 화면이 열려요. HTTPS는 자체 서명 인증서라 사파리가 경고할 수 있어요.")
            }
        }
    }

    private func url(for port: UInt16) -> URL? {
        let scheme: String
        if BannerPorts.https.contains(port) {
            scheme = "https"
        } else if BannerPorts.http.contains(port) {
            scheme = "http"
        } else {
            return nil
        }
        let isDefault = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
        return URL(string: "\(scheme)://\(device.address)\(isDefault ? "" : ":\(port)")/")
    }
}

/// 핑(ICMP) 10번: 응답 시간 막대, 최소·평균·최대·흔들림·손실.
private struct PingSection: View {
    let device: Device
    let pinger: any Pinging

    @State private var session = PingSession()

    var body: some View {
        Section {
            if session.isRunning {
                HStack {
                    ProgressView()
                    Text("핑 보내는 중… \(session.samples.count)/\(PingSession.count)")
                    Spacer()
                    Button("중지", role: .destructive) { session.stop() }
                        .buttonStyle(.borderless)
                }
            } else {
                Button {
                    session.start(device.address, pinger: pinger)
                } label: {
                    Label(session.samples.isEmpty ? "핑 \(PingSession.count)번 보내기" : "다시 핑", systemImage: "waveform.path.ecg")
                }
            }

            if !session.samples.isEmpty {
                PingChart(samples: session.samples)
                    .frame(height: 110)
                    .padding(.vertical, 4)
                let stats = session.statistics
                LabeledContent("받음", value: "\(stats.received)/\(stats.sent) · 손실 \(stats.lossRate.formatted(.percent.precision(.fractionLength(0))))")
                if let minimum = stats.minimum, let average = stats.average, let maximum = stats.maximum {
                    LabeledContent("최소 / 평균 / 최대",
                                   value: "\(minimum.shortDescription) / \(average.shortDescription) / \(maximum.shortDescription)")
                }
                if let jitter = stats.jitter {
                    LabeledContent("흔들림(지터)", value: jitter.shortDescription)
                }
            }
        } header: {
            Text("핑(ICMP)")
        } footer: {
            Text("응답이 없으면 기기가 잠들었거나 방화벽이 핑을 막는 거예요. iPhone은 화면이 꺼지면 늦게 답하기도 해요.")
        }
        .onDisappear { session.stop() }
    }
}

private struct PingChart: View {
    let samples: [PingSession.Sample]

    var body: some View {
        Chart(samples) { sample in
            if let time = sample.time {
                BarMark(x: .value("순번", Double(sample.sequence)), y: .value("ms", time.milliseconds))
                    .foregroundStyle(.tint)
            } else {
                // 답이 없던 핑은 바닥에 빨간 점
                PointMark(x: .value("순번", Double(sample.sequence)), y: .value("ms", 0.0))
                    .foregroundStyle(.red)
                    .symbol(.cross)
            }
        }
        .chartXScale(domain: 0.5...(Double(PingSession.count) + 0.5))
        .chartXAxis(.hidden)
        .chartYAxisLabel("ms")
    }
}

/// 상세의 "제어": Wake-on-LAN으로 기기를 깨운다.
private struct WakeSection: View {
    let device: Device
    let scan: ScanViewModel

    @State private var isSending = false
    @State private var result: Bool?

    var body: some View {
        Section {
            Button {
                Task {
                    isSending = true
                    result = await scan.wake(device)
                    isSending = false
                }
            } label: {
                HStack {
                    Label("깨우기 (Wake on LAN)", systemImage: "power")
                    Spacer()
                    if isSending { ProgressView() }
                }
            }
            .disabled(isSending)
            if let result {
                Text(result ? "매직 패킷을 보냈어요. 기기가 잠자기였거나 공유기가 IP를 기억하면 깨어나요."
                             : "보내지 못했어요.")
                    .font(.caption)
                    .foregroundStyle(result ? Color.secondary : Color.orange)
            }
        } header: {
            Text("제어")
        } footer: {
            Text("꺼진 기기를 깨우려면 그 기기에서 Wake-on-LAN을 켜 두어야 해요. 완전히 꺼진 기기는 iOS 제약(브로드캐스트)으로 못 깨울 수 있어요.")
        }
    }
}
