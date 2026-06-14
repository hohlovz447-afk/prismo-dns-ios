// ==============================================================================
// PrismoVPN
// Author: Prismo
// Github: https://github.com/prismo
// Year: 2026
// ==============================================================================
package handlers

import (
	Enums "prismo-dns-go/internal/enums"
	VpnProto "prismo-dns-go/internal/vpnproto"
	"net"
)

func init() {
	RegisterHandler(Enums.PACKET_DNS_QUERY_REQ_ACK, handleDNSQueryAck)
	RegisterHandler(Enums.PACKET_DNS_QUERY_RES, handleDNSQueryRes)
}

func handleDNSQueryAck(c ClientContext, packet VpnProto.Packet, addr *net.UDPAddr) error {
	return c.HandleDNSQueryAck(packet)
}

func handleDNSQueryRes(c ClientContext, packet VpnProto.Packet, addr *net.UDPAddr) error {
	return c.HandleDNSQueryRes(packet)
}
