import SwiftUI

/// 설정: 공유기 SNMP(ARP 표로 MAC 읽기)와 백그라운드 새 기기 알림.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.snmpEnabledKey) private var snmpEnabled = true
    @AppStorage(AppSettings.snmpCommunityKey) private var snmpCommunity = "public"
    @AppStorage(AppSettings.backgroundCheckKey) private var backgroundCheck = false
    @State private var notificationsDenied = false

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
                } header: {
                    Text("MAC 주소")
                } footer: {
                    Text("iOS는 다른 기기의 MAC을 지워서 주기 때문에, 기기가 스스로 공개한 MAC을 모아요: NetBIOS(윈도우)·AirPlay·Time Machine·워크스테이션 광고, UPnP·프린터 기기 ID, IPv6 주소(EUI-64), Roku·삼성 TV·Hue·Shelly 정보 API. 이 스위치를 켜면 SNMP가 켜진 공유기·AP에 ARP 표를, 프린터·NAS 같은 기기에는 자기 인터페이스 MAC을 물어봐요(UDP 161, 읽기만). 커뮤니티 문자열은 관리자가 정한 값이에요(보통 public). 휴대폰은 Wi-Fi마다 무작위 MAC을 써서 제조사가 안 나와요.")
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
}
