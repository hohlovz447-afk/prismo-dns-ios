// ==============================================================================
// PrismoVPN
// Author: Prismo
// Github: https://github.com/prismo
// Year: 2026
// ==============================================================================
package handlers

import (
	"net"

	Enums "prismo-dns-go/internal/enums"
	VpnProto "prismo-dns-go/internal/vpnproto"
)

func init() {
	RegisterHandler(Enums.PACKET_MTU_UP_RES, handleMTUResponse)
	RegisterHandler(Enums.PACKET_MTU_DOWN_RES, handleMTUResponse)
}

func handleMTUResponse(c ClientContext, packet VpnProto.Packet, addr *net.UDPAddr) error {
	return c.HandleMTUResponse(packet)
}
