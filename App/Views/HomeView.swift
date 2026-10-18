import NagoNetCore
import SwiftUI

/// 메인 화면: 내 네트워크 카드(다음 단계에서 스캔 버튼·기기 목록이 아래에 붙는다).
struct HomeView: View {
    let network: NetworkViewModel
    let location: LocationPermission

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await network.refresh() } }
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
