# Deployment guide

This repository is the **public** Syncwell deployment. The Go engine
(CRDT, hub, persistence, auth) lives in a separate **private**
repository and is consumed as a private Go module at build time. This
file walks you through pushing both repos to GitHub, wiring secrets,
and shipping the demo to Fly.io.

If anything here disagrees with what Fly or GitHub shows in their
console, trust the console — this guide is correct as of the
tooling versions pinned in `go.mod`, `.github/workflows/ci.yml`, and
`Dockerfile`. Check the tool's release notes if you bump versions.

## 0. Before you start

You will need:

- A GitHub account with permission to create two repositories:
  one public, one private.
- A Fly.io account and the `fly` CLI installed
  (`curl -L https://fly.io/install.sh | sh`, then `fly auth login`).
- A place to keep two secrets: `SYNCWELL_SECRET` (32 random bytes)
  and a fine-scoped GitHub PAT. A password manager is fine; do not
  commit either value.
- Two repository names picked in advance. The rest of this guide
  assumes:
  - public:  `Nil-Vaghani/syncwell-public`
  - private: `Nil-Vaghani/syncwell-engine`
  - Fly app: `Nil-Vaghani-syncwell-demo`

  Replace `Nil-Vaghani` everywhere it appears below with your actual
  GitHub username. There is no automated way to do this — `grep -r
  Nil-Vaghani .` will list every file that needs editing.

## 1. Create the private engine repo first

The public repo's `go.mod` requires the private one to exist with at
least one tagged release. Set it up first.

```bash
cd syncwell-engine

git init -b main
git add .
git commit -m "import: initial engine from monorepo split"

# Create the private repo on GitHub (web UI, or `gh repo create
# Nil-Vaghani/syncwell-engine --private --source=. --remote=origin`).
git push -u origin main

# Tag a version. The public repo pins to a tag, not a branch, so a
# release here is intentional and reviewable.
git tag v0.1.0
git push origin v0.1.0
```

Edit `pkg/engine/engine.go`'s package comment if you want to update
the symbol list; the public repo only needs the facade to keep the
same shape.

## 2. Create the public repo

```bash
cd syncwell-public

# Edit go.mod to pin to the tag you just pushed:
#   require github.com/Nil-Vaghani/syncwell-engine v0.1.0
# (replace Nil-Vaghani and v0.1.0 with your values)
$EDITOR go.mod

# Create the public repo on GitHub.
git init -b main
git add .
git commit -m "import: public demo, engine consumed as private module"
git push -u origin main
```

The first push will fail in CI if the engine tag doesn't exist yet,
because `go mod download` cannot resolve the private module. That is
expected. CI will pass once step 1 is complete.

## 3. Create a fine-scoped GitHub PAT

The build (both local Docker and Fly) needs a token to fetch the
private engine module. Make it as small as possible:

- GitHub → Settings → Developer settings → Personal access tokens →
  Fine-grained tokens.
- Resource owner: yourself.
- Repository access: **Only select repositories** → `syncwell-engine`.
- Permissions: **Contents: Read-only**. Nothing else.
- Expiration: 90 days. Calendar a reminder to rotate.

Copy the token once into your password manager. You will paste it
into Fly as a build secret in the next step.

## 4. Create the Fly app

```bash
cd syncwell-public

# This reads fly.toml and creates the app without deploying yet.
fly launch --no-deploy

# Generate the room-token secret. 32 random bytes, hex-encoded.
SYNCWELL_SECRET=$(openssl rand -hex 32)
echo "save this somewhere: $SYNCWELL_SECRET"

# Set the two secrets on Fly. Neither will be visible in `fly config`
# or `fly.toml` — they live in Fly's secret store.
fly secrets set SYNCWELL_SECRET="$SYNCWELL_SECRET"

# The GITHUB_TOKEN is consumed at build time only. It is *not* a
# runtime environment variable, so we use secrets import + a build
# arg. Fly exposes build secrets to the Dockerfile as build args.
fly secrets import <<< "GITHUB_TOKEN=ghp_replace_me_with_real_pat"
```

The GITHUB_TOKEN ends up in the Dockerfile as `ARG GITHUB_TOKEN`,
which is used to set up a `git config url.<token>@github.com/...
insteadOf https://github.com/` line. It is only consulted by `go mod
download` and never persisted into any layer's history (BuildKit
treats `RUN` lines that consume an ARG without `ENV` as
non-caching). You can verify with `docker history syncwell:latest`
and check that no layer contains the token string.

## 5. Deploy

```bash
fly deploy
fly open
```

The first deploy will take a few minutes because of the Go module
download. Subsequent deploys are faster (BuildKit cache).

## 6. Verify

End-to-end checks, in the order you should run them:

1. **Health endpoint responds.**
   ```bash
   curl -s https://Nil-Vaghani-syncwell-demo.fly.dev/healthz
   # expect: ok
   ```

2. **The demo page is served.**
   ```bash
   curl -s https://Nil-Vaghani-syncwell-demo.fly.dev/ | head -20
   # expect: HTML with a "Syncwell" string
   ```

3. **The SDK is reachable.**
   ```bash
   curl -sI https://Nil-Vaghani-syncwell-demo.fly.dev/sdk/syncwell.js
   # expect: HTTP/2 200
   ```

4. **WebSocket sync works in a browser.** Open
   `https://Nil-Vaghani-syncwell-demo.fly.dev/kanban.html` in two browser
   windows. Drag a card in one; it should move in the other within
   ~50 ms. If it doesn't:
   - `fly logs` — look for `Origin not allowed` (you need to set
     `SYNCWELL_ORIGINS` to the deployed hostname, or leave it empty
     for "allow any").
   - Check the browser dev tools network tab for a failed
     `Upgrade: websocket`.

5. **The engine's `internal/` source is not in the deployed
   binary.** Locally:
   ```bash
   fly ssh console --command '/syncwell -h' >/dev/null
   # The above just confirms the binary runs. To inspect it, build
   # locally and check:
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
   If this is non-zero, your GITHUB_TOKEN leaked into a layer. Revoke
   it and rotate.

## 7. Rotating the GitHub token

Every 90 days (or immediately if the previous verification step ever
fails):

```bash
# Generate the new token on GitHub first, with the same scope.
fly secrets import <<< "GITHUB_TOKEN=ghp_new_token_here"
fly deploy
```

The deploy rebuilds the image, so the new token replaces the old
one in BuildKit's cache. The old token is invalidated by GitHub as
soon as you revoke it; the in-flight build's copy of the old token
is only valid for the duration of that build.

## 8. Updating the engine

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
fly deploy
```

## 9. Teardown

```bash
fly apps destroy Nil-Vaghani-syncwell-demo
# Optionally delete the GitHub repos via the web UI.
```

## 10. Troubleshooting

- **"module github.com/Nil-Vaghani/syncwell-engine: reading
  http://..." with 401/403.** The GITHUB_TOKEN is missing, wrong,
  or doesn't have read access to the engine repo. Verify with
  `fly secrets list` and `gh repo view Nil-Vaghani/syncwell-engine
  --json viewerPermission` (should be `READ`).

- **Build hangs at `go mod download`.** Almost always a credential
  problem. Run the build locally with `--progress=plain` to see the
  underlying git error: `docker build --progress=plain -t syncwell
  .`.

- **WebSocket works locally but not in production.** You forgot to
  set `SYNCWELL_ORIGINS` to the deployed hostname (or leave it
  empty). The `fly.toml` default is set to the deployed URL; if you
  renamed the app, update both `app =` and `SYNCWELL_ORIGINS`.

- **Out of memory in production.** Fly's `[[vm]] memory_mb` is
  256 in `fly.toml`. The engine uses ~12 MB under load, but the
  Go runtime reserves more. If you see OOMs, bump to 512 with
  `fly scale memory 512`.

- **CI green locally, red in GitHub Actions.** The PAT stored in
  GitHub secrets (`secrets.GITHUB_TOKEN`) is different from the one
  in Fly secrets. Both are needed. CI uses GitHub's secret; Fly
  uses Fly's. They can be the same token if you want, but they are
  managed in two different places.

## 11. What this guide does not cover

- **Custom domains.** Add a CNAME and a Fly certificate with
  `fly certs add` and update `SYNCWELL_ORIGINS`.
- **Horizontal scaling.** The engine is per-process; running more
  than one machine requires a shared transport (Redis pub/sub or
  NATS) which the current code does not include. See
  [docs/ROADMAP.md](docs/ROADMAP.md) for the design sketch.
- **Backup of persistent data.** If you enable `-data /data`, the
  data lives on the Fly volume. Back it up with
  `fly ssh console -C "tar czf - /data" > backup.tgz` on a
  schedule.
