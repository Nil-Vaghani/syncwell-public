FROM golang:1.23-alpine AS build
WORKDIR /src

RUN apk add --no-cache git

<<<<<<< HEAD
=======
# Tell the go toolchain that github.com/OWNER is private; the engine
# module lives there. The token below is read in via a build ARG (not
# kept in any layer's history) and used only to satisfy git over HTTPS.
>>>>>>> 54066b3 (Fix: Add missing main.go and structure)
ARG GITHUB_TOKEN
ENV GOPRIVATE=github.com/OWNER/*
RUN git config --global url."https://${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"

# 1. પહેલા કોડ કોપી કરો
COPY . .

# 2. કોડ કોપી થયા પછી જ tidy અને download રન કરો
RUN go mod tidy && go mod download

# 3. હવે બિલ્ડ કરો
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/syncwell ./cmd/syncwell

<<<<<<< HEAD
FROM gcr.io/distroless/static-debian12:nonroot
=======
# --- runtime stage ---
# distroless `base` (not `static`) so we have a shell to translate
# Render's $PORT env var into a CLI flag. The nonroot tag is non-negotiable
# for a public-internet container.
FROM gcr.io/distroless/base-debian12:nonroot
>>>>>>> 54066b3 (Fix: Add missing main.go and structure)
COPY --from=build --chown=nonroot:nonroot /out/syncwell /syncwell
COPY --from=build --chown=nonroot:nonroot /src/demo /demo
COPY --from=build --chown=nonroot:nonroot /src/sdk /sdk
EXPOSE 8080
USER nonroot:nonroot
# Render injects $PORT (default 10000) at runtime. We bind the binary
# to that port if set, otherwise 8080 (the local default). Note that
# Render's free Web Service tier enforces a 5-minute WebSocket idle
# timeout regardless of binding; see DEPLOY.md.
ENTRYPOINT ["/busybox/sh", "-c", "exec /syncwell -addr :${PORT:-8080} -static /demo"]
