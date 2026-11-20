// Command loadgen drives traffic through an xray SOCKS inbound for benchmarking.
//
//	loadgen target -listen :443            TLS 1.3 site used as the REALITY target
//	loadgen sink   -listen :9000           data server (inner TLS, like real HTTPS traffic)
//	loadgen run    -socks xc:1080 -dst sink:9000 -mode down|churn|idle ...
package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		log.Fatal("usage: loadgen target|sink|run [flags]")
	}
	fs := flag.NewFlagSet(os.Args[1], flag.ExitOnError)
	listen := fs.String("listen", ":9000", "listen address (target/sink)")
	socks := fs.String("socks", "127.0.0.1:1080", "SOCKS5 proxy")
	dst := fs.String("dst", "sink:9000", "sink address as seen by the proxy server")
	mode := fs.String("mode", "down", "down | churn | idle")
	conns := fs.Int("conns", 8, "parallel connections / workers")
	size := fs.Int64("bytes", 1<<30, "bytes per connection (down, churn)")
	total := fs.Int("total", 2000, "churn: total connections")
	dur := fs.Duration("dur", 30*time.Second, "idle: how long to hold connections")
	interval := fs.Duration("interval", 5*time.Second, "idle: ping interval per connection")
	_ = fs.Parse(os.Args[2:])

	switch os.Args[1] {
	case "target":
		serveTarget(*listen)
	case "sink":
		serveSink(*listen)
	case "run":
		run(*socks, *dst, *mode, *conns, *size, *total, *dur, *interval)
	default:
		log.Fatalf("unknown command %q", os.Args[1])
	}
}

func selfSigned(name string) tls.Certificate {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		log.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1), DNSNames: []string{name},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(24 * time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		log.Fatal(err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
}

// serveTarget answers like a tiny HTTPS site so REALITY can borrow its handshake.
func serveTarget(addr string) {
	cfg := &tls.Config{Certificates: []tls.Certificate{selfSigned("bench.local")}, MinVersion: tls.VersionTLS13, NextProtos: []string{"h2", "http/1.1"}}
	ln, err := tls.Listen("tcp", addr, cfg)
	if err != nil {
		log.Fatal(err)
	}
	for {
		c, err := ln.Accept()
		if err != nil {
			continue
		}
		go func() {
			defer c.Close()
			_ = c.SetDeadline(time.Now().Add(10 * time.Second))
			b := make([]byte, 4096)
			if _, err := c.Read(b); err == nil {
				_, _ = io.WriteString(c, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
			}
		}()
	}
}

const (
	opDown = 'D' // server sends n bytes
	opEcho = 'E' // server echoes until EOF
)

var junk = func() []byte { b := make([]byte, 64<<10); _, _ = rand.Read(b); return b }()

func serveSink(addr string) {
	cfg := &tls.Config{Certificates: []tls.Certificate{selfSigned("sink")}, MinVersion: tls.VersionTLS13}
	ln, err := tls.Listen("tcp", addr, cfg)
	if err != nil {
		log.Fatal(err)
	}
	for {
		c, err := ln.Accept()
		if err != nil {
			continue
		}
		go func() {
			defer c.Close()
			var hdr [9]byte
			if _, err := io.ReadFull(c, hdr[:]); err != nil {
				return
			}
			n := int64(binary.BigEndian.Uint64(hdr[1:]))
			switch hdr[0] {
			case opDown:
				for n > 0 {
					k := min(n, int64(len(junk)))
					if _, err := c.Write(junk[:k]); err != nil {
						return
					}
					n -= k
				}
			case opEcho:
				_, _ = io.Copy(c, c)
			}
		}()
	}
}

// dial opens a SOCKS5 CONNECT to dst and wraps it in inner TLS.
func dial(socks, dst string) (net.Conn, error) {
	host, portStr, err := net.SplitHostPort(dst)
	if err != nil {
		return nil, err
	}
	port, _ := strconv.Atoi(portStr)
	c, err := net.DialTimeout("tcp", socks, 10*time.Second)
	if err != nil {
		return nil, err
	}
	_ = c.SetDeadline(time.Now().Add(15 * time.Second))
	req := append([]byte{5, 1, 0, 5, 1, 0, 3, byte(len(host))}, host...)
	req = binary.BigEndian.AppendUint16(req, uint16(port))
	if _, err := c.Write(req); err != nil {
		c.Close()
		return nil, err
	}
	var rep [12]byte // 2 (method) + 4 (header) + 4 (IPv4) + 2 (port)
	if _, err := io.ReadFull(c, rep[:]); err != nil || rep[1] != 0 || rep[3] != 0 {
		c.Close()
		return nil, fmt.Errorf("socks handshake failed: %v %v", err, rep)
	}
	tc := tls.Client(c, &tls.Config{ServerName: "sink", InsecureSkipVerify: true})
	if err := tc.Handshake(); err != nil {
		c.Close()
		return nil, err
	}
	_ = c.SetDeadline(time.Time{})
	return tc, nil
}

func header(op byte, n int64) []byte {
	h := []byte{op, 0, 0, 0, 0, 0, 0, 0, 0}
	binary.BigEndian.PutUint64(h[1:], uint64(n))
	return h
}

func run(socks, dst, mode string, conns int, size int64, total int, dur, interval time.Duration) {
	var bytesDone, connsDone, errs atomic.Int64
	start := time.Now()
	var wg sync.WaitGroup
	switch mode {
	case "down", "churn":
		var next atomic.Int64
		jobs := int64(conns)
		if mode == "churn" {
			jobs = int64(total)
		}
		for range conns {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for next.Add(1) <= jobs {
					c, err := dial(socks, dst)
					if err != nil {
						errs.Add(1)
						continue
					}
					_, _ = c.Write(header(opDown, size))
					n, err := io.Copy(io.Discard, c)
					c.Close()
					bytesDone.Add(n)
					if err != nil || n != size {
						errs.Add(1)
						continue
					}
					connsDone.Add(1)
				}
			}()
		}
	case "idle":
		ping := make([]byte, 256)
		for i := range conns {
			wg.Add(1)
			go func() {
				defer wg.Done()
				time.Sleep(time.Duration(i) * time.Millisecond) // don't open them all in the same instant
				c, err := dial(socks, dst)
				if err != nil {
					errs.Add(1)
					return
				}
				defer c.Close()
				connsDone.Add(1)
				_, _ = c.Write(header(opEcho, 0))
				buf := make([]byte, len(ping))
				for time.Since(start) < dur {
					if _, err := c.Write(ping); err != nil {
						errs.Add(1)
						return
					}
					if _, err := io.ReadFull(c, buf); err != nil {
						errs.Add(1)
						return
					}
					bytesDone.Add(int64(len(ping)))
					time.Sleep(interval)
				}
			}()
		}
	default:
		log.Fatalf("unknown mode %q", mode)
	}
	wg.Wait()
	el := time.Since(start).Seconds()
	fmt.Printf("mode=%s conns=%d ok=%d errors=%d bytes=%d secs=%.2f MBps=%.1f conn_per_s=%.1f\n",
		mode, conns, connsDone.Load(), errs.Load(), bytesDone.Load(), el,
		float64(bytesDone.Load())/el/1e6, float64(connsDone.Load())/el)
	if errs.Load() > 0 {
		os.Exit(1)
	}
}
