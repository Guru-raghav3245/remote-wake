// Prototype: join the tailnet in userspace (tsnet, no VPN service, no root), open an SSH connection to a
// Tailscale SSH server and run a command. Usage: tsproto <state-dir> <host:port> <user> <command>
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"time"

	"golang.org/x/crypto/ssh"
	"tailscale.com/tsnet"
)

func main() {
	if len(os.Args) < 5 {
		log.Fatal("usage: tsproto <state-dir> <host:port> <user> <command>")
	}
	dir, addr, user, cmd := os.Args[1], os.Args[2], os.Args[3], os.Args[4]
	s := &tsnet.Server{Dir: dir, Hostname: "rw-proto", Ephemeral: true, AuthKey: os.Getenv("TS_AUTHKEY")}
	defer s.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	t0 := time.Now()
	st, err := s.Up(ctx) // prints a login URL to the log on first run
	if err != nil {
		log.Fatalf("up: %v", err)
	}
	fmt.Printf("joined as %v in %v\n", st.TailscaleIPs, time.Since(t0).Round(time.Millisecond))

	t1 := time.Now()
	conn, err := s.Dial(ctx, "tcp", addr)
	if err != nil {
		log.Fatalf("dial: %v", err)
	}
	// Tailscale SSH identifies the caller by its tailnet identity, so SSH auth is "none"; the host key is checked by Tailscale.
	c, chans, reqs, err := ssh.NewClientConn(conn, addr, &ssh.ClientConfig{
		User: user, HostKeyCallback: ssh.InsecureIgnoreHostKey(), Timeout: 30 * time.Second, // ponytail: pin the host key in the real app
	})
	if err != nil {
		log.Fatalf("ssh: %v", err)
	}
	sess, err := ssh.NewClient(c, chans, reqs).NewSession()
	if err != nil {
		log.Fatalf("session: %v", err)
	}
	out, err := sess.CombinedOutput(cmd)
	fmt.Printf("ssh connected+ran in %v, err=%v\n%s", time.Since(t1).Round(time.Millisecond), err, out)
}
