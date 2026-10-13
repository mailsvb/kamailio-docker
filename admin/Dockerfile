FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /admin .

FROM alpine:latest
COPY --from=build /admin /usr/local/bin/admin
EXPOSE 8080
CMD ["/usr/local/bin/admin"]
