import NagoNetCore
import SwiftUI

/// 메인 화면: 내 네트워크 카드, 큰 스캔 버튼과 진행률, 기기 목록.
struct HomeView: View {
    let network: NetworkViewModel
    @Bindable var scan: ScanViewModel
    let location: LocationPermission
    @Binding var selection: IPv4?

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List(selection: $selection) {
            switch network.phase {
            case .loading:
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("네트워크 정보를 읽는 중…").foregroundStyle(.secondary)
                    }
                }
            case .connected(let snapshot):
                Section {
                    NetworkCard(snapshot: snapshot)
                    WiFiNameAccessRow(location: location, hasName: snapshot.ssid != nil)
                } footer: {
                    NetworkNotes(snapshot: snapshot)
                }
            case .notConnected:
                ContentUnavailableView {
                    Label("Wi-Fi에 연결되어 있지 않아요", systemImage: "wifi.slash")
                } description: {
                    Text("같은 Wi-Fi의 기기를 찾으려면 Wi-Fi에 연결하세요. 연결되면 자동으로 다시 읽어요.")
                }
                .listRowBackground(Color.clear)
            case .failed(let message):
                ContentUnavailableView {
                    Label("네트워크 정보를 읽지 못했어요", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("다시 시도") { Task { await network.refresh() } }
                }
                .listRowBackground(Color.clear)
            }

            if let snapshot = network.snapshot {
                Section {
                    ScanControl(scan: scan, network: snapshot)
                }
                if scan.status == .accessDenied {
                    Section {
                        LocalNetworkDeniedView()
                    }
                }
            }

            if !scan.devices.isEmpty {
                Section {
                    ForEach(scan.sortedDevices) { device in
                        DeviceRow(device: device)
                    }
                } header: {
                    HStack {
                        Text("기기 \(scan.devices.count)대")
                        Spacer()
                        Picker("정렬", selection: $scan.sortOrder) {
                            ForEach(DeviceSort.allCases) { order in
                                Text(order.title).tag(order)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .font(.caption)
                    }
                    .textCase(nil)
                }
            }
        }
        .navigationTitle("NAGO NET")
        .refreshable { await network.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await network.refresh() }
                } label: {
                    Label("새로고침", systemImage: "arrow.clockwise")
                }
                .disabled(network.isRefreshing)
            }
        }
        .task {
            network.startMonitoring()
            await network.refresh()
        }
        // 위치 권한을 막 허용했으면 SSID를 다시 읽는다
        .onChange(of: location.state) {
            Task { await network.refresh() }
        }
        // 다른 Wi-Fi로 옮기면 이전 결과를 지운다
        .onChange(of: network.snapshot?.subnet) {
            scan.networkChanged(to: network.snapshot)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await network.refresh() }
            case .background:
                // 백그라운드에서는 스캔하지 않는다
                scan.cancel()
            default:
                break
            }
        }
    }
}

/// 카드 아래 주의 문구: 게이트웨이 추정, 큰 대역 일부만 스캔, 자동 할당 주소.
private struct NetworkNotes: View {
    let snapshot: NetworkSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if snapshot.isSelfAssigned {
                Label("공유기에서 주소를 받지 못했어요(169.254.x.x 자동 할당). Wi-Fi 연결을 확인하세요.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if snapshot.gateway.isEstimated {
                Label("라우팅 테이블에서 게이트웨이를 찾지 못해 대역의 첫 주소로 추정했어요.", systemImage: "questionmark.circle")
            }
            if snapshot.scanRange.isPartial {
                Label("대역(\(snapshot.subnet.cidr), \(snapshot.subnet.hostCount.formatted())개)이 커서 내 주소가 든 \(snapshot.scanRange.count.formatted())개만 스캔해요.",
                      systemImage: "scissors")
            }
        }
        .font(.footnote)
    }
}
