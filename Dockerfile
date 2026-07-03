# --- build stage ---
FROM golang:1.23-alpine AS build
WORKDIR /src

RUN apk add --no-cache git

ARG GITHUB_TOKEN
ENV GOPRIVATE=github.com/Nil-Vaghani/*
RUN git config --global url."https://${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"


COPY . .


RUN go mod tidy && go mod download


RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" \
    -o /out/syncwell ./cmd/syncwell

# --- runtime stage ---
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build --chown=nonroot:nonroot /out/syncwell /syncwell
COPY --from=build --chown=nonroot:nonroot /src/demo /demo
COPY --from=build --chown=nonroot:nonroot /src/sdk /sdk
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/syncwell", "-addr", ":8080", "-static", "/demo"]
