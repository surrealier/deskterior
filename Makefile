# Deskterior developer tasks. Scripts live in scripts/; every target works with Command Line Tools only.
# `make app VERSION=0.1.0` sets the bundle version (default: latest git tag, else 0.0.0-dev).
.PHONY: build release test lint check app universal install icon run idle soak clean
# MARK: release (M13)
.PHONY: gif

APP_ARGS = $(if $(VERSION),--version $(VERSION))

build:
	swift build

release:
	swift build -c release --product Deskterior

test:
	scripts/ci-test.sh

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

# MARK: release (M13): a window on a fresh mktemp fixture and state folder (the app refuses runs without one).
run:
	@FIX="$$(mktemp -d "$${TMPDIR:-/tmp}/deskterior-run.XXXXXX")" && scripts/make-fixture-desktop.sh "$$FIX/desk" && \
	  swift run Deskterior --windowed --desktop-folder "$$FIX/desk" --state-dir "$$FIX/state"

# MARK: harden: DESIGN §5 idle check (§8.3 item 20); add ARGS="--exit-after 70" for the 60-s average.
idle:
	scripts/measure-idle.sh $(ARGS)

soak:
	scripts/soak.sh --release

# MARK: release (M13): records Demos/hero.json on a mktemp fixture; writes docs/media/hero.gif and the stills (ffmpeg).
gif:
	scripts/make-gif.sh

clean:
	rm -rf .build .build-* build
