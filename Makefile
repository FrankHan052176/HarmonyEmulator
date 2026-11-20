.PHONY: build build-all test install doctor run package-kit package-full

LISTEN ?= 127.0.0.1:18555
GOFLAGS ?= -buildvcs=false

build:
	@mkdir -p bin
	cd dashboard && CGO_ENABLED=0 GOFLAGS="$(GOFLAGS)" go build -o ../bin/harmony-emulator-dashboard .

build-all:
	@mkdir -p dist
	cd dashboard && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 GOFLAGS="$(GOFLAGS)" go build -trimpath -ldflags="-s -w" -o ../dist/harmony-emulator-dashboard-darwin-arm64 .
	cd dashboard && CGO_ENABLED=0 GOOS=linux  GOARCH=arm64 GOFLAGS="$(GOFLAGS)" go build -trimpath -ldflags="-s -w" -o ../dist/harmony-emulator-dashboard-linux-arm64 .
	@ls -lh dist/harmony-emulator-dashboard-*

test:
	cd dashboard && GOFLAGS="$(GOFLAGS)" go test -v ./...

install:
	./install.sh --listen $(LISTEN)

doctor:
	./scripts/doctor.sh --listen $(LISTEN)

run: build
	./bin/harmony-emulator-dashboard --listen $(LISTEN) --root "$(CURDIR)"

package-kit: build-all
	./scripts/package-runtime.sh --without-images

package-full: build-all
	./scripts/package-runtime.sh
