/// 로컬 네트워크 권한 확인 결과.
public enum LocalNetworkSignal: Hashable, Sendable {
    /// iOS가 막고 있다: 처음이라 허용 창이 떠 있거나, 설정에서 꺼져 있다
    case denied
    /// 허용됨. 이 신호 뒤에 스트림이 끝난다
    case granted
}

/// 로컬 네트워크 권한을 확인한다. iOS에는 상태를 묻는 API가 없어서(TN3179) 실제로 연결해 보고 판단한다.
public protocol LocalNetworkAccessChecking: Sendable {
    /// `host`로 연결해 보며 신호를 흘려보낸다. 막혀 있으면 `.denied`를 보내고 계속 기다리다가,
    /// 사용자가 허용하면(허용 창이나 설정 앱에서) `.granted`를 보내고 끝난다.
    func signals(probing host: IPv4) -> AsyncStream<LocalNetworkSignal>
}
