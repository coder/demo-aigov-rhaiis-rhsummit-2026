FROM golang:1.22 AS builder
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /bridge ./cmd/bridge

FROM gcr.io/distroless/static-debian12:nonroot
USER nonroot:nonroot
COPY --from=builder /bridge /bridge
EXPOSE 8080
ENTRYPOINT ["/bridge"]
