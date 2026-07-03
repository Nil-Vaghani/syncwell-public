# Deployment guide

This repository is the **public** Syncwell deployment. The Go engine
(CRDT, hub, persistence, auth) lives in a separate **private**
repository and is consumed as a private Go module at build time. This
file walks you through pushing both repos to GitHub, wiring secrets,
and shipping the demo to Render.com.

If anything here disagrees with what Render or GitHub shows in their
console, trust the console — this guide is correct as of the
tooling versions pinned in `go.mod`, `.github/workflows/ci.yml`, and
`Dockerfile`. Check the tool's release notes if you bump versions.

## 0. Before you start

You will need:

- A GitHub account with permission to create two repositories:
  one public, one private.
- A Render.com account.
  - **A credit card is required to create a Web Service**, even on
    the free tier. If you don't have one, see §12 below for
    alternatives.
- A place to keep two secrets: `SYNCWELL_SECRET` (32 random bytes)
  and a fine-scoped GitHub PAT. A password manager is fine; do not
  commit either value.
- Two repository names picked in advance. The rest of this guide
  assumes:
  - public:  `OWNER/syncwell-public`
  - private: `OWNER/syncwell-engine`

  Replace `OWNER` everywhere it appears below with your actual
  GitHub username. There is no automated way to do this — `grep -r
  OWNER .` will list every file that needs editing.

## 1. Important: read this before choosing Render

Render is a fine platform, but it has two constraints that are
relevant to a real-time collaboration engine like Syncwell. **Check
these against your needs before continuing.**

### 1.1 WebSocket idle timeout

Render terminates idle WebSocket connections after **5 minutes** on
all plans, including paid. There is no configuration to disable
this. This means:

- A kanban board that sits open with no activity will disconnect
  every 5 minutes. The client reconnects automatically (the SDK has
  reconnect logic with exponential backoff), and the CRDT
  convergence story still holds — but the visible "live cursor
  staying put for an hour" experience is not what Render delivers.
- For a public demo where the visitor is actively interacting, this
  is fine. For a production deployment, it isn't.

### 1.2 Free-tier sleep behavior

Free Web Services on Render **spin down after 15 minutes of
inactivity**. The first request after a sleep takes 30+ seconds
while the container boots. This makes the demo look broken if no
one has used it recently.

To avoid the sleep, you need a paid plan (Starter at $7/mo as of
this writing). The WebSocket timeout in §1.1 still applies.

### 1.3 Bottom line

If real-time persistence and zero-cold-start latency are the point
of the demo, Fly.io or Railway are better fits. Render is
**acceptable for a paid-tier deployment** but **not a great fit
for a free-tier demo** of a real-time engine. §12 lists
alternatives.

The rest of this guide assumes you've decided Render is right for
you and you're going to use a paid Web Service plan.

## 2. Create the private engine repo first

The public repo's `go.mod` requires the private one to exist with at
least one tagged release. Set it up first.

```bash
cd syncwell-engine

git init -b main
git add .
git commit -m "import: initial engine from monorepo split"

# Create the private repo on GitHub (web UI, or `gh repo create
# OWNER/syncwell-engine --private --source=. --remote=origin`).
git push -u origin main

# Tag a version. The public repo pins to a tag, not a branch, so a
# release here is intentional and reviewable.
git tag v0.1.0
git push origin v0.1.0
```

## 3. Create the public repo

```bash
cd syncwell-public

# Edit go.mod to pin to the tag you just pushed:
#   require github.com/OWNER/syncwell-engine v0.1.0
# (replace OWNER and v0.1.0 with your values)
$EDITOR go.mod

# Create the public repo on GitHub.
git init -b main
git add .
git commit -m "import: public demo, engine consumed as private module"
git push -u origin main
```

The first push will fail in CI if the engine tag doesn't exist yet,
because `go mod download` cannot resolve the private module. That is
expected. CI will pass once step 2 is complete.

## 4. Create a fine-scoped GitHub PAT

The build needs a token to fetch the private engine module. Make it
as small as possible:

- GitHub → Settings → Developer settings → Personal access tokens →
  Fine-grained tokens.
- Resource owner: yourself.
- Repository access: **Only select repositories** → `syncwell-engine`.
- Permissions: **Contents: Read-only**. Nothing else.
- Expiration: 90 days. Calendar a reminder to rotate.

Copy the token once into your password manager. You will paste it
into Render as a build-time environment variable in the next step.

## 5. Pre-generate the room-token secret

The server uses `SYNCWELL_SECRET` to mint room tokens. Generate it
once now so you can paste it into Render in step 6.

```bash
SYNCWELL_SECRET=$(openssl rand -hex 32)
echo "$SYNCWELL_SECRET"   # copy this value — paste into Render
```

## 6. Create the Render Web Service

The GitHub-side repo is ready. Now the Render-side setup. This is
the only step that requires the Render dashboard.

### 6.1 Create a new Web Service

1. Render dashboard → **New** → **Web Service**.
2. **Connect a repository**: select `OWNER/syncwell-public`. The
   first time, Render will ask you to grant GitHub access — grant
   access to *only* this repo (the principle of least privilege).
3. Fill in:
   - **Name**: `syncwell-demo` (or your choice; the public URL
     becomes `https://syncwell-demo.onrender.com`).
   - **Region**: closest to your audience. `Oregon (US West)` is
     the default; pick `Frankfurt` or `Singapore` for non-US users.
   - **Branch**: `main`.
   - **Runtime**: **Docker**.
   - **Instance type**: Starter ($7/mo) or higher. The free tier
     will spin down — see §1.2.
4. **Advanced** → **Health Check Path**: `/healthz`. (The Go
   binary serves this — see `cmd/syncwell/main.go:71-73`.)
5. **Advanced** → **Docker Command**: leave blank. The
   `Dockerfile`'s `ENTRYPOINT` is correct.

### 6.2 Set environment variables

In the same screen, scroll to **Environment Variables** and add:

| Key              | Value                              | Sync? |
| ---------------- | ---------------------------------- | ----- |
| `GITHUB_TOKEN`   | the PAT from step 4                | **No** (it's a secret) |
| `SYNCWELL_SECRET`| the hex string from step 5         | **No** (it's a secret) |
| `SYNCWELL_ORIGINS`| `https://YOUR-SERVICE.onrender.com` | No |
| `SYNCWELL_DATA`  | `/var/data/syncwell`               | No    |

> **What "Sync" does.** "Sync" is a Render feature that propagates
> the variable between services. We don't need that here — the
> values above are all for this one service. Leave it unchecked.

> **Why `GITHUB_TOKEN` is build-time, not runtime.** Render
> exposes the `GITHUB_TOKEN` env var to the Docker build (as a
> build-time env, which the Dockerfile receives via `ARG
> GITHUB_TOKEN`) and *also* to the running container. To make it
> build-time only — so it doesn't end up baked into the runtime
> image as a layer's env — Render supports marking the variable
> as "Available during build" in the dropdown next to the value.
> Set that to "Yes" for `GITHUB_TOKEN` and "No" for the others.

> **Why `/var/data/syncwell` is special.** On Render, `/var/data`
> is the only path that **persists across deploys** (you need a
> paid plan with a persistent disk for this to actually work —
> free Web Services have ephemeral filesystems). The
> `SYNCWELL_DATA` env var tells the Go binary to write its
> snapshot there. If you're on the free tier, leave this empty
> and accept that rooms are in-memory only — the demo still
> works, but state is lost on every deploy.

### 6.3 Add a persistent disk (paid plans only)

If you want state to survive deploys:

1. Render dashboard → your service → **Disks** → **Add Disk**.
2. **Name**: `syncwell-data`.
3. **Mount Path**: `/var/data`.
4. **Size**: 1 GB is plenty for hundreds of rooms.

### 6.4 Deploy

Click **Create Web Service**. The first build takes 3–5 minutes
(the Go module download is the slow part). Subsequent deploys are
faster because Render caches Docker layers.

Watch the build log. The line you want to see at the end is:

```
==> Build successful 🎉
==> Deploying...
```

If you see `==> Exited with status 1`, the most common cause is a
bad `GITHUB_TOKEN` (the build can't fetch the private engine
module). See §9.

## 7. Verify

End-to-end checks, in the order you should run them. Replace
`syncwell-demo` with your service name.

1. **Health endpoint responds.**
   ```bash
   curl -s https://syncwell-demo.onrender.com/healthz
   # expect: ok
   ```

2. **The demo page is served.**
   ```bash
   curl -s https://syncwell-demo.onrender.com/ | head -20
   # expect: HTML with a "Syncwell" string
   ```

3. **The SDK is reachable.**
   ```bash
   curl -sI https://syncwell-demo.onrender.com/sdk/syncwell.js
   # expect: HTTP/2 200
   ```

4. **WebSocket sync works in a browser.** Open
   `https://syncwell-demo.onrender.com/kanban.html` in two browser
   windows. Drag a card in one; it should move in the other within
   ~50 ms. If it doesn't:
   - Render dashboard → your service → **Logs** — look for
     `Origin not allowed` (you need to set `SYNCWELL_ORIGINS` to
     the deployed hostname, or leave it empty for "allow any").
   - Check the browser dev tools network tab for a failed
     `Upgrade: websocket`.
   - **The free tier is more likely to fail here** because of
     cold starts. If you see ~30s delays, that's Render
     spinning the container back up. Upgrade to a paid plan.

5. **The engine's `internal/` source is not in the deployed
   image.** Build locally with the same Dockerfile and inspect
   the binary:
   ```bash
   docker build --build-arg GITHUB_TOKEN="$GITHUB_TOKEN" -t syncwell:dev .
   cid=$(docker create syncwell:dev)
   docker cp "${cid}:/syncwell" /tmp/syncwell
   docker rm "${cid}"
   strings /tmp/syncwell | grep -c 'syncwell/internal'
   # expect: 0
   ```
   The only `syncwell` strings in the binary should reference
   `syncwell-engine/pkg/engine` (the public façade), not
   `syncwell/internal/...`.

6. **No tokens in the image history.**
   ```bash
   docker history syncwell:dev --no-trunc | grep -c "$GITHUB_TOKEN"
   # expect: 0
   ```
   If this is non-zero, your GITHUB_TOKEN leaked into a layer.
   Revoke it and rotate.

## 8. Rotating the GitHub token

Every 90 days (or immediately if the verification step ever fails):

1. Generate the new token on GitHub first, with the same scope.
2. Render dashboard → your service → **Environment** → edit the
   `GITHUB_TOKEN` value → **Save Changes**.
3. Render will offer to redeploy. **Accept.** The new build uses
   the new token. The old token is invalidated as soon as you
   revoke it on GitHub.

## 9. Updating the engine

When you change something in the private engine repo:

```bash
cd syncwell-engine
git tag v0.1.1
git push origin v0.1.1
```

Then in the public repo:

```bash
cd syncwell-public
# Bump the pin in go.mod.
$EDITOR go.mod      # change "v0.1.0" to "v0.1.1"
go mod tidy
git commit -am "engine: bump to v0.1.1"
git push
```

Render watches the public repo on `main` and will auto-deploy
within ~1 minute. Confirm the new version is live with
`curl -s https://syncwell-demo.onrender.com/healthz`.

## 10. Teardown

Render dashboard → your service → **Settings** → **Delete
Service**. Optionally delete the GitHub repos via the web UI.

## 11. Troubleshooting

- **Build fails with "module github.com/OWNER/syncwell-engine:
  reading http://..." with 401/403.** The `GITHUB_TOKEN` env var
  is missing, wrong, or doesn't have read access to the engine
  repo. Verify in the Render dashboard under **Environment**.

- **"Exited with status 1" right after deploy.** Open the **Logs**
  tab. Most common cause: the binary was built with a bad
  `GITHUB_TOKEN` and the resulting `go.mod` resolution failed
  silently. Look for "module ... not found" near the end of the
  build log.

- **WebSocket works locally but not in production.** The
  `SYNCWELL_ORIGINS` env var is wrong. It must exactly match the
  `Origin` header the browser sends. If you renamed the service,
  update both the URL in `SYNCWELL_ORIGINS` and the URL you visit.

- **Cold start delay on first request.** Expected on the free
  tier. See §1.2.

- **WebSocket disconnects every few minutes.** Expected on
  Render. See §1.1. The SDK reconnects automatically and the
  CRDT convergence story still works; the experience is just less
  polished than a host without this constraint.

- **Out of memory.** Render's smallest paid instance is 512 MB
  RAM. The engine uses ~12 MB RSS under load, so this shouldn't
  happen. If it does, upgrade instance type.

## 12. Alternatives if Render isn't right for you

If you came to this guide because Fly.io required a credit card
and you don't have one, the realistic options are:

| Host                          | Card required? | Persistent WebSockets? | Cold starts? | Notes |
| ----------------------------- | -------------- | ---------------------- | ------------ | ----- |
| Render free                   | **Yes**        | No (5-min idle kill)   | Yes (15 min) | what this guide covers |
| Render Starter ($7/mo)        | Yes            | No (5-min idle kill)   | No           | recommended Render tier |
| Fly.io free allowance         | varies         | Yes                    | No           | card-free for some users historically |
| Railway free trial            | No             | Yes                    | No           | $5 free credit, then card required |
| Koyeb free tier               | No             | Yes (limits)           | Limited      | worth checking current policy |
| Self-host (Hetzner, OVH)      | Yes            | Yes                    | No           | ~€4/mo, full control |

If your real constraint is "no credit card at all," Railway's
trial or Koyeb are the most likely options. The repo layout in
this directory does not need to change to switch — only the
platform-specific deployment steps in this guide.

## 13. What this guide does not cover

- **Custom domains.** Add a custom domain on the Render service
  page, then update `SYNCWELL_ORIGINS` to match.
- **Horizontal scaling.** The engine is per-process; running more
  than one instance requires a shared transport (Redis pub/sub or
  NATS) which the current code does not include. See
  [docs/ROADMAP.md](docs/ROADMAP.md) for the design sketch.
- **Backup of persistent data.** If you enabled a persistent
  disk, back it up with `render ssh syncwell-data` → `tar czf
  - /var/data/syncwell`. Render also offers periodic snapshots
  on paid plans.
