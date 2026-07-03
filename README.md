# Syncwell

<!-- After pushing to GitHub, replace Nil-Vaghani/REPO to activate the badge. -->
[![CI](https://github.com/Nil-Vaghani/REPO/actions/workflows/ci.yml/badge.svg)](https://github.com/Nil-Vaghani/REPO/actions/workflows/ci.yml)
&nbsp;![Go](https://img.shields.io/badge/Go-1.23-00ADD8) ![License](https://img.shields.io/badge/license-MIT-blue)

**Add multiplayer — live cursors, presence, and conflict-free shared state — to any app with a few lines of code. Self-hostable, single binary, language-agnostic.**

Syncwell is an open-source, self-hostable real-time collaboration engine — an alternative to closed SaaS like Liveblocks and PartyKit. Drop in the client SDK, point it at a Syncwell server, and your users get Google-Docs-style live sync. The server compiles to a single dependency-free binary you can run anywhere.

```
┌──────────┐   ws    ┌─────────────────────┐   ws   ┌──────────┐
│ Client A │◀───────▶│  Syncwell server     │◀──────▶│ Client B │
│ (browser)│         │  • CRDT per room     │        │ (browser)│
└──────────┘         │  • presence relay    │        └──────────┘
                     │  • single 8 MB binary│
                     └─────────────────────┘
```

> **Note.** The Go engine (CRDT core, hub state machine, persistence,
> auth) is intentionally **not** in this repository. It is consumed as a
> private Go module so the convergence algorithm and protocol can be
> iterated on without exposing the implementation. The public surface
> of the engine is documented in `pkg/engine` of the private repo and
> consists of six symbols: `Hub`, `Config`, `NewHub`, `SignToken`,
> `Store`, `Open`. Everything else is implementation detail.

## Architecture in one screen

- **CRDT per room.** Each collaborative document is a
  Last-Writer-Wins map keyed by string. Concurrent writes are merged
  by `(timestamp, clientID)` ordering, so any pair of replicas that
  have seen the same set of ops converge to byte-identical state —
  no central coordinator needed, no merge conflicts to resolve.
- **Lamport clocks, not wall clocks.** Every op carries a Lamport
  timestamp. Clocks advance on every local event and on every
  received op, so causality is preserved without trusting client
  clocks. This is what makes the offline-then-reconnect story work.
- **One goroutine owns one room.** All writes to a CRDT happen on
  the room's goroutine, so there are **no locks** in the hot path.
  Cross-room concurrency is message passing on a hub. This is
  structured concurrency (the same shape as a `select`-driven event
  loop) and it is what keeps the server at 11 MB RSS under load.
- **Tombstone GC via causal-stability low-water mark.** Deletes are
  retained as tombstones so a late-arriving op can still lose to
  them. The hub tracks a per-room low-water mark (the smallest
  timestamp it has heard *acked* from every connected client) and
  compacts tombstones below it. This is the "40 deletes collapse to
  ~1" claim — see [docs/PROTOCOL.md](docs/PROTOCOL.md) for the
  proof and `internal/crdt/gc_test.go` for the test.

Full design rationale, including why CRDT over Operational
Transform and the tombstone-growth problem with its fix, lives in
the private engine repo's [DESIGN.md]. The public surface of that
doc is mirrored here in [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Why it exists

Real-time collaboration is something every product wants and few build well: concurrent edits, offline clients, and reconnection are genuinely hard. The hosted options are proprietary and per-seat priced. Syncwell gives you the same capability as an MIT-licensed binary you own.

## Status & numbers

Offline-capable, durable, and bounded-memory. Clients edit locally (even while
disconnected) and converge on reconnect; the server persists to disk, survives
`kill -9`, and garbage-collects tombstones so a long-lived room stays small.

**Measured** (50 concurrent clients, one room, single box — reproduce with `make bench` from the engine repo):

| metric | value |
| --- | --- |
| sync latency p50 / p95 / p99 | **1.3 / 2.5 / 3.6 ms** |
| delivery throughput | **~9,000 msg/s** |
| server memory (RSS) | **11.5 MB** |
| binary size | single **~8 MB** static binary, zero runtime deps |

**Proven correct** (all green from the engine repo's `make all`):
- ⚡ CRDT laws — commutativity, associativity, idempotence (Go + JS suites)
- 💥 **Convergence under chaos** — 5 replicas × 3000 ops with partitions,
  reordering, and duplicate delivery converge byte-identical
- 🔌 **Offline → reconnect** convergence with no lost edits
- 💾 **Durability** across `kill -9` + restart
- 🗑️ **Tombstone GC** — 40 deletes collapse to ~1 via the
  causal-stability low-water mark

The public repo verifies the client-side CRDT
(`sdk/crdt.test.js`) and that the binary builds. The full Go test
suite — including the chaos, persistence, and GC scenarios — lives
in the private engine repo.

_Still ahead (see [docs/ROADMAP.md](docs/ROADMAP.md)): hosted demo URL, npm SDK,
GitHub stars / Docker pulls / self-hosting users._

## Quickstart

```bash
# Build the public binary (requires the private engine module — see DEPLOY.md)
docker build -t syncwell .
docker run -p 8080:8080 syncwell
# open http://localhost:8080            → simple text demo (two windows)
# open http://localhost:8080/kanban.html → collaborative kanban (drag cards live)
```

### Production knobs (all optional)

```bash
syncwell \
  -data ./data \                 # persist to disk (survives restart)
  -secret "$SECRET" \            # require room tokens (HMAC, expiring)
  -origins https://app.example \ # Origin allow-list
  -max-clients 200               # per-room cap

# issue a 24h token for a room:
syncwell -secret "$SECRET" -mint my-room
# clients connect with ws://host/ws?room=my-room&token=<token>
```

Use it from the browser:

```js
import { Syncwell } from "./sdk/syncwell.js";

const sw = new Syncwell("ws://localhost:8080/ws", "my-room");
sw.on("snapshot", ({ state }) => render(state));
sw.on("op", ({ key, register }) => applyChange(key, register));
sw.connect();

sw.set("title", "Hello, multiplayer");   // syncs to everyone in "my-room"
sw.presence({ cursor: { x: 12, y: 40 } }); // ephemeral, not persisted
```

## How it works

A **room** is one collaborative document, backed by a CRDT so
concurrent edits merge without conflicts. Each room is owned by a
single goroutine that is the only code allowed to touch the document
— so there are **no locks**, and concurrency is structured as message
passing. Clients get a full **snapshot** on join, then a stream of
**ops**; ephemeral **presence** (cursors, who's-online) is relayed
but never stored. Lamport timestamps on every op mean that late
arrivals, replays, and offline-then-reconnect all converge to the
same state.

## Layout

```
cmd/syncwell/      single-binary entrypoint (HTTP + WebSocket)
demo/              runnable multiplayer demo (open in two windows)
sdk/               zero-dependency browser/Node client
docs/              PROTOCOL.md, ROADMAP.md
```

## Deployment

See **[DEPLOY.md](DEPLOY.md)** for the end-to-end deployment guide
(Render.com, secrets, private-module fetch, verification).

## Roadmap

Phased so each step is independently shippable — see **[docs/ROADMAP.md](docs/ROADMAP.md)**.
Phase 1 ✅ shared state + presence · Phase 2 offline/client-side CRDT + persistence · Phase 3 SDK polish, auth, Docker release · Stretch: horizontal scaling.

## License

MIT — see [LICENSE](LICENSE).
