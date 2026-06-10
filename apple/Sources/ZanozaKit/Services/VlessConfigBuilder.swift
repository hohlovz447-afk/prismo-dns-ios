import Foundation

/// Builds the sing-box JSON config consumed by the embedded Singbox engine
/// from a parsed ``VlessServer``. Produces a local SOCKS inbound on
/// 127.0.0.1:<port> and a single VLESS outbound matching the server's
/// transport / security (Reality, TLS, gRPC, WS).
public enum VlessConfigBuilder {
    /// Builds the sing-box config JSON string for `server`, listening for
    /// SOCKS on `socksPort`.
    public static func buildJSON(for server: VlessServer, socksPort: Int) throws -> String {
        let config = buildDictionary(for: server, socksPort: socksPort)
        let data = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        )
        guard let json = String(data: data, encoding: .utf8) else {
            throw VlessConfigError.encodingFailed
        }
        return json
    }

    static func buildDictionary(for server: VlessServer, socksPort: Int) -> [String: Any] {
        var outbound: [String: Any] = [
            "type": "vless",
            "tag": "proxy",
            "server": server.host,
            "server_port": server.port,
            "uuid": server.uuid,
        ]
        if let flow = server.flow, !flow.isEmpty {
            outbound["flow"] = flow
        }

        // TLS block (Reality or plain TLS).
        if server.security == .reality || server.security == .tls {
            var tls: [String: Any] = ["enabled": true]
            if let sni = server.sni, !sni.isEmpty {
                tls["server_name"] = sni
            }
            if let fp = server.fingerprint, !fp.isEmpty {
                tls["utls"] = ["enabled": true, "fingerprint": fp]
            }
            if server.security == .reality {
                var reality: [String: Any] = ["enabled": true]
                if let pbk = server.publicKey, !pbk.isEmpty {
                    reality["public_key"] = pbk
                }
                if let sid = server.shortID, !sid.isEmpty {
                    reality["short_id"] = sid
                }
                tls["reality"] = reality
            }
            outbound["tls"] = tls
        }

        // Transport block (gRPC / WS). TCP needs no transport key.
        switch server.transport {
        case .grpc:
            outbound["transport"] = [
                "type": "grpc",
                "service_name": server.serviceName ?? "",
            ]
        case .ws:
            var ws: [String: Any] = ["type": "ws"]
            if let path = server.path, !path.isEmpty { ws["path"] = path }
            if let host = server.hostHeader, !host.isEmpty {
                ws["headers"] = ["Host": host]
            }
            outbound["transport"] = ws
        case .http:
            var http: [String: Any] = ["type": "http"]
            if let path = server.path, !path.isEmpty { http["path"] = path }
            outbound["transport"] = http
        case .tcp, .quic, .kcp:
            break
        }

        let inbound: [String: Any] = [
            "type": "socks",
            "tag": "socks-in",
            "listen": "127.0.0.1",
            "listen_port": socksPort,
            "sniff": true,
        ]

        return [
            "log": ["level": "warn", "timestamp": true],
            "inbounds": [inbound],
            "outbounds": [
                outbound,
                ["type": "direct", "tag": "direct"],
            ],
        ]
    }
}

public enum VlessConfigError: LocalizedError {
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return AppLocalization.string("Failed to build the server configuration.")
        }
    }
}
