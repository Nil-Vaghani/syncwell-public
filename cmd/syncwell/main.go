// Command syncwell runs the collaboration engine: a websocket sync endpoint at
// /ws plus the static demo pages at / and the browser SDK at /sdk/. It
// compiles to a single self-contained binary with no runtime dependencies.
//
// The engine (CRDT, hub, persistence, auth) is consumed as a private Go
// module: see pkg/engine in github.com/Nil-Vaghani/syncwell-engine. The public
// surface of this binary is a small set of HTTP handlers wired into a
// single hub.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/Nil-Vaghani/syncwell-engine/pkg/engine"
)

func main() {
	addr := flag.String("addr", envOr("SYNCWELL_ADDR", ":8080"), "listen address")
	static := flag.String("static", "demo", "directory of static files to serve at / (skipped if missing)")
	sdk := flag.String("sdk", "sdk", "directory of the client SDK to serve at /sdk/ (skipped if missing)")
	data := flag.String("data", envOr("SYNCWELL_DATA", ""), "data directory for persistence (empty = in-memory)")
	compact := flag.Int("compact", 256, "winning writes between maintenance passes (tombstone GC + compaction)")
	secret := flag.String("secret", envOr("SYNCWELL_SECRET", ""), "HMAC secret for room tokens (empty = auth disabled)")
	origins := flag.String("origins", envOr("SYNCWELL_ORIGINS", ""), "comma-separated allowed Origins (empty = allow any)")
	maxClients := flag.Int("max-clients", 0, "max clients per room (0 = unlimited)")
	mint := flag.String("mint", "", "issue a token for this room and exit (requires -secret)")
	ttl := flag.Duration("ttl", 24*time.Hour, "token lifetime for -mint")
	flag.Parse()

	// Token-minting helper: `syncwell -secret S -mint room` prints a token.
	if *mint != "" {
		if *secret == "" {
			log.Fatal("-mint requires -secret")
		}
		fmt.Println(engine.SignToken(*secret, *mint, time.Now().Add(*ttl).Unix()))
		return
	}

	var st engine.Store
	if *data != "" {
		fs, err := engine.Open(*data)
		if err != nil {
			log.Fatalf("open data dir %q: %v", *data, err)
		}
		st = fs
		log.Printf("persistence enabled at %s/", *data)
	}

	var allowedOrigins []string
	if *origins != "" {
		allowedOrigins = strings.Split(*origins, ",")
	}
	hub := engine.NewHub(engine.Config{
		Store:        st,
		CompactEvery: *compact,
		Secret:       *secret,
		Origins:      allowedOrigins,
		MaxClients:   *maxClients,
	})
	if *secret != "" {
		log.Print("room-token auth enabled")
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", hub.ServeWS)
	mux.HandleFunc("/stats", hub.ServeStats)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	})
	// Serve the client SDK at /sdk/ so the demo can import it with an absolute
	// path regardless of where the static root is.
	if _, err := os.Stat(*sdk); err == nil {
		mux.Handle("/sdk/", http.StripPrefix("/sdk/", http.FileServer(http.Dir(*sdk))))
	}
	if _, err := os.Stat(*static); err == nil {
		mux.Handle("/", http.FileServer(http.Dir(*static)))
		log.Printf("serving demo from %s/", *static)
	}

	srv := &http.Server{Addr: *addr, Handler: mux}

	// Graceful shutdown: drain connections and flush persistence on SIGINT/TERM.
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
		<-sig
		log.Print("shutting down…")
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(ctx)
		if st != nil {
			_ = st.Close()
		}
	}()

	log.Printf("syncwell listening on %s  (websocket: /ws?room=ID)", *addr)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
