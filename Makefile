# Deskterior developer tasks. Scripts live in scripts/; every target works with Command Line Tools only.
# `make app VERSION=0.1.0` sets the bundle version (default: latest git tag, else 0.0.0-dev).
.PHONY: build release test lint check app universal install icon run soak clean

APP_ARGS = $(if $(VERSION),--version $(VERSION))

build:
	swift build

release:
	swift build -c release --product Deskterior

test:
	scripts/swift-test.sh

lint:
	scripts/check-file-safety.sh

check: build test lint

app:
	scripts/build-app.sh $(APP_ARGS)

universal:
	ARCHS="arm64 x86_64" scripts/build-app.sh $(APP_ARGS)

install: app
	rm -rf /Applications/Deskterior.app
	ditto build/Deskterior.app /Applications/Deskterior.app

icon:
	scripts/make-icon.sh

run:
	swift run Deskterior --windowed

soak:
	scripts/soak.sh --release

clean:
	rm -rf .build .build-* build
