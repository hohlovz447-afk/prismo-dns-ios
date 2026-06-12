import XCTest
@testable import PrismoKit

final class VlessParserTests: XCTestCase {
    func testParsesRealityTCP() {
        let link = "vless://11111111-2222-3333-4444-555555555555@1.2.3.4:33443"
            + "?type=tcp&security=reality&flow=xtls-rprx-vision"
            + "&sni=www.google.com&pbk=PUBKEY&sid=ab12&fp=firefox"
            + "#%F0%9F%87%B7%F0%9F%87%BA%20Obhod-3"
        let s = VlessSubscriptionService.parse(link)
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.uuid, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(s?.host, "1.2.3.4")
        XCTAssertEqual(s?.port, 33443)
        XCTAssertEqual(s?.transport, .tcp)
        XCTAssertEqual(s?.security, .reality)
        XCTAssertEqual(s?.flow, "xtls-rprx-vision")
        XCTAssertEqual(s?.sni, "www.google.com")
        XCTAssertEqual(s?.publicKey, "PUBKEY")
        XCTAssertEqual(s?.shortID, "ab12")
        XCTAssertEqual(s?.fingerprint, "firefox")
        XCTAssertEqual(s?.name, "🇷🇺 Obhod-3")
    }

    func testParsesGRPC() {
        let link = "vless://uuiduuid@example.com:2053"
            + "?type=grpc&security=reality&sni=vk.com&pbk=K&sid=00&fp=firefox"
            + "&serviceName=grpcsvc#Server%20gRPC"
        let s = VlessSubscriptionService.parse(link)
        XCTAssertEqual(s?.transport, .grpc)
        XCTAssertEqual(s?.serviceName, "grpcsvc")
        XCTAssertEqual(s?.port, 2053)
    }

    func testParsesWSOverTLS() {
        let link = "vless://uuid@cdn.prismovpn.org:443"
            + "?type=ws&security=tls&sni=cdn.prismovpn.org&host=cdn.prismovpn.org"
            + "&path=%2Fsecretpath&fp=firefox#CDN"
        let s = VlessSubscriptionService.parse(link)
        XCTAssertEqual(s?.transport, .ws)
        XCTAssertEqual(s?.security, .tls)
        XCTAssertEqual(s?.path, "/secretpath")
        XCTAssertEqual(s?.hostHeader, "cdn.prismovpn.org")
    }

    func testRejectsNonVless() {
        XCTAssertNil(VlessSubscriptionService.parse("ss://blah@1.2.3.4:8388"))
        XCTAssertNil(VlessSubscriptionService.parse("not a link"))
    }

    func testParsesBase64Subscription() {
        let links = [
            "vless://a@1.1.1.1:443?type=tcp&security=reality#A",
            "vless://b@2.2.2.2:443?type=grpc&security=reality#B",
        ].joined(separator: "\n")
        let b64 = Data(links.utf8).base64EncodedString()
        let servers = VlessSubscriptionService.parseSubscription(b64)
        XCTAssertEqual(servers.count, 2)
        XCTAssertEqual(servers.first?.name, "A")
    }

    func testParsesRawSubscriptionWithJunkLines() {
        let body = """
        vless://a@1.1.1.1:443?type=tcp&security=reality#A
        # comment line
        ss://ignored@host:1
        vless://b@2.2.2.2:443?type=tcp&security=reality#B
        """
        let servers = VlessSubscriptionService.parseSubscription(body)
        XCTAssertEqual(servers.count, 2)
    }
}
