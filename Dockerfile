FROM golang:1.23-alpine AS build
WORKDIR /src


RUN apk add --no-cache git openssh-client


RUN mkdir -p -m 0700 /root/.ssh && \
    ssh-keyscan github.com >> /root/.ssh/known_hosts && \
    git config --global url."git@github.com:".insteadOf "https://github.com/"


ENV GOPRIVATE=github.com/Nil-Vaghani/*


COPY . .


RUN go mod tidy && go mod download


RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/syncwell ./cmd/syncwell


FROM gcr.io/distroless/base-debian12:nonroot
COPY --from=build --chown=nonroot:nonroot /out/syncwell /syncwell
COPY --from=build --chown=nonroot:nonroot /src/demo /demo
COPY --from=build --chown=nonroot:nonroot /src/sdk /sdk
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/busybox/sh", "-c", "exec /syncwell -addr :${PORT:-8080} -static /demo"]
