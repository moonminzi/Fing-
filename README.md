# NAGO NET (iOS·iPadOS)

같은 Wi-Fi에 연결된 기기를 찾아 이름·종류·열린 포트를 보여 주는 네트워크 스캐너(Fing 같은 앱).
Swift 6 · SwiftUI · Swift Concurrency · Network 프레임워크 · SwiftData, 외부 라이브러리 없음. iOS 17 이상, iPhone·iPad(iPad는 두 칸 화면).

## 진행 단계

| 단계 | 내용 | 상태 |
| --- | --- | --- |
| 1 | 내 네트워크 정보(SSID·내 IP·서브넷·게이트웨이)와 스캔 대역 계산 | ✅ |
| 2 | TCP 연결로 기기 탐색, 진행률·취소, 기기 목록, 로컬 네트워크 권한 거부 안내 | ✅ |
| 3 | Bonjour(NWBrowser)와 역방향 DNS로 기기 이름 찾기 | ✅ |
| 4 | 기기 종류 추정, 상세 화면, 포트 100개 스캔, 별명 | |
| 5 | SwiftData로 네트워크별 기록, "새 기기" 배지 | |

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
  NameResolver.swift        기기별 이름 조회: 역방향 DNS + mDNS 유니캐스트 + NetBIOS
App/                        NagoNet 앱
  Services/                 SystemNetworkInfo(SSID: NEHotspotNetwork), WiFiPathMonitor, LocationPermission,
                            TCPProber(NWConnection), LocalNetworkAccess(권한 확인), BonjourBrowser(NWBrowser),
                            UDPExchange(NWConnection UDP)
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

- **Bonjour**: `NWBrowser`로 11종(`_airplay`, `_raop`, `_googlecast`, `_ipp`, `_printer`, `_smb`, `_ssh`, `_http`, `_hap`,
  `_companion-link`, `_spotify-connect`)을 TXT 레코드와 함께 찾는다. NWBrowser는 주소를 주지 않아서 서비스마다
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

## iOS에서 하지 않는 것

- 다른 기기의 MAC 주소·ARP 테이블 읽기(iOS에서 막혀 있음)
- raw 소켓 ICMP(필요하면 SOCK_DGRAM ICMP만)
- SSDP/UPnP 같은 멀티캐스트(별도 entitlement 필요)
- 백그라운드 스캔

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
