FROM golang:1.22-alpine AS builder

WORKDIR /build

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /paystream-auth-service .

FROM gcr.io/distroless/static:nonroot

COPY --from=builder /paystream-auth-service /paystream-auth-service

USER nonroot:nonroot

EXPOSE 8080

ENTRYPOINT ["/paystream-auth-service"]
