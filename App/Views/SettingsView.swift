import SwiftUI

/// 설정: 공유기 SNMP(ARP 표로 MAC 읽기)와 백그라운드 새 기기 알림.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.snmpEnabledKey) private var snmpEnabled = true
    @AppStorage(AppSettings.snmpCommunityKey) private var snmpCommunity = "public"
    @AppStorage(AppSettings.dhcpSniffKey) private var dhcpSniff = true
    @AppStorage(AppSettings.backgroundCheckKey) private var backgroundCheck = false
    @State private var notificationsDenied = false
    @State private var advertiser = BonjourAdvertiser()
    @State private var spoofName = "거실 TV"
    @State private var spoofTypeIndex = 0
    @State private var confirmingSpoof = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("SNMP로 MAC 묻기(공유기·기기)", isOn: $snmpEnabled)
                    if snmpEnabled {
                        LabeledContent("커뮤니티 문자열") {
                            TextField("public", text: $snmpCommunity)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                    Toggle("DHCP 스니핑", isOn: $dhcpSniff)
                } header: {
                    Text("MAC 주소")
                } footer: {
                    Text("iOS는 다른 기기의 MAC을 지워서 주기 때문에, 기기가 스스로 공개한 MAC을 모아요: NetBIOS(윈도우)·AirPlay·Time Machine·워크스테이션 광고, UPnP·프린터 기기 ID, IPv6 주소(EUI-64), Roku·삼성 TV·Hue·Shelly 정보 API. 이 스위치를 켜면 SNMP가 켜진 공유기·AP에 ARP 표를, 프린터·NAS 같은 기기에는 자기 인터페이스 MAC을 물어봐요(UDP 161, 읽기만). 커뮤니티 문자열은 관리자가 정한 값이에요(보통 public). 휴대폰은 Wi-Fi마다 무작위 MAC을 써서 제조사가 안 나와요.\n\nDHCP 스니핑: 앱이 떠 있는 동안 :67·:68 포트로 오는 DHCP 요청을 엿들어요. 기기가 Wi-Fi에 새로 붙거나 임대를 갱신하는 순간 자기 MAC(chaddr)을 브로드캐스트하는데, 그걸 공유기·비번 없이 바로 잡아 그 기기에 붙여요(출처 'DHCP 요청'). 공유기 ARP·IPv6 이웃 캐시가 다 가려도 이 길은 통해요. 기기가 붙거나 갱신할 때만 잡히니, 폰의 Wi-Fi(또는 비행기모드)를 껐다 켜면 그 순간 잡혀요.")
                }

                Section {
                    Toggle("새 기기 알림", isOn: $backgroundCheck)
                        .onChange(of: backgroundCheck) { _, isOn in
                            guard isOn else {
                                BackgroundCheck.schedule()
                                return
                            }
                            Task {
                                let allowed = await BackgroundCheck.requestNotificationPermission()
                                notificationsDenied = !allowed
                                if allowed {
                                    BackgroundCheck.schedule()
                                } else {
                                    backgroundCheck = false
                                }
                            }
                        }
                    if notificationsDenied {
                        Text("알림이 꺼져 있어요. 설정 앱 → NAGO NET → 알림에서 켜 주세요.")
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("백그라운드")
                } footer: {
                    Text("앱이 꺼져 있을 때 iOS가 정한 때(보통 몇 시간에 한 번, 충전 중이거나 자주 쓰는 시간에 더 자주) 30초쯤 깨워 줘요. 그때 Wi-Fi를 빠르게 훑어 기록에 없는 기기가 보이면 알려요. 실시간 감시는 iOS에서 할 수 없어요. 앱에서 스캔하다 나가면 30초 동안은 마저 스캔해요.")
                }

                bonjourSpoofSection
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }

    /// 보안 실험: 가짜 Bonjour 서비스를 광고해 유인 + 접속자 기록(iOS에서 실제로 동작, entitlement 불필요).
    @ViewBuilder private var bonjourSpoofSection: some View {
        Section {
            if case .advertising(let name, let type) = advertiser.state {
                LabeledContent("광고 중", value: "\(name)")
                Text(type).font(.caption).foregroundStyle(.secondary)
                Button("중지", role: .destructive) { advertiser.stop() }
                if advertiser.hits.isEmpty {
                    Text("아직 접속한 기기 없음 — 다른 기기에서 이 서비스가 보이는지 확인하세요.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(advertiser.hits, id: \.self) { hit in
                        Label(hit, systemImage: "dot.radiowaves.left.and.right").font(.caption)
                    }
                }
            } else {
                Picker("서비스 종류", selection: $spoofTypeIndex) {
                    ForEach(Array(BonjourAdvertiser.advertisableTypes.enumerated()), id: \.offset) { index, item in
                        Text(item.label).tag(index)
                    }
                }
                LabeledContent("이름") {
                    TextField("거실 TV", text: $spoofName)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                }
                Button("가짜 서비스 광고 시작") { confirmingSpoof = true }
                if case .failed(let message) = advertiser.state {
                    Text("실패: \(message)").font(.caption).foregroundStyle(.orange)
                }
            }
        } header: {
            Text("보안 실험: 가짜 Bonjour 서비스 광고")
        } footer: {
            Text("인가받은 자기 네트워크·CTF에서만 쓰세요. 선택한 종류의 가짜 Bonjour 서비스를 네트워크에 광고해 다른 기기 목록에 뜨게 하고(유인), 접속해 온 기기의 주소를 기록해요(허니팟). 로컬 네트워크 권한만으로 iOS에서 실제로 동작해요(멀티캐스트 entitlement 불필요). 접속 사실만 보고 자격증명은 수집하지 않아요. 앱을 끄거나 '중지'하면 사라져요.")
        }
        .confirmationDialog("인가된 자기 네트워크인가요?", isPresented: $confirmingSpoof, titleVisibility: .visible) {
            Button("광고 시작", role: .destructive) {
                let type = BonjourAdvertiser.advertisableTypes[spoofTypeIndex].type
                advertiser.start(name: spoofName.isEmpty ? "거실 TV" : spoofName, type: type)
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("네트워크에 가짜 서비스를 띄웁니다. 소유·관리하는 네트워크에서만 실행하세요.")
        }
    }
}
