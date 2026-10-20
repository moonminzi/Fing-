import Testing
@testable import NagoNetCore

struct UPnPControlTests {
    // 공유기 IGD 설명 XML(서비스가 중첩 기기에 흩어져 있음)
    static let igdXML = """
    <root xmlns="urn:schemas-upnp-org:device-1-0"><device>
      <deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType>
      <serviceList>
        <service><serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType><controlURL>/ctl/L3F</controlURL><SCPDURL>/scpd/L3F</SCPDURL></service>
      </serviceList>
      <deviceList><device><deviceList><device>
        <serviceList>
          <service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType><controlURL>/ctl/IPConn</controlURL><eventSubURL>/evt/IPConn</eventSubURL></service>
        </serviceList>
      </device></deviceList></device></deviceList>
    </device></root>
    """

    @Test func parsesAllServicesIncludingNestedWANConnection() {
        let services = SSDP.services(in: Self.igdXML)
        #expect(services.count == 2)
        let wan = services.first { $0.serviceType.contains("WANIPConnection") }
        #expect(wan?.controlURL == "/ctl/IPConn")
        let l3f = services.first { $0.serviceType.contains("Layer3Forwarding") }
        #expect(l3f?.scpdURL == "/scpd/L3F")
    }

    @Test func controlTargetResolvesRelativeAndGuardsHost() {
        let gateway = IPv4("192.168.0.1")!
        // 상대 controlURL은 설명 XML(base)의 호스트·포트에 붙는다
        let resolved = SSDP.controlTarget(controlURL: "/ctl/IPConn", base: "http://192.168.0.1:5000/desc.xml", expectedHost: gateway)
        #expect(resolved?.port == 5000)
        #expect(resolved?.path == "/ctl/IPConn")
        #expect(resolved?.tls == false)

        // 절대 controlURL도 같은 기기면 허용
        let absolute = SSDP.controlTarget(controlURL: "http://192.168.0.1:80/ctl", base: "http://192.168.0.1:5000/d", expectedHost: gateway)
        #expect(absolute?.port == 80)

        // 발견한 기기가 아닌 주소로는 절대 안 보낸다(엉뚱한 곳 POST 방지)
        #expect(SSDP.controlTarget(controlURL: "http://10.0.0.9/x", base: "http://192.168.0.1/d", expectedHost: gateway) == nil)
    }

    @Test func addPortMappingEnvelopeAndSOAPAction() {
        let add = UPnPControl.addPortMapping(externalPort: 8888, protocolTCP: true, internalPort: 8888,
                                             internalClient: IPv4("192.168.0.50")!, description: "NAGO-NET-TEST", leaseSeconds: 3600)
        #expect(add.soapAction == "\"urn:schemas-upnp-org:service:WANIPConnection:1#AddPortMapping\"")
        let body = String(decoding: add.body, as: UTF8.self)
        #expect(body.contains("<u:AddPortMapping xmlns:u=\"urn:schemas-upnp-org:service:WANIPConnection:1\">"))
        #expect(body.contains("<NewExternalPort>8888</NewExternalPort>"))
        #expect(body.contains("<NewProtocol>TCP</NewProtocol>"))
        #expect(body.contains("<NewInternalClient>192.168.0.50</NewInternalClient>"))
        #expect(body.contains("<NewLeaseDuration>3600</NewLeaseDuration>"))
    }

    @Test func getExternalIPAddressEnvelope() {
        let ext = UPnPControl.getExternalIPAddress()
        #expect(ext.soapAction.hasSuffix("#GetExternalIPAddress\""))
        #expect(String(decoding: ext.body, as: UTF8.self).contains("<u:GetExternalIPAddress xmlns:u=\"urn:schemas-upnp-org:service:WANIPConnection:1\">"))
    }

    @Test func setAVTransportURIEscapesAndTargetsAVTransport() {
        let set = UPnPControl.setAVTransportURI(uri: "http://host/a&b<c>")
        #expect(set.soapAction == "\"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\"")
        let body = String(decoding: set.body, as: UTF8.self)
        #expect(body.contains("<InstanceID>0</InstanceID>"))
        #expect(body.contains("<CurrentURI>http://host/a&amp;b&lt;c&gt;</CurrentURI>"))   // XML 이스케이프
    }

    @Test func parsesSuccessOutArgsAndNoFault() {
        let http = Array(("HTTP/1.1 200 OK\r\nContent-Type: text/xml; charset=\"utf-8\"\r\n\r\n"
            + "<?xml version=\"1.0\"?><s:Envelope><s:Body><u:GetExternalIPAddressResponse>"
            + "<NewExternalIPAddress>203.0.113.7</NewExternalIPAddress></u:GetExternalIPAddressResponse></s:Body></s:Envelope>").utf8)
        #expect(UPnPControl.parseResponse(http)["NewExternalIPAddress"] == "203.0.113.7")
        #expect(UPnPControl.fault(http) == nil)
    }

    @Test func detectsSOAPFault() {
        let http = Array(("HTTP/1.1 500 Internal Server Error\r\n\r\n"
            + "<s:Envelope><s:Body><s:Fault><faultcode>s:Client</faultcode><detail>"
            + "<UPnPError><errorCode>713</errorCode><errorDescription>SpecifiedArrayIndexInvalid</errorDescription></UPnPError>"
            + "</detail></s:Fault></s:Body></s:Envelope>").utf8)
        let fault = UPnPControl.fault(http)
        #expect(fault?.code == "713")
        #expect(fault?.description == "SpecifiedArrayIndexInvalid")
        #expect(UPnPControl.parseResponse(http)["NewExternalIPAddress"] == nil)
    }
}
