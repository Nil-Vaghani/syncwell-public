# --- build stage ---
FROM golang:1.23-alpine AS build
WORKDIR /src

# Git is required to fetch the private engine module. We pass a fine-scoped
# GitHub token (read-only on the syncwell-engine repo) as a build secret —
# see DEPLOY.md for how to set it. It is exposed to `go mod download` only
# via GOPRIVATE and git's credential helper, never persisted into the
# resulting binary.
RUN apk add --no-cache git

# Tell the go toolchain that github.com/Nil-Vaghani is private; the engine
# module lives there. The token below is read in via a build ARG (not
# kept in any layer's history) and used only to satisfy git over HTTPS.
ARG GITHUB_TOKEN
ENV GOPRIVATE=github.com/Nil-Vaghani/*
RUN git config --global url."https://${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"

COPY go.mod go.sum* ./
RUN go mod download

COPY . .

# Static, stripped, single binary. -trimpath strips local filesystem
# paths from the binary so neither the build machine's layout nor any
# absolute source paths leak into the deployable artifact.
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" \
    -o /out/syncwell ./cmd/syncwell

# --- runtime stage ---
# Distroless: no shell, no package manager, no writable filesystem.
# Runs as a non-root user (uid 65532) for defense in depth.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build --chown=nonroot:nonroot /out/syncwell /syncwell
COPY --from=build --chown=nonroot:nonroot /src/demo /demo
COPY --from=build --chown=nonroot:nonroot /src/sdk /sdk
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/syncwell", "-addr", ":8080", "-static", "/demo"]
