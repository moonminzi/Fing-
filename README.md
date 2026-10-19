# NAGO NET (iOS·iPadOS)

같은 Wi-Fi에 연결된 기기를 찾아 이름·종류·열린 포트를 보여 주는 네트워크 스캐너(Fing 같은 앱).
Swift 6 · SwiftUI · Swift Concurrency · Network 프레임워크 · SwiftData, 외부 라이브러리 없음. iOS 17 이상, iPhone·iPad(iPad는 두 칸 화면).

## 진행 단계

| 단계 | 내용 | 상태 |
| --- | --- | --- |
| 1 | 내 네트워크 정보(SSID·내 IP·서브넷·게이트웨이)와 스캔 대역 계산 | ✅ |
| 2 | TCP 연결로 기기 탐색, 진행률·취소, 기기 목록, 로컬 네트워크 권한 거부 안내 | ✅ |
| 3 | Bonjour(NWBrowser)와 역방향 DNS로 기기 이름 찾기 | ✅ |
| 4 | 기기 종류 추정, 상세 화면, 포트 100개 스캔, 별명 | ✅ |
| 5 | SwiftData로 네트워크별 기록, "새 기기" 배지 | ✅ |
| + | 네트워크 레이더, 핑(ICMP) 도구·핑으로 찾기, 웹 관리 페이지 열기, CSV 내보내기, 앱 아이콘 | ✅ |
| + | SSDP 유니캐스트(UPnP), MAC 주소·제조사(NetBIOS·AirPlay·공유기 SNMP), 백그라운드 마무리·새 기기 알림 | ✅ |
| + | 기기 깨우기(Wake-on-LAN) — 상세·기록에서 매직 패킷 보내기 | ✅ |

## 구조

```
Core/                       NagoNetCore: UI·Network 프레임워크 없음 → 리눅스/맥에서 swift test
  IPv4.swift                IPv4 주소(파싱·출력·순서·범위)
  Subnet.swift              대역 계산, 스캔 범위(최대 1024개)
  Interfaces.swift          getifaddrs로 인터페이스 주소·넷마스크 읽기
  RouteTable.swift          sysctl(NET_RT_FLAGS) 라우팅 테이블 파싱, 게이트웨이 고르기
  NetworkSnapshot.swift     위 셋을 묶은 "지금 내 네트워크" + NetworkInfoProviding 프로토콜
  Scanner.swift             ScannerService(actor): 두 번 훑는 TCP 탐색, HostProbing·NetworkScanning 프로토콜
  Device.swift              목록의 기기, 정렬, 스캔할 주소 목록
  LocalNetworkAccess.swift  로컬 네트워크 권한 확인 프로토콜
  Bonjour.swift             Bonjour 서비스·이름 고르기·호스트 이름 다듬기, BonjourBrowsing·HostNameResolving 프로토콜
  ReverseDNS.swift          getnameinfo 역방향 DNS(시간 제한·취소)
  DNSMessage.swift          DNS 메시지 만들기·읽기(압축 포인터), NetBIOS 이름 상태 질의
  NameResolver.swift        기기별 이름 조회: 역방향 DNS + mDNS 유니캐스트(+ TXT·_device-info 모델) + NetBIOS
  ServiceBanner.swift       HTTP 머리·제목·인증 영역, HTTPS 인증서, SSH 첫 줄 해석, BannerGrabbing 프로토콜
  DeviceClassifier.swift    DeviceKind, 점수로 종류 추정(DeviceClassifying 프로토콜)
  PortScanner.swift         주요 포트 100개 스캔(PortScanning 프로토콜)
  KnownPorts.swift          포트 100개와 서비스 이름
  History.swift             NetworkIdentity, DeviceMatcher(같은 기기 찾기), NetworkBaseline("새 기기"),
                            ScanHistoryStoring 프로토콜
  ICMP.swift                SOCK_DGRAM ICMP 핑(Pinging 프로토콜), 에코 메시지·체크섬, 핑 통계
  MAC.swift                 MAC 주소(무작위 주소 판별), OUI 제조사 표
  SSDP.swift                SSDP 유니캐스트 검색·UPnP 설명 XML 해석, HTTPFetching 프로토콜
  SNMP.swift                SNMPv2c(BER) GetBulk, 공유기 ARP 표 읽기(ARPTableReader)
  ARPTable.swift            이 기기 ARP 캐시 읽기(sysctl NET_RT_FLAGS+RTF_LLINFO), ARPCacheReading
  Export.swift              CSV 내보내기, 레이더 배치(RadarLayout)
  WakeOnLAN.swift           Wake-on-LAN 매직 패킷
App/                        NagoNet 앱
  Services/                 SystemNetworkInfo(SSID: NEHotspotNetwork), WiFiPathMonitor, LocationPermission,
                            TCPProber(NWConnection), LocalNetworkAccess(권한 확인), BonjourBrowser(NWBrowser),
                            UDPExchange(NWConnection UDP), BannerGrabber(TCP/TLS), AliasStore(UserDefaults)
  History/                  SwiftData 모델(NetworkRecord·DeviceRecord·ScanRecord·ScanEntry), HistoryStore
  ViewModels/               @Observable 뷰모델
  Views/                    SwiftUI 화면
```

### 내 네트워크 정보를 어떻게 읽나

- **Wi-Fi 인터페이스 이름**: `NWPathMonitor(requiredInterfaceType: .wifi)`가 알려 주는 이름을 쓰고, 모르면 `en0`.
  대부분 `en0`이지만 아닌 기기도 있다(Apple TN3179).
- **내 IP·서브넷 마스크**: `getifaddrs`에서 그 인터페이스의 IPv4 주소와 `ifa_netmask`. 주소가 여러 개면 169.254 자동 주소보다 진짜 주소 먼저.
- **게이트웨이**: `sysctl(CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY)`로 라우팅 테이블을 읽어
  **Wi-Fi 인터페이스 번호**의 기본 경로(0.0.0.0/0)를 고른다. VPN을 켜면 utun 쪽 기본 경로가 하나 더 생기는데,
  인터페이스 번호와 "대역 안의 주소인지"로 거른다. 못 읽으면 대역의 첫 주소(.1)로 짐작하고 화면에 **추정**이라고 표시한다.
  iOS SDK에는 `net/route.h`가 없어서 `rt_msghdr`(92바이트) 배치를 직접 적었고, CI의 맥에서 진짜 라우팅 테이블로 확인한다.
- **접속 AP의 MAC(BSSID)**: `NEHotspotNetwork.fetchCurrent`의 `bssid`. iOS가 유일하게 읽게 해 주는 "남의 MAC"이다
  — 지금 붙어 있는 AP의 하드웨어 주소라 무작위가 아니고, OUI 표로 제조사(Aruba·ipTIME 등)까지 나온다. 카드에 "접속 AP"로 표시.
  (다른 기기의 MAC은 iOS가 ARP 캐시에서 `02:00:00:00:00:00`으로 가리고, 폰은 무작위 MAC을 써서 어차피 못 읽는다 — SNMP가 되는 공유기에서만 보인다.)
- **SSID**: `NEHotspotNetwork.fetchCurrent`. **Access Wi-Fi Information** entitlement와 **정확한 위치** 권한이 둘 다 있어야 나온다.
  권한이 없으면 카드 아래에 "네트워크 이름 보기 / 정확한 위치 허용 / 설정에서 위치 허용" 버튼이 나온다. 위치 자체는 읽지 않는다.
- **스캔 범위**: 네트워크·브로드캐스트 주소를 뺀 호스트 전부. 1024개를 넘으면(/21보다 큰 대역) 내 주소가 든 /22 칸(1024개)만.
  /31은 두 주소 모두, /32는 나 혼자.

### 기기를 어떻게 찾나

- 대역의 모든 주소(나 빼고)에 흔히 열린 포트 `80, 62078, 443, 22, 445, 548, 7000, 8080`으로 TCP 연결을 시도한다.
  **연결되거나 거부(RST)되면 기기가 있는 것**, 시간 초과(1초)면 없는 것.
  NWConnection은 거부되면 `.failed`가 아니라 `.waiting(ECONNREFUSED)`로 가서 다시 시도하려 하므로 둘 다 "있음"으로 처리하고 바로 끊는다.
- 두 번에 나눠 훑는다(`ScannerService`):
  1. 모든 주소에 첫 포트(80) 하나씩, 동시 연결 50개. 대부분의 기기가 여기서 답해 목록에 바로 뜬다.
  2. 찾은 기기(열린 포트를 마저 알려고)와 답이 없던 주소에 나머지 7개 포트를 한꺼번에(주소 7개 × 포트 7개 ≈ 50).
     없는 주소는 1에서 ARP가 실패한 뒤 커널이 곧장 "호스트 없음"(EHOSTDOWN)을 돌려주는 경우가 많아 빨리 끝나고,
     첫 포트를 조용히 버리는 기기(iPhone의 62078, Windows의 445 등)는 여기서 찾는다.
- 연결은 `NWParameters.requiredInterfaceType = .wifi`라서 VPN이 켜져 있어도 Wi-Fi로 나간다.
- 응답 시간은 연결이나 거부 답이 올 때까지 걸린 시간 중 가장 짧은 것.
- 진행률 = 끝난 연결 시도 / (주소 × 포트 8). 중지 버튼은 Task 취소로 돌던 연결까지 바로 끊는다.
- 앱이 백그라운드로 가면 스캔을 멈춘다.
- **로컬 네트워크 권한**: iOS에는 상태를 묻는 API가 없어서(TN3179), 스캔 전에 공유기로 연결을 열어 본다.
  막혀 있으면 연결이 `.waiting` + `unsatisfiedReason == .localNetworkDenied`에 머문다 → "로컬 네트워크 권한이 필요해요"와
  설정 열기 버튼. 처음 스캔할 때는 이 연결이 iOS 허용 창을 띄우고, 허용하면(창이나 설정에서) iOS가 연결을 다시 시도하므로
  스캔이 자동으로 이어진다. 스캔 도중 권한이 꺼져도 같은 화면으로 간다.

### 기기 이름을 어떻게 찾나

TCP 탐색과 함께 두 가지를 동시에 돌려 주소별로 합친다(`ScanViewModel.discover`).

- **Bonjour**: `NWBrowser`로 16종(`_airplay`, `_raop`, `_googlecast`, `_ipp`, `_printer`, `_smb`, `_ssh`, `_http`, `_hap`,
  `_companion-link`, `_spotify-connect`, 그리고 MAC이 든 광고 `_adisk`, `_workstation`, `_apple-mobdev2`, `_hue`,
  `_esphomelib`)을 TXT 레코드와 함께 찾는다. NWBrowser는 주소를 주지 않아서 서비스마다
  NWConnection(IPv4만, Wi-Fi만)을 열어 시스템이 푼 주소(경로의 `remoteEndpoint`)만 읽고 바로 끊는다.
  서비스 포트가 막혀 연결이 끝나지 않아도 주소가 풀리는 순간 경로에 나타나므로 그때 읽는다.
  TCP 탐색 포트에 답하지 않는 기기(방화벽 켠 맥 등)도 Bonjour로 찾으면 목록에 더한다("Bonjour" 표시).
  TCP 탐색이 끝난 뒤 늦게 오는 답을 2초 더 기다린다.
- **기기별 이름 조회**: 목록에 새 주소가 들어올 때마다 세 가지를 함께 묻는다(기기 8대씩, `NameResolver`).
  - **mDNS 유니캐스트**: 기기의 UDP 5353으로 직접 DNS 질의를 보낸다. 회사·아파트·관리형 AP처럼 기기끼리의
    멀티캐스트(Bonjour 광고)를 막아 둔 Wi-Fi에서도 애플 기기·리눅스·프린터는 직접 온 질의에 답한다(RFC 6762 §5.5).
    역방향 PTR로 호스트 이름(`Minjis-iPhone.local`), 서비스 종류별 PTR로 Bonjour 이름을 얻는다(1.5초 제한).
    멀티캐스트가 아니라서 multicast entitlement가 필요 없다.
  - **NetBIOS 이름 상태**(UDP 137): 윈도우 PC·삼바 NAS의 컴퓨터 이름(`MINJI-PC`).
  - **역방향 DNS**: `getnameinfo(NI_NAMEREQD)`로 공유기 DNS의 PTR 이름(`Galaxy-S23.lan`, 2초 제한).
- **이름 고르는 순서**: Bonjour 이름 → 호스트 이름(mDNS → NetBIOS → DNS) → (공유기면) "공유기" → IP.
  - Bonjour는 사용자가 붙인 이름이 그대로 든 서비스 먼저: Google Cast(TXT의 `fn`) → Apple 기기(companion-link) →
    AirPlay → AirPlay 오디오(`MAC@이름`에서 이름만) → HomeKit → 프린터 → Spotify → SMB → SSH → 웹
  - DNS 이름은 `.lan`·`.local` 같은 꼬리를 떼고, `192-168-0-7`처럼 IP를 그대로 쓴 이름은 버린다.

### 기기 종류를 어떻게 짐작하나

iOS는 다른 기기의 MAC 주소(제조사)를 읽을 수 없어서, 모은 단서에 점수를 매겨 고른다(`DeviceClassifier`).
상세 화면에 근거가 그대로 나온다.

| 단서 | 점수 | 예 |
| --- | --- | --- |
| 기본 게이트웨이 | 100 | 공유기 |
| 모델 식별자 | 90 | mDNS로 물은 `_device-info` TXT `model=iPad13,1`, AirPlay `model`, companion-link `rpMd`, Cast `md`, 프린터 `ty` |
| Bonjour 서비스 | 20~70 | `_ipp` → 프린터, `_googlecast` → TV(Home/Nest면 스피커), `_raop`만 → 스피커 |
| 배너 | 45 | 웹 제목·인증 영역·HTTPS 인증서·Server·SSH에 `UniFi`·`ipTIME`·`LaserJet`·`DiskStation`·`Ubuntu`·`dropbear`… |
| NetBIOS 이름 | 45 | 컴퓨터 |
| 이름 | 40 | `iPad`, `iPhone`, `MacBook`, `Galaxy-Tab`, `DESKTOP-…`, `TV` … |
| 열린 포트 | 20~50 | 62078 → iPhone·iPad, 631·9100 → 프린터, 3389 → 컴퓨터, 5000·5001 → NAS, 8009 → TV |

가장 높은 종류가 20점 미만이면 "알 수 없음". 종류: 공유기·AP, iPhone, 휴대폰, 태블릿, Mac, 컴퓨터, TV, 스피커, 프린터, NAS, 알 수 없음.

**배너**: 스캔 끝에 웹·SSH 포트가 열린 기기에 직접 연결해 읽는다(기기 8대씩, 2.5초 제한).
HTTP는 `GET /`의 `Server`·`WWW-Authenticate realm`·`<title>`, HTTPS는 자체 서명 인증서를 받아들이고 인증서 이름까지,
SSH는 첫 줄. 로그인·오류 같은 흔한 제목은 이름으로 쓰지 않는다. 이름이 없는 공유기·AP·프린터·NAS가 제품명으로 보인다.

**별명**: 상세 화면에서 붙인다. SwiftData의 기억하는 기기(`DeviceRecord`)에 저장돼 다음 스캔에서도 같은 기기에 붙는다.
(4단계 때 UserDefaults에 붙인 별명은 다음 기록 때 SwiftData로 옮겨진다.)

**제조사 이름**: 배너(인증서·리디렉션 주소·제목·Server·SSH)에 Aruba·UniFi·Cisco·ipTIME·Synology·HP 같은 이름이 보이면
"Aruba AP", "Synology NAS", "HP 프린터"처럼 이름을 붙인다.

**포트 스캔**: 상세 화면의 버튼으로 주요 포트 100개(`KnownPorts`)를 동시 20개, 1초 제한으로 두드린다.
끝나면 새로 찾은 웹·SSH 포트의 배너도 읽고 종류를 다시 짐작한다.

### 기록과 "새 기기"

- 스캔을 **끝까지 마치면** SwiftData에 네트워크별로 남긴다(중지한 스캔은 남기지 않는다). 네트워크마다 최근 30번.
  - `NetworkRecord`: 네트워크. SSID가 있으면 SSID로, 없으면(위치 권한 없음) 대역 + 게이트웨이로 알아본다.
    처음에 SSID 없이 기억했다가 나중에 SSID를 알게 되면 채운다
  - `DeviceRecord`: 이 네트워크에서 본 적 있는 기기(마지막 IP·호스트 이름·Bonjour 이름·별명·종류·처음/마지막 본 날·본 횟수)
  - `ScanRecord` / `ScanEntry`: 스캔 한 번과 그때 본 기기들(이름·종류·응답 시간·열린 포트·새 기기 여부)
- **같은 기기 찾기**(`DeviceMatcher`): ① Bonjour 이름이 같으면(IP가 바뀌어도) ② 호스트 이름이 같으면
  ③ IP가 같고 이름이 서로 다르지 않으면. 같은 IP에 다른 이름이면 IP를 물려받은 다른 기기로 본다.
  기억하는 기기 하나는 지금 기기 하나에만 짝지어진다.
- **새 기기**: 스캔을 시작할 때 꺼내 둔 이 네트워크의 기억하는 기기 중 어디에도 짝이 없는 기기.
  이름이 나중에 풀리면 다시 판단한다. 네트워크의 **첫 스캔**은 비교할 기록이 없어 표시하지 않는다.
- 툴바의 시계 버튼 → **스캔 기록**: 네트워크 목록 → 스캔들(새 기기 수)과 기억하는 기기 → 스캔 한 번의 기기 목록.
  밀어서 지우기.

### 네트워크 레이더

iPad는 기기를 고르지 않았을 때 오른쪽 칸 전체가, iPhone은 툴바의 레이더 버튼이 레이더다.

- 공유기가 가운데, 기기는 **응답 시간 고리**(5ms·20ms·60ms·그 밖)에 놓인다. 가까울수록 빠른 기기
- 같은 **종류**끼리 이웃한 각도에 모이고, 색·아이콘이 종류. 이 기기는 12시 방향
- 스캔하는 동안 빔이 돌고 찾은 기기가 하나씩 나타난다. **새 기기**는 빨간 고리가 퍼진다
- 점을 누르면 상세(iPad는 오른쪽 칸, 상세의 레이더 버튼으로 돌아온다)
- 아래에 종류별 개수

### 핑(ICMP)

- iOS 앱은 raw 소켓을 못 쓰므로 `socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)`(Apple SimplePing과 같은 방식)으로
  에코 요청을 보낸다. 체크섬은 직접 계산하고, 애플 커널이 붙여 주는 IP 머리를 떼고 답을 확인한다.
  `IP_BOUND_IF`로 Wi-Fi 인터페이스에 묶어 VPN이 켜져 있어도 Wi-Fi로 나간다.
- **상세 화면의 핑 도구**: 1초 간격 10번, 응답 시간 막대 그래프, 최소·평균·최대·흔들림(지터)·손실률
- **탐색 보강**: 첫 포트에 답이 없던 주소에는 2차 탐색 때 나머지 TCP 포트와 함께 핑도 보낸다.
  TCP를 모두 막았지만 핑에는 답하는 기기를 찾는다(목록에 "핑에만 응답")

### 웹 관리 페이지·내보내기

- 상세에 웹 포트(80·8080·443·8443·5001 …)가 열려 있으면 **웹 관리 페이지** 링크(사파리로 열기)
- 툴바의 공유 버튼으로 지금 목록을 **CSV**로 보낸다(IP·이름·별명·종류·응답 시간·열린 포트·Bonjour 이름·
  호스트 이름·모델·새 기기, 엑셀에서 한글이 깨지지 않게 BOM)

### iOS 제약을 돌아가는 방법

처음엔 아래 넷을 하지 않기로 했지만, 막힌 것만 피하고 할 수 있는 길로 더했다.

| 막힌 것 | 이 앱이 하는 것 |
| --- | --- |
| 다른 기기의 MAC·ARP 표 읽기(iOS 11부터 막힘) | iOS는 ARP 캐시를 주지만 MAC을 `02:00:00:00:00:00`으로 지운다. 그래서 MAC을 다른 길로 모은다(아래 "MAC을 어디서 얻나"). ① 기기가 스스로 알려 준 MAC: NetBIOS 답의 unit ID(윈도우), AirPlay TXT `deviceid`·AirPlay 오디오 이름 앞자리(애플 TV·스피커), Bonjour 광고·UPnP·프린터 기기 ID·IPv6 EUI-64·기기 정보 API·기기 SNMP ② **공유기·AP에 SNMP로 ARP 표를 묻기**(UDP 161, 설정의 커뮤니티 문자열, 기본 public). 게이트웨이 → 관리형 AP 순으로 묻고, 탐색엔 안 잡혔지만 공유기가 최근에 본 기기도 "공유기 기록에만 있음"으로 더한다. MAC 앞자리로 IEEE 등록 목록(`App/Resources/oui.txt`, 약 4만 개)에서 제조사를 찾는다. 무작위 주소(비공개 Wi-Fi 주소)는 제조사가 없고 "휴대기기"의 단서로만 쓴다. 진짜 MAC은 같은 기기 찾기의 가장 강한 열쇠가 된다 |
| raw 소켓 ICMP | 그대로 안 씀(root 필요). 핑은 SOCK_DGRAM ICMP로 한다 |
| SSDP/UPnP 멀티캐스트(entitlement 필요) | **유니캐스트 SSDP**(UPnP 1.1): 기기 주소의 1900 포트로 직접 `M-SEARCH`를 보내고, 답의 LOCATION(그 기기 주소일 때만)에서 설명 XML을 읽어 이름(friendlyName)·제조사·모델·기기 종류를 얻는다. 멀티캐스트가 아니라 entitlement가 필요 없다 |
| 백그라운드 상시 스캔 | ① 스캔 중에 앱을 나가면 iOS가 주는 약 30초 동안 마저 스캔(`beginBackgroundTask`), 시간이 다 되면 멈춤 ② 설정의 **새 기기 알림**을 켜면 `BGAppRefreshTask`로 iOS가 가끔(보통 몇 시간에 한 번) 깨워 줄 때 포트 하나로 빠르게 훑고, 기록에 없는 주소만 이름을 물어 다시 확인한 뒤 처음 보는 기기를 알림. 한 번 알린 기기는 다음 앱 스캔이 기록될 때까지 다시 알리지 않는다. 실시간 감시는 iOS에서 할 수 없다 |

### MAC을 어디서 얻나

iOS(그리고 안드로이드 10 이상)는 앱에 다른 기기의 MAC을 주지 않는다. 대신 기기가 같은 Wi-Fi에 **스스로 공개해 둔 MAC**을
모은다(`MACClues`, `MACProber`). 믿는 순서는 아래 표의 위에서 아래로이고, 상세 화면의 "알게 된 곳"에 출처가 나온다.

| 출처 | 어떤 기기 | 어떻게 |
| --- | --- | --- |
| 공유기 ARP 표(SNMP) | 모든 기기(공유기가 SNMP를 켰을 때) | 게이트웨이·관리형 AP에 ipNetToMediaPhysAddress GetBulk |
| DHCP 요청(스니핑) | 모든 기기(붙거나 갱신하는 순간, 폰 포함) — **공유기 없이** | 앱이 떠 있는 동안 :67·:68로 오는 DHCP 브로드캐스트의 chaddr. 공유기가 아니라 기기 자신이 알린다(아래 "DHCP 스니핑") |
| IPv6 이웃 탐색(NDP) | 모든 IPv6 기기(아이패드·아이폰 포함) — **공유기 없이, 온디맨드** | all-nodes(ff02::1)·링크로컬에 ICMPv6 핑을 쏴 상대가 NS/NA로 자기 MAC을 알리게 유도하고, SOCK_DGRAM ICMPv6 소켓으로 받는다(`NeighborProber`, 실기기에서 작동 확인) |
| 기기 SNMP(인터페이스 MAC) | 프린터·NAS·관리형 AP·스위치 | 그 기기에 ipAdEntIfIndex.<IP> → ifPhysAddress.<번호> Get(UDP 161, 읽기만) |
| 기기 정보 API | Roku, 삼성 TV(2016~), Hue 브리지, Shelly | `:8060/query/device-info`의 `wifi-mac`·`ethernet-mac`, `:8001/api/v2/`의 `device.wifiMac`, `/api/config`의 `mac`, `/shelly`의 `mac`(Hue·Shelly는 80 포트가 열린 기기만) |
| NetBIOS 응답 | 윈도우 PC | NBSTAT 답의 unit ID |
| AirPlay 광고 | 애플 TV·HomePod·에어플레이 스피커 | TXT `deviceid`, `_raop` 이름의 `MAC@` |
| Bonjour 광고 | 시놀로지·QNAP·Time Machine 디스크, 리눅스(avahi), 아이폰·아이패드(Wi-Fi 동기화), ESPHome, Hue | `_adisk` TXT `sys=waMa=…`, `_workstation` 이름의 `[MAC]`, `_apple-mobdev2` 이름의 `MAC@`, `_esphomelib` TXT `mac`, `_hue` TXT `bridgeid`(가운데 FFFE를 빼면 MAC) |
| 기기 ID(UUID) | UPnP 기기(Hue·공유기·TV), 프린터(브라더·엡손·캐논), 소노스 | 버전 1 UUID의 끝 12자리는 만든 기기의 MAC(RFC 4122). UPnP `UDN`, IPP TXT `UUID`, 소노스 `RINCON_<MAC>` |
| IPv6 주소(EUI-64) | 프린터·TV·공유기·IoT(리눅스·임베디드) | mDNS로 호스트 이름의 AAAA를 묻고, 인터페이스 ID가 `…ff:fe…`면 가운데를 빼고 U/L 비트를 되돌린다 |
| 기억된 MAC | 한 번이라도 잡힌 기기(특히 아이패드·아이폰) | 위 방법으로 한 번 잡은 MAC을 mDNS·Bonjour 이름으로 기억해 두고(`MACMemoryStore`), DHCP가 그 순간 못 잡아도 되살린다 |

기기 ID와 IPv6는 우연히 MAC 꼴이 될 수 있어서 **IEEE에 등록된 제조사 번호일 때만** 믿는다. 휴대폰은 Wi-Fi마다 무작위
MAC을 써서, 어디서 얻든 제조사가 안 나온다(이건 MAC을 읽는 쪽이 아니라 폰이 그렇게 만든 것). 스스로는 MAC을 공개하지 않는
휴대폰도 **DHCP 스니핑**으로 붙거나 갱신하는 순간 공유기 없이 잡을 수 있다(아래, 실기기에서 확인됨).

#### iOS가 MAC을 흘리는지 직접 확인 (ARP 캐시 진단)

"다른 기기 MAC은 iOS가 가린다"는 건 iOS 버전·기기마다 다를 수 있어서, 단정하지 않고 **스캔할 때마다 실제로 측정**한다.
스캔은 모든 기기에 TCP로 붙으므로 끝난 직후 이 기기의 ARP 캐시가 가장 따뜻하다. 그때 캐시를 날것으로 읽어(`ARPCache.report`)
"항목 N개 중 진짜 MAC M개, iOS가 가린 것 K개"를 세어 스캔 요약에 한 줄로 보여 준다(공유기·비밀번호 불필요).

- **M > 0** — 이 기기·iOS 버전은 ARP 캐시에 진짜 MAC을 흘린다. 그러면 공유기 없이도 그만큼 MAC이 채워진다(폰이면 무작위 MAC).
- **M = 0, K > 0** — iOS가 항목은 주되 MAC을 전부 `02:00:…`으로 가린 게 **그 기기에서 입증된 것**. 그래도 공유기 SNMP나 아래 **DHCP 스니핑**으로는 얻을 수 있다.

(IPv6 이웃(NDP) **캐시**도 ARP와 별개로 같은 식으로 측정한다 — 실기기에선 둘 다 가렸다. 다만 **캐시**가 가려진 것일 뿐,
살아 있는 NS/NA 메시지를 직접 받는 **능동 이웃 탐색**(위 표의 "IPv6 이웃 탐색")은 통한다 — 실기기에서 아이패드 MAC을 받았다.)

즉 "공유기 없이 다른 기기의 MAC"이 되는지 안 되는지를, 추측이 아니라 그 기기의 실제 측정값으로 알려 준다.

#### DHCP 스니핑 — 공유기 없이 MAC을 잡는 길 (실기기에서 확인됨)

ARP·NDP·SNMP가 다 막혀도 뚫리는 길이다. 기기는 Wi-Fi에 새로 붙거나 임대를 갱신할 때 자기 MAC(`chaddr`)을
**브로드캐스트**로 알린다 — 공유기가 아니라 기기 자신이. 앱이 떠 있는 동안 UDP `:67`·`:68`에 소켓을 묶어
(`DHCPSniffer`, `ICMPPinger`와 같은 BSD 소켓 방식) 그 브로드캐스트를 엿듣고 `DHCP.parse`로 chaddr와 요청/할당 IP를
꺼내 그 IP의 기기에 붙인다(출처 "DHCP 요청"). 읽기만 하고 아무것도 보내지 않는다.

- iOS가 이 브로드캐스트를 앱에 넘겨주는지는 기기마다 달라, 요약에 "소켓 막힘 / 0개 / N개 잡음"으로 측정값을 그대로 보여 준다.
  실기기(iPad)에서 **소켓이 열리고 실제로 MAC이 잡혔다** — ARP·NDP·SNMP가 모두 가려진 네트워크에서.
- 기회성이다: 그 순간에 붙거나 갱신한 기기만 잡힌다. 폰의 Wi-Fi(또는 비행기모드)를 껐다 켜면 그 순간 잡힌다.
- 잡은 MAC은 폰의 네트워크용 무작위 MAC이라 제조사는 없지만, **그 네트워크 안에선 고정**이라 IP가 바뀌어도 같은 기기를
  알아보는 열쇠가 된다(`DeviceIdentity`가 무작위 MAC도 식별에 쓴다). 설정에서 끌 수 있다.

### 기기 깨우기 (Wake-on-LAN)

MAC을 아는 기기는 상세 화면의 **제어 → 깨우기**, 또는 스캔 기록에서 기기를 **왼쪽으로 밀어** 깨울 수 있다
(꺼져 있어 지금 스캔엔 안 보이는 기기도 기록에 MAC이 있으면 깨울 수 있다). 매직 패킷(0xFF×6 + MAC×16)을
UDP 포트 9·7로, 마지막으로 본 IP와 서브넷 브로드캐스트(x.x.x.255)로 보낸다. 브로드캐스트는 iOS가 막을 수 있어
(멀티캐스트 entitlement 필요) 완전히 꺼진 기기는 못 깨울 수 있고, 잠자기 중이거나 공유기가 IP↔MAC을 기억하는
기기는 깨어난다. 대상 기기에서 Wake-on-LAN(원격 깨우기)이 켜져 있어야 한다.

멀티캐스트 entitlement(`com.apple.developer.networking.multicast`)는 유료 개발자 계정으로 Apple에 신청해 승인받으면 쓸 수 있다.
승인받으면 SSDP·mDNS를 멀티캐스트로도 보낼 수 있지만, 지금 방식만으로도 대부분의 기기는 답한다.

## 빌드

### A. XcodeGen + Xcode (추천)

```bash
brew install xcodegen
# project.yml에서 DEVELOPMENT_TEAM, PRODUCT_BUNDLE_IDENTIFIER 수정
xcodegen
open NagoNet.xcodeproj
```

아이폰·아이패드를 연결하고 ▶︎ 실행. 자동 서명이 App ID와 **Access Wi-Fi Information** 기능을 알아서 등록한다.
(Xcode 16 이상 필요: Swift 6)

### B. GitHub Actions IPA

`App/`, `Core/`, `project.yml`이 바뀐 푸시마다 `.github/workflows/build-ipa.yml`이
Core 시험 → 서명 없는 Release 빌드 → entitlements를 넣은 ad-hoc 서명 IPA를 만들어 **Releases**(prerelease)에 올린다.
본인 인증서로 재서명해 설치한다(Sideloadly 등). 재서명할 때 Wi-Fi 정보 권한이 빠지면 SSID만 "이름 모를 Wi-Fi"로 나온다.

### 엔진 시험

```bash
swift test --package-path Core
```

## 실기기 확인

### 1단계: 내 네트워크 정보

1. Wi-Fi에 연결된 상태로 앱을 연다. 카드에 **내 IP·게이트웨이·서브넷·스캔 범위**가 나온다.
2. **설정 → Wi-Fi → 연결된 네트워크의 ⓘ** 화면의 `IP 주소`, `서브넷 마스크`, `라우터`와 카드 값이 같은지 본다.
   - 게이트웨이 옆에 **추정**이 붙어 있으면 라우팅 테이블을 못 읽은 것(값이 라우터와 다르면 알려 주세요).
3. 카드 아래 **네트워크 이름 보기**를 누르고 위치 권한을 **앱을 사용하는 동안 허용**(정확한 위치 켬)으로 주면 카드 제목이 SSID로 바뀐다.
   - "정확한 위치"를 끄고 허용하면 **정확한 위치 허용** 버튼이 나오고, 누르면 이번만 정확한 위치를 묻는다.
   - 거부하면 **설정에서 위치 허용** 버튼이 앱 설정을 연다.
4. 제어 센터에서 Wi-Fi를 끄면 "Wi-Fi에 연결되어 있지 않아요"로 바뀌고, 다시 켜면 몇 초 안에 카드가 돌아온다(당겨서 새로고침도 됨).
5. VPN을 켠 채로 열어도 내 IP·게이트웨이가 Wi-Fi 값 그대로인지 본다(VPN 주소가 나오면 안 됨).
6. 스캔 범위: 집 공유기(/24)는 `x.x.x.1 – x.x.x.254 · 254개`. 회사·학교처럼 큰 대역(/16 등)이면 카드 아래에
   "대역이 커서 … 1,024개만 스캔해요"가 나온다.
7. iPad에서는 왼쪽에 카드, 오른쪽에 "기기를 골라 주세요" 두 칸으로 나온다. 다크 모드로 바꿔도 잘 보이는지 확인.

### 2단계: TCP 기기 탐색과 목록

1. **스캔 시작**을 누른다. 처음이면 "로컬 네트워크의 기기를 찾고 연결하도록 허용" 창이 뜬다 → **허용**.
   뒤에 "로컬 네트워크 권한이 필요해요"가 잠깐 보이는 건 정상이고, 허용하면 바로 스캔이 시작된다.
2. 진행 막대와 "기기 N대"가 올라가고, 몇 초 안에 **공유기**(초록 아이콘)와 **이 기기**가 목록에 뜬다.
   /24 집 네트워크는 보통 10~40초, 지금처럼 /23(510개)이면 그보다 조금 더 걸린다.
3. 아는 기기(맥, 다른 아이폰, TV, 프린터, NAS)의 IP가 목록에 있는지 본다. 각 기기의 IP는 그 기기의 설정이나
   공유기 관리 페이지(DHCP 목록)에서 확인할 수 있다.
   - 이름은 아직 없다(3단계). 아래 줄에 탐색 포트 중 열린 것(HTTP·AirPlay·iPhone 동기화…)이 나온다.
   - 잠든 아이폰이나 방화벽을 켠 맥/윈도우 PC는 TCP에 답하지 않아 빠질 수 있다(3단계 Bonjour가 보완).
4. 스캔 중 **중지**를 누르면 바로 멈추고 그때까지 찾은 기기는 남는다. **다시 스캔**으로 처음부터.
5. 기기를 누르면 상세(IP, 응답 시간, 열린 포트)가 iPad는 오른쪽, iPhone은 다음 화면에 나온다.
   목록 위 메뉴로 **IP순 / 이름순** 정렬.
6. 권한 거부 화면 확인: **설정 → NAGO NET → 로컬 네트워크**를 끄고 돌아와 스캔하면 "로컬 네트워크 권한이 필요해요"와
   **설정 열기**가 나온다. 설정에서 다시 켜고 돌아오면 스캔이 저절로 이어진다.
7. VPN을 켠 채로 스캔해도 기기가 똑같이 나오는지 본다(연결을 Wi-Fi로 고정).
8. 스캔 중 홈 화면으로 나가면 스캔이 멈춘다(백그라운드 스캔 안 함). 다른 Wi-Fi로 옮기면 목록이 비워진다.

### 3단계: Bonjour와 역방향 DNS로 이름 찾기

1. **스캔 시작**. 진행 막대가 끝나면 "기기 이름 찾는 중…"이 2초쯤 나온 뒤 끝난다.
2. 애플 기기·TV·스피커·프린터는 **사용자가 붙인 이름**("민지의 iPhone", "거실 Apple TV", "HP LaserJet …")으로,
   나머지는 공유기가 아는 **호스트 이름**("Galaxy-S23" 같은)으로 바뀌는지 본다.
   - 아래 줄에 IP와 찾은 서비스(Apple 기기 · AirPlay …)가 나온다.
   - 기기끼리 멀티캐스트를 막은 Wi-Fi에서도 애플 기기·윈도우 PC·리눅스·프린터는 직접 질의(mDNS·NetBIOS)로 이름이 붙는다.
   - 이름이 안 붙는 기기는 어떤 방법에도 답하지 않는 기기다(안드로이드 폰, IoT 기기, 관리형 AP 등에서 흔함).
3. 기기를 누르면 상세에 **Bonjour 이름 / mDNS 호스트 이름 / NetBIOS 이름 / DNS 이름**과
   **Bonjour 서비스 목록**(종류, 인스턴스 이름, 포트, 모델)이 나와 어디서 이름을 얻었는지 보인다.
4. 2단계에서 빠졌던 기기(방화벽을 켠 맥 등)가 오른쪽에 "Bonjour"라고 표시되며 새로 잡히는지 본다.
5. **이름순** 정렬로 바꾸면 이름 있는 기기가 가나다순으로 먼저, 이름 없는 기기는 뒤에 IP순으로 나온다.
6. VPN을 켠 채로도 이름이 똑같이 나오는지 본다(Bonjour 검색과 주소 풀기도 Wi-Fi로 고정).

### 4단계: 종류 추정, 상세 화면, 포트 스캔, 별명

1. **다시 스캔**. 목록 아이콘이 종류별로 바뀐다(iPad·iPhone·공유기·AP·프린터… 모르면 ?).
   진행 막대가 끝난 뒤 "기기 이름 찾는 중…"이 조금 더 길어진다(웹·SSH 배너를 읽는 시간).
2. `192.168.10.10~15`처럼 SSH·HTTP·HTTPS가 열린 기기가 **공유기·AP**로 바뀌고, 웹 제목·인증서에 제품명이 있으면 그 이름으로 보이는지 본다.
   상세의 **기기 정보**에 웹 페이지 제목·인증서·서버·SSH 버전이 나온다.
3. 이름이 "동혁pad"처럼 iPad라는 말이 없는 기기도 **모델 iPad…**로 태블릿이 되는지, 상세의 **종류 추정 근거**를 본다.
4. 목록 위 정렬 메뉴에서 **종류별**: 공유기·AP → iPhone → … → 알 수 없음 순.
5. 상세에서 **포트 스캔(주요 100개)** → 진행률과 열린 포트가 차례로 뜨고, 끝나면 푸터에 "주요 포트 100개를 확인했어요".
   중지 버튼도 확인. 프린터(631·9100)나 NAS(5000·5001)는 포트 스캔 뒤 종류가 더 정확해진다.
6. 이름 없는 기기에 **별명 붙이기** → 목록에 바로 반영. **다시 스캔**해도 그대로 붙어 있는지,
   앱을 껐다 켜고 스캔해도 남아 있는지 본다. **별명 지우기**로 원래 이름으로.

### 5단계: 기록과 "새 기기"

1. 스캔을 끝까지 마친다. 버튼 아래에 "이 네트워크의 첫 기록이에요…"가 나온다(첫 스캔엔 새 기기 배지 없음).
2. 툴바의 **시계 버튼 → 스캔 기록**에 네트워크(GreenLamp49)와 스캔 1번, 기억하는 기기 수가 보이는지 본다.
3. **다시 스캔**한다. 지난 스캔에 없던 기기(그사이 들어온 폰·노트북)에 빨간 **새 기기** 배지가 붙고,
   목록 머리에 "새 기기 N대"가 나온다. 아무도 안 들어왔으면 배지가 없는 게 정상.
   - 확인용: 다른 폰의 Wi-Fi를 껐다가 첫 스캔 뒤에 켜면 그 폰이 새 기기로 뜬다.
4. 기록에서 스캔을 누르면 그때 본 기기 목록(새 기기 표시 포함). 기억하는 기기에는 처음·마지막 본 날과 본 횟수.
5. 별명을 붙이고 앱을 완전히 껐다 켠 뒤 스캔해도 별명이 남는지 본다(이제 SwiftData).
6. iPad가 IP를 새로 받아도(Wi-Fi 껐다 켜기) Bonjour 이름으로 같은 기기로 알아봐 새 기기로 뜨지 않는지 본다.
7. `.14`·`.15` 같은 Aruba AP가 **Aruba AP**라는 이름으로 보이고, 기기 정보에 **리디렉션** 주소가 나오는지 본다.

### 추가 기능: 레이더·핑·웹·CSV·아이콘

1. 홈 화면에 레이더 모양 **앱 아이콘**이 보인다.
2. iPad: 스캔을 시작하면 오른쪽 칸에 **레이더**가 뜨고 빔이 돌며 점이 하나씩 나타난다. 공유기가 가운데,
   iPad들(남색)이 한쪽에 모여 있는지 본다. 점을 누르면 상세, 상세 오른쪽 위 **레이더** 버튼으로 돌아온다.
   iPhone: 툴바의 레이더 버튼.
3. 두 번째 스캔부터 새 기기는 레이더에서 빨간 고리가 퍼진다.
4. 상세 → **핑 10번 보내기**: 막대가 하나씩 차오르고 평균·손실이 나온다. 공유기는 몇 ms, 잠든 iPhone은 손실이 많을 수 있다.
5. 목록에서 "핑에만 응답"이 붙은 기기가 생겼는지 본다(전에는 안 보이던 기기).
6. Aruba AP 상세 → **웹 관리 페이지** 링크를 누르면 사파리로 열린다.
7. 스캔이 끝난 뒤 툴바의 공유 버튼 → 파일에 저장하거나 메일로 보내서 CSV가 엑셀·넘버스에서 열리는지 본다.

### 추가 기능 2: SSDP·MAC·SNMP·백그라운드

1. **다시 스캔**. 끝나면 버튼 아래에 "공유기 ARP 표(SNMP, …)에서 MAC N개를 읽었어요" 또는 "SNMP 응답이 없어…"가 나온다.
   - SNMP가 되면: 거의 모든 기기 상세에 **MAC·제조사**가 생기고, 탐색엔 없던 기기가 "공유기 기록에만 있음"으로 더해진다.
     휴대폰은 대부분 "무작위 주소"로 나오는 게 정상(비공개 Wi-Fi 주소).
   - 안 되면: 툴바 … → **설정**에서 커뮤니티 문자열을 학교 네트워크 관리자에게 받아 넣는다.
2. 윈도우 PC 상세에 **MAC(NetBIOS 응답)**과 제조사(Intel·Dell…), 애플 TV·에어플레이 스피커에 **MAC(AirPlay 광고)**가 나오는지 본다.
3. 스마트 TV·공유기·NAS·소노스가 있으면 상세에 **UPnP(SSDP)** 칸(이름·제조사·모델)이 생기고 이름이 "[TV] Samsung …"처럼 바뀌는지 본다.
4. 스캔 중에 홈 화면으로 나갔다가 30초 안에 돌아오면 스캔이 이어져 끝나 있는지 본다(너무 오래 있으면 "중지됨").
5. **설정 → 새 기기 알림** 켜기 → 알림 허용. 앱을 닫아 두면 몇 시간 안에 iOS가 깨워 확인한다(정확한 때는 iOS가 정한다).
   알림을 보려면 첫 스캔 기록이 있는 Wi-Fi에서, 그 뒤 처음 보는 기기가 들어와야 한다.

### 추가 기능 3: 기기가 공개한 MAC 모으기

1. 새 IPA를 설치하면 로컬 네트워크 권한 창이 다시 뜰 수 있다(찾는 Bonjour 종류가 늘어서). 허용한다.
2. **다시 스캔**. 끝나면 버튼 아래에 "MAC을 아는 기기 N/M대"가 나온다. 이전보다 N이 늘었는지 본다.
3. 기기 상세의 **MAC → 알게 된 곳**에서 출처를 본다.
   - 프린터: "기기 SNMP(인터페이스 MAC)", "기기 ID(UUID)", "IPv6 주소(EUI-64)" 중 하나가 흔하다.
   - 삼성 TV·Roku: "기기 정보 API"
   - 시놀로지·QNAP NAS: "Bonjour 광고"(Time Machine을 켠 경우) 또는 "기기 SNMP"
   - Hue 브리지: "기기 정보 API" 또는 "기기 ID(UUID)"
   - 윈도우 PC: "NetBIOS 응답", 애플 TV·HomePod: "AirPlay 광고"
4. **이름** 칸에 IPv6 주소가 보이는 기기가 있으면, `…ff:fe…`가 들어 있는 주소에서 MAC이 나왔는지 확인한다.
5. 휴대폰은 여전히 MAC이 없거나 "무작위 주소"로 나오는 게 정상이다.
