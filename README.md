# NAGO NET (iOS·iPadOS)

같은 Wi-Fi에 연결된 기기를 찾아 이름·종류·열린 포트를 보여 주는 네트워크 스캐너(Fing 같은 앱).
Swift 6 · SwiftUI · Swift Concurrency · Network 프레임워크 · SwiftData, 외부 라이브러리 없음. iOS 17 이상, iPhone·iPad(iPad는 두 칸 화면).

## 진행 단계

| 단계 | 내용 | 상태 |
| --- | --- | --- |
| 1 | 내 네트워크 정보(SSID·내 IP·서브넷·게이트웨이)와 스캔 대역 계산 | ✅ |
| 2 | TCP 연결로 기기 탐색, 진행률·취소, 기기 목록, 로컬 네트워크 권한 거부 안내 | |
| 3 | Bonjour(NWBrowser)와 역방향 DNS로 기기 이름 찾기 | |
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
App/                        NagoNet 앱
  Services/                 SystemNetworkInfo(SSID: NEHotspotNetwork), WiFiPathMonitor, LocationPermission
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
