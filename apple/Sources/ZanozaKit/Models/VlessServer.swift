import Foundation

/// A single VLESS server parsed from a `vless://` subscription link.
///
/// Mirrors the link shapes produced by the Prismo backend
/// (`app/api/webhooks/subscription.py`): VLESS over TCP/gRPC/WS with
/// Reality or plain TLS security.
public struct VlessServer: Identifiable, Equatable {
    public enum Transport: String, Equatable {
        case tcp
        case grpc
        case ws
        case http
        case quic
        case kcp
    }

    public enum Security: String, Equatable {
        case reality
        case tls
        case none
    }

    public let id: UUID
    /// Display label from the link fragment (`#...`), usually includes country.
    public let name: String
    public let uuid: String
    public let host: String
    public let port: Int
    public let transport: Transport
    public let security: Security
    public let sni: String?
    public let fingerprint: String?
    public let flow: String?
    /// Reality public key (`pbk`).
    public let publicKey: String?
    /// Reality short id (`sid`).
    public let shortID: String?
    /// gRPC service name (`serviceName`).
    public let serviceName: String?
    /// WS / HTTP path.
    public let path: String?
    /// WS / HTTP host header.
    public let hostHeader: String?

    public init(
        id: UUID = UUID(),
        name: String,
        uuid: String,
        host: String,
        port: Int,
        transport: Transport,
        security: Security,
        sni: String? = nil,
        fingerprint: String? = nil,
        flow: String? = nil,
        publicKey: String? = nil,
        shortID: String? = nil,
        serviceName: String? = nil,
        path: String? = nil,
        hostHeader: String? = nil
    ) {
        self.id = id
        self.name = name
        self.uuid = uuid
        self.host = host
        self.port = port
        self.transport = transport
        self.security = security
        self.sni = sni
        self.fingerprint = fingerprint
        self.flow = flow
        self.publicKey = publicKey
        self.shortID = shortID
        self.serviceName = serviceName
        self.path = path
        self.hostHeader = hostHeader
    }

    /// Best-effort country/label for the UI, taken from the fragment name.
    public var displayName: String {
        name.isEmpty ? "\(host):\(port)" : name
    }
}
