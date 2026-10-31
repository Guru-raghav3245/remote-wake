// C API over a userspace Tailscale node + SSH client, built as a shared library (Dart FFI / JNI can load it).
//
//	rw_start(stateDir, authKey)  start the node (non-blocking)
//	rw_state()                   JSON {"state","authUrl","ips"}
//	rw_exec(addr, user, cmd)     run one command over Tailscale SSH, returns combined output (or "ERROR: ...")
//	rw_free(p)                   free any returned string
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"time"
	"unsafe"

	"net"
	"os"

	"golang.org/x/crypto/ssh"
	"tailscale.com/net/netmon"
	"tailscale.com/tsnet"
)

// Android 11+ denies apps the netlink calls behind net.Interfaces ("netlinkrib: permission denied"), which breaks the
// node's network monitor. Tailscale's own Android app solves it the same way: hand netmon a minimal interface list.
// ponytail: one fake "wlan0" holding the address the kernel would use to reach the internet (found without netlink by
// connecting a UDP socket, nothing is sent); no IPv6, no multi-interface awareness. Upgrade: pass the real list from Java.
func init() {
	netmon.RegisterInterfaceGetter(func() ([]netmon.Interface, error) {
		lo := netmon.Interface{Interface: &net.Interface{Index: 1, MTU: 65536, Name: "lo", Flags: net.FlagUp | net.FlagLoopback | net.FlagRunning},
			AltAddrs: []net.Addr{&net.IPNet{IP: net.IPv4(127, 0, 0, 1), Mask: net.CIDRMask(8, 32)}}}
		c, err := net.Dial("udp4", "8.8.8.8:80")
		if err != nil {
			return []netmon.Interface{lo}, nil
		}
		defer c.Close()
		ip := c.LocalAddr().(*net.UDPAddr).IP
		wlan := netmon.Interface{Interface: &net.Interface{Index: 2, MTU: 1500, Name: "wlan0", Flags: net.FlagUp | net.FlagBroadcast | net.FlagMulticast | net.FlagRunning},
			AltAddrs: []net.Addr{&net.IPNet{IP: ip, Mask: net.CIDRMask(24, 32)}}}
		return []netmon.Interface{lo, wlan}, nil
	})
}

var (
	mu  sync.Mutex
	srv *tsnet.Server
)

//export rw_start
func rw_start(stateDir, authKey *C.char) *C.char {
	mu.Lock()
	defer mu.Unlock()
	if srv != nil {
		return C.CString("")
	}
	// Android apps have no HOME/XDG_CACHE_HOME, and Tailscale's log policy panics ("no safe place found to store log state")
	// when it cannot find a cache dir. Point both at the app's own directory.
	os.Setenv("HOME", C.GoString(stateDir))
	os.Setenv("XDG_CACHE_HOME", C.GoString(stateDir))
	s := &tsnet.Server{Dir: C.GoString(stateDir), Hostname: "rw-phone", AuthKey: C.GoString(authKey)}
	if err := s.Start(); err != nil {
		return C.CString("ERROR: " + err.Error())
	}
	srv = s
	return C.CString("")
}

//export rw_state
func rw_state() *C.char {
	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return C.CString(`{"state":"NotStarted"}`)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	lc, err := s.LocalClient()
	if err != nil {
		return C.CString(`{"state":"Error"}`)
	}
	st, err := lc.Status(ctx)
	if err != nil {
		return C.CString(`{"state":"Error"}`)
	}
	ips := []string{}
	for _, ip := range st.TailscaleIPs {
		ips = append(ips, ip.String())
	}
	b, _ := json.Marshal(map[string]any{"state": st.BackendState, "authUrl": st.AuthURL, "ips": ips})
	return C.CString(string(b))
}

//export rw_exec
func rw_exec(addr, user, cmd *C.char) *C.char {
	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return C.CString("ERROR: not started")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	conn, err := s.Dial(ctx, "tcp", C.GoString(addr))
	if err != nil {
		return C.CString("ERROR: dial: " + err.Error())
	}
	c, chans, reqs, err := ssh.NewClientConn(conn, C.GoString(addr), &ssh.ClientConfig{
		User: C.GoString(user), HostKeyCallback: ssh.InsecureIgnoreHostKey(), Timeout: 30 * time.Second, // ponytail: pin host key in the real app
	})
	if err != nil {
		return C.CString("ERROR: ssh: " + err.Error())
	}
	cl := ssh.NewClient(c, chans, reqs)
	defer cl.Close()
	sess, err := cl.NewSession()
	if err != nil {
		return C.CString("ERROR: session: " + err.Error())
	}
	out, err := sess.CombinedOutput(C.GoString(cmd))
	if err != nil {
		return C.CString(fmt.Sprintf("%sERROR: %v", out, err))
	}
	return C.CString(string(out))
}

//export rw_free
func rw_free(p *C.char) { C.free(unsafe.Pointer(p)) }

func main() {}
