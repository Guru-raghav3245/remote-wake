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
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
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
func rw_start(stateDir, authKey, hostname *C.char) *C.char {
	mu.Lock()
	defer mu.Unlock()
	if srv != nil {
		return C.CString("")
	}
	// Android apps have no HOME/XDG_CACHE_HOME, and Tailscale's log policy panics ("no safe place found to store log state")
	// when it cannot find a cache dir. Point both at the app's own directory.
	os.Setenv("HOME", C.GoString(stateDir))
	os.Setenv("XDG_CACHE_HOME", C.GoString(stateDir))
	s := &tsnet.Server{Dir: C.GoString(stateDir), Hostname: C.GoString(hostname), AuthKey: C.GoString(authKey)}
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
	type peer struct {
		Name   string `json:"name"`
		IP     string `json:"ip"`
		OS     string `json:"os"`
		Online bool   `json:"online"`
	}
	peers := []peer{}
	for _, p := range st.Peer {
		if len(p.TailscaleIPs) > 0 {
			peers = append(peers, peer{p.HostName, p.TailscaleIPs[0].String(), p.OS, p.Online})
		}
	}
	b, _ := json.Marshal(map[string]any{"state": st.BackendState, "authUrl": st.AuthURL, "ips": ips, "peers": peers})
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

// ---- interactive shell ----

type shell struct {
	cl      *ssh.Client
	sess    *ssh.Session
	in      io.WriteCloser
	mu      sync.Mutex
	buf     []byte
	done    bool
	dropped bool // connection lost (not a normal exit)
	ready   chan struct{} // poked when output arrives or the shell ends, so rw_shell_wait can return at once
}

var (
	shells  = map[int]*shell{}
	nextID  = 1
	lastErr string
	banner  string // SSH banner from the server (Tailscale puts its re-approval link here)
	lastKey string
)

//export rw_last_hostkey
func rw_last_hostkey() *C.char { mu.Lock(); defer mu.Unlock(); return C.CString(lastKey) }

func fail(err error) C.int { mu.Lock(); lastErr = err.Error(); mu.Unlock(); return -1 }

//export rw_last_error
func rw_last_error() *C.char { mu.Lock(); defer mu.Unlock(); return C.CString(lastErr) }

//export rw_last_banner
func rw_last_banner() *C.char { mu.Lock(); defer mu.Unlock(); return C.CString(banner) }

//export rw_shell_open
func rw_shell_open(addr, user, pinned *C.char, cols, rows C.int) C.int {
	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return fail(fmt.Errorf("not started"))
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	conn, err := s.Dial(ctx, "tcp", C.GoString(addr))
	if err != nil {
		return fail(fmt.Errorf("dial: %w", err))
	}
	mu.Lock()
	banner = ""
	mu.Unlock()
	// 3 min: a Tailscale "check" policy holds the handshake until the user approves in a browser; a dead server must not hang forever
	conn.SetDeadline(time.Now().Add(3 * time.Minute))
	c, chans, reqs, err := ssh.NewClientConn(conn, C.GoString(addr), &ssh.ClientConfig{
		User: C.GoString(user), Timeout: 30 * time.Second,
		BannerCallback: func(m string) error { mu.Lock(); banner += m; mu.Unlock(); return nil },
		// trust on first use: the app stores the fingerprint it saw (rw_last_hostkey) and passes it back as `pinned`
		HostKeyCallback: func(_ string, _ net.Addr, k ssh.PublicKey) error {
			fp := ssh.FingerprintSHA256(k)
			mu.Lock()
			lastKey = fp
			mu.Unlock()
			if pin := C.GoString(pinned); pin != "" && pin != fp {
				return fmt.Errorf("HOSTKEY_CHANGED")
			}
			return nil
		},
	})
	if err != nil {
		return fail(fmt.Errorf("ssh: %w", err))
	}
	conn.SetDeadline(time.Time{})
	cl := ssh.NewClient(c, chans, reqs)
	sess, err := cl.NewSession()
	if err != nil {
		cl.Close()
		return fail(err)
	}
	if err := sess.RequestPty("xterm-256color", int(rows), int(cols), ssh.TerminalModes{ssh.ECHO: 1}); err != nil {
		cl.Close()
		return fail(err)
	}
	in, _ := sess.StdinPipe()
	out, _ := sess.StdoutPipe() // with a PTY the remote merges stderr into stdout
	if err := sess.Shell(); err != nil {
		cl.Close()
		return fail(err)
	}
	sh := &shell{cl: cl, sess: sess, in: in, ready: make(chan struct{}, 1)}
	go func() {
		b := make([]byte, 32*1024)
		for {
			n, err := out.Read(b)
			sh.mu.Lock()
			sh.buf = append(sh.buf, b[:n]...)
			if err != nil {
				sh.done = true
			}
			sh.mu.Unlock()
			select {
			case sh.ready <- struct{}{}:
			default:
			}
			if err != nil {
				return
			}
		}
	}()
	go func() { // exit status tells a typed `exit` from a lost connection
		err := sess.Wait()
		var ee *ssh.ExitError
		sh.mu.Lock()
		sh.dropped = err != nil && !errors.As(err, &ee)
		sh.mu.Unlock()
	}()
	go func() { // keepalive: a silently dead network is noticed in ~15 s instead of minutes
		for {
			time.Sleep(5 * time.Second)
			sh.mu.Lock()
			d := sh.done
			sh.mu.Unlock()
			if d {
				return
			}
			ok := make(chan error, 1)
			go func() { _, _, e := cl.SendRequest("keepalive@openssh.com", true, nil); ok <- e }()
			select {
			case e := <-ok:
				if e != nil {
					cl.Close()
					return
				}
			case <-time.After(10 * time.Second):
				cl.Close()
				return
			}
		}
	}()
	mu.Lock()
	id := nextID
	nextID++
	shells[id] = sh
	mu.Unlock()
	return C.int(id)
}

func getShell(id C.int) *shell { mu.Lock(); defer mu.Unlock(); return shells[int(id)] }

//export rw_shell_read
func rw_shell_read(id C.int) *C.char {
	sh := getShell(id)
	if sh == nil {
		return C.CString("")
	}
	sh.mu.Lock()
	b := sh.buf
	sh.buf = nil
	sh.mu.Unlock()
	return C.CString(base64.StdEncoding.EncodeToString(b))
}

// Blocks until output is waiting, the shell ended, or ms elapsed. Lets the app react to output at once instead of polling on a timer.
//
//export rw_shell_wait
func rw_shell_wait(id, ms C.int) {
	sh := getShell(id)
	if sh == nil {
		return
	}
	sh.mu.Lock()
	has := len(sh.buf) > 0 || sh.done
	sh.mu.Unlock()
	if has {
		return
	}
	select {
	case <-sh.ready:
	case <-time.After(time.Duration(ms) * time.Millisecond):
	}
}

//export rw_shell_alive
func rw_shell_alive(id C.int) C.int {
	sh := getShell(id)
	if sh == nil {
		return 0
	}
	sh.mu.Lock()
	defer sh.mu.Unlock()
	if sh.done && len(sh.buf) == 0 {
		return 0
	}
	return 1
}

//export rw_shell_write
func rw_shell_write(id C.int, b64 *C.char) {
	if sh := getShell(id); sh != nil {
		if b, err := base64.StdEncoding.DecodeString(C.GoString(b64)); err == nil {
			sh.in.Write(b)
		}
	}
}

//export rw_shell_resize
func rw_shell_resize(id, cols, rows C.int) {
	if sh := getShell(id); sh != nil {
		sh.sess.WindowChange(int(rows), int(cols))
	}
}

//export rw_shell_dropped
func rw_shell_dropped(id C.int) C.int {
	sh := getShell(id)
	if sh == nil {
		return 0
	}
	sh.mu.Lock()
	defer sh.mu.Unlock()
	if sh.dropped {
		return 1
	}
	return 0
}

//export rw_shell_close
func rw_shell_close(id C.int) {
	mu.Lock()
	sh := shells[int(id)]
	delete(shells, int(id))
	mu.Unlock()
	if sh != nil {
		sh.cl.Close()
	}
}
