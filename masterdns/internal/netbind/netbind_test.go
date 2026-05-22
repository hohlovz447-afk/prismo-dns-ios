package netbind

import (
	"net"
	"sync/atomic"
	"testing"
	"time"
)

func TestCurrentDefaultsToEmpty(t *testing.T) {
	SetInterface("")
	if got := Current(); got != "" {
		t.Errorf("Current after reset = %q, want empty", got)
	}
}

func TestSetInterfaceFiresOnChangeOnDistinctValues(t *testing.T) {
	SetInterface("")
	var count int32
	handle := OnChange(func() { atomic.AddInt32(&count, 1) })
	defer RemoveHook(handle)

	SetInterface("en0")
	SetInterface("en0") // identical → no-op
	SetInterface("pdp_ip0")
	SetInterface("")

	if got := atomic.LoadInt32(&count); got != 3 {
		t.Errorf("OnChange fired %d times, want 3", got)
	}
}

func TestRemoveHookStopsCallbacks(t *testing.T) {
	SetInterface("")
	var count int32
	handle := OnChange(func() { atomic.AddInt32(&count, 1) })

	SetInterface("en0")
	if atomic.LoadInt32(&count) != 1 {
		t.Fatalf("hook never fired before remove")
	}
	RemoveHook(handle)

	SetInterface("pdp_ip0")
	if got := atomic.LoadInt32(&count); got != 1 {
		t.Errorf("hook fired after RemoveHook: count=%d", got)
	}
}

func TestDialUDPWithoutBindingMatchesNetDial(t *testing.T) {
	SetInterface("")

	echo, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0})
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer echo.Close()

	go func() {
		buf := make([]byte, 64)
		_ = echo.SetReadDeadline(time.Now().Add(2 * time.Second))
		n, addr, err := echo.ReadFromUDP(buf)
		if err != nil {
			return
		}
		_, _ = echo.WriteToUDP(buf[:n], addr)
	}()

	addr, ok := echo.LocalAddr().(*net.UDPAddr)
	if !ok {
		t.Fatalf("unexpected local addr type %T", echo.LocalAddr())
	}
	conn, err := DialUDP("udp", addr)
	if err != nil {
		t.Fatalf("DialUDP: %v", err)
	}
	defer conn.Close()

	_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err := conn.Write([]byte("ping")); err != nil {
		t.Fatalf("write: %v", err)
	}
	buf := make([]byte, 16)
	n, err := conn.Read(buf)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if string(buf[:n]) != "ping" {
		t.Errorf("echo mismatch: %q", buf[:n])
	}
}

func TestDialUDPWithLoopbackBindingSucceedsOnDarwin(t *testing.T) {
	// lo0 is always present on Darwin and on Linux test runners too.
	if _, err := net.InterfaceByName("lo0"); err != nil {
		t.Skip("lo0 not present; skipping interface-binding test")
	}
	SetInterface("lo0")
	defer SetInterface("")

	echo, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0})
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer echo.Close()
	addr, ok := echo.LocalAddr().(*net.UDPAddr)
	if !ok {
		t.Fatalf("unexpected local addr type %T", echo.LocalAddr())
	}

	conn, err := DialUDP("udp", addr)
	if err != nil {
		t.Fatalf("DialUDP with lo0 binding: %v", err)
	}
	conn.Close()
}
